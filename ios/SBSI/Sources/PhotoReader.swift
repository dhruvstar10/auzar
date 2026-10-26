import UIKit
import Vision

/// On-device text + barcode reading (Apple Vision, the engine behind Live Text) on full-res photos.
///
/// The realtime model downsizes every image to ~512 px, so it can't read labels from a whole photo,
/// and a fixed centre crop missed: hand-held objects appear low-right in the glasses' view
/// (field test, 2026-10-26). Vision reads the full 1080x1440 photo in well under a second, for free,
/// and tells us where the text is, so the zoom crop can go there.
enum PhotoReader {
  struct Result {
    var lines: [String] = []
    var barcodes: [String] = []
    /// The main label, with margin, in UIKit image coordinates (origin top-left). A union of ALL
    /// text spanned a monitor behind the bottle too, so the "close-up" was 2465x2162 px and the
    /// model, which views ~512 px, couldn't read it (2026-10-26).
    var textRegion: CGRect?
    /// Lines inside `textRegion` (the main label) and the rest (screens, papers, background).
    var mainLines: [String] = []
    var otherLines: [String] = []
  }

  static func read(_ image: UIImage) async -> Result {
    guard let cg = image.cgImage else { return Result() }
    return await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = true
        // Auto language detection turned "Walgreens" into Cyrillic on a real label.
        text.recognitionLanguages = ["en-US"]
        text.automaticallyDetectsLanguage = false
        let codes = VNDetectBarcodesRequest()
        try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([text, codes])

        var result = Result()
        let size = CGSize(width: cg.width, height: cg.height)
        // Vision boxes are normalized with origin bottom-left.
        func toImage(_ n: CGRect) -> CGRect {
          CGRect(x: n.minX * size.width, y: (1 - n.maxY) * size.height,
                 width: n.width * size.width, height: n.height * size.height)
        }
        var textBoxes: [(text: String, rect: CGRect)] = []
        var codeBoxes: [CGRect] = []
        for obs in text.results ?? [] {
          guard let best = obs.topCandidates(1).first, best.confidence >= 0.3 else { continue }
          result.lines.append(best.string)
          textBoxes.append((best.string, toImage(obs.boundingBox)))
        }
        for obs in codes.results ?? [] {
          if let payload = obs.payloadStringValue {
            result.barcodes.append("\(obs.symbology.rawValue.replacingOccurrences(of: "VNBarcodeSymbology", with: "")): \(payload)")
          }
          codeBoxes.append(toImage(obs.boundingBox))
        }
        // Main label: a window around the barcodes if any (a barcode marks a label), else around
        // the biggest letters (usually the product name). Chaining nearby text instead pulled in a
        // whole monitor of dense text (tested on 2026-10-26 photos).
        // Letter size is the box height, capped by width per character because Vision's boxes for
        // long, slanted lines are tall.
        func letterSize(_ t: String, _ r: CGRect) -> CGFloat { min(r.height, r.width / CGFloat(max(t.count, 1)) / 0.55) }
        var region: CGRect?
        if let first = codeBoxes.first {
          let codes = codeBoxes.dropFirst().reduce(first) { $0.union($1) }
          let w = max(codes.width, codes.height)
          region = codes.insetBy(dx: -w * 0.9, dy: -w * 0.7)
        } else if let seed = textBoxes.filter({ $0.text.filter(\.isLetter).count >= 3 })
          .max(by: { letterSize($0.text, $0.rect) < letterSize($1.text, $1.rect) }) {
          let l = letterSize(seed.text, seed.rect)
          region = CGRect(x: seed.rect.midX - l * 7, y: seed.rect.midY - l * 6, width: l * 14, height: l * 13)
        }
        if let region {
          result.textRegion = region.intersection(CGRect(origin: .zero, size: size))
          for box in textBoxes {
            if region.contains(CGPoint(x: box.rect.midX, y: box.rect.midY)) {
              result.mainLines.append(box.text)
            } else {
              result.otherLines.append(box.text)
            }
          }
        } else {
          result.otherLines = result.lines
        }
        continuation.resume(returning: result)
      }
    }
  }
}

extension UIImage {
  /// Crop to `region` (it already has margin), at least 640 px on each side so the model keeps some
  /// context (it views images at ~512 px, so a bigger crop loses detail). Expects an upright image.
  func cropped(around region: CGRect) -> UIImage {
    guard let cg = cgImage else { return self }
    let w = CGFloat(cg.width), h = CGFloat(cg.height)
    var r = region
    let minW = min(w, 640), minH = min(h, 640)
    if r.width < minW { r = r.insetBy(dx: -(minW - r.width) / 2, dy: 0) }
    if r.height < minH { r = r.insetBy(dx: 0, dy: -(minH - r.height) / 2) }
    r = r.intersection(CGRect(x: 0, y: 0, width: w, height: h)).integral
    guard !r.isEmpty, let crop = cg.cropping(to: r) else { return self }
    return UIImage(cgImage: crop)
  }
}
