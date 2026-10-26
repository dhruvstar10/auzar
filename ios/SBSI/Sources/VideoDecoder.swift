import CoreImage
import CoreMedia
import UIKit
import VideoToolbox

/// Decodes the glasses' compressed HEVC (`.hvc1`) stream into images.
///
/// We switched from `.raw` because the raw stream saturated the glasses link: the SDK cut it to
/// 504x896 even at 2 fps, the video stalled, and photos timed out (field tests, 2026-10-24/25).
/// With `.hvc1` the Meta sample held 720x1280 @ 24 fps. HEVC frames depend on earlier frames,
/// so every frame must be decoded, even though we only turn a few per second into a UIImage.
final class VideoDecoder {
  private var session: VTDecompressionSession?
  private var format: CMFormatDescription?
  private let ciContext = CIContext()
  private var failures = 0

  /// Decodes one frame. Calls `onImage` (on a decoder thread) only when `wantImage` is true.
  func decode(_ sampleBuffer: CMSampleBuffer, wantImage: Bool, onImage: @escaping (UIImage) -> Void) {
    guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
    if session == nil || format.map({ !CMFormatDescriptionEqual($0, otherFormatDescription: desc) }) ?? true {
      makeSession(for: desc)
    }
    guard let session else { return }
    let status = VTDecompressionSessionDecodeFrame(
      session, sampleBuffer: sampleBuffer, flags: [], infoFlagsOut: nil
    ) { [weak self] status, _, imageBuffer, _, _ in
      guard let self, status == noErr, let imageBuffer else { return }
      guard wantImage else { return }
      let ci = CIImage(cvPixelBuffer: imageBuffer)
      if let cg = self.ciContext.createCGImage(ci, from: ci.extent) {
        onImage(UIImage(cgImage: cg))
      }
    }
    if status != noErr {
      failures += 1
      if failures == 1 || failures % 50 == 0 { sbsiLog("video decode error \(status) (x\(failures))") }
      // A broken session (e.g. after a stream glitch) recovers at the next keyframe with a new one.
      if status == kVTInvalidSessionErr { invalidate() }
    }
  }

  func invalidate() {
    if let session { VTDecompressionSessionInvalidate(session) }
    session = nil
    format = nil
  }

  private func makeSession(for desc: CMFormatDescription) {
    invalidate()
    let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA]
    var newSession: VTDecompressionSession?
    let status = VTDecompressionSessionCreate(
      allocator: nil, formatDescription: desc, decoderSpecification: nil,
      imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
      decompressionSessionOut: &newSession)
    if status == noErr {
      session = newSession
      format = desc
      let dims = CMVideoFormatDescriptionGetDimensions(desc)
      sbsiLog("video decoder ready: \(dims.width)x\(dims.height)")
    } else {
      sbsiLog("video decoder create failed: \(status)")
    }
  }

  deinit { invalidate() }
}
