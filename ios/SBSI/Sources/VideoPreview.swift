import AVFoundation
import SwiftUI

/// Feeds the glasses' compressed HEVC samples straight to an `AVSampleBufferDisplayLayer`, which
/// decodes and draws them in hardware: full-rate preview (~15 fps) for less work than the old path
/// of converting frames to UIImages at 5 fps. Images for the model still come from `VideoDecoder`.
final class VideoSink: @unchecked Sendable {
  private weak var layer: AVSampleBufferDisplayLayer?  // only touched on the main queue

  @MainActor func attach(_ layer: AVSampleBufferDisplayLayer) {
    self.layer = layer
  }

  /// Any thread.
  func enqueue(_ buffer: CMSampleBuffer) {
    // Show each frame as soon as it arrives; the stream's timestamps aren't tied to a clock here.
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true),
       CFArrayGetCount(attachments) > 0 {
      let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
      CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                           Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
    DispatchQueue.main.async { [weak self] in
      guard let renderer = self?.layer?.sampleBufferRenderer else { return }
      // The layer fails when the app backgrounds; flush to recover. HEVC then needs the next
      // keyframe, so the preview may stay black for a moment.
      if renderer.status == .failed { renderer.flush() }
      if renderer.isReadyForMoreMediaData { renderer.enqueue(buffer) }
    }
  }

  /// Clear the picture (stream stopped or restarted).
  func flush() {
    DispatchQueue.main.async { [weak self] in
      self?.layer?.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }
  }
}

struct VideoPreview: UIViewRepresentable {
  let sink: VideoSink

  final class LayerView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
  }

  func makeUIView(context: Context) -> LayerView {
    let view = LayerView()
    view.displayLayer.videoGravity = .resizeAspect
    view.backgroundColor = .black
    sink.attach(view.displayLayer)
    return view
  }

  func updateUIView(_ view: LayerView, context: Context) {}
}
