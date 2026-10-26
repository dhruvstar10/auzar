import AVFoundation

/// On-device text-to-speech for app-scripted cues (e.g. the detail test), played through the
/// current audio route (the glasses). `say` returns when the utterance finishes.
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
  private let synth = AVSpeechSynthesizer()
  private var pending: [ObjectIdentifier: CheckedContinuation<Void, Never>] = [:]

  override init() {
    super.init()
    synth.delegate = self
  }

  func say(_ text: String) async {
    sbsiLog("speaker: \(text)")
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
    await withCheckedContinuation { continuation in
      pending[ObjectIdentifier(utterance)] = continuation
      synth.speak(utterance)
    }
  }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    let id = ObjectIdentifier(utterance)
    Task { @MainActor in self.pending.removeValue(forKey: id)?.resume() }
  }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    let id = ObjectIdentifier(utterance)
    Task { @MainActor in self.pending.removeValue(forKey: id)?.resume() }
  }
}
