import AVFoundation

/// Microphone in / speech out, routed through the glasses (Bluetooth HFP).
///
/// Input is converted to 24 kHz mono PCM16 (what the realtime API expects) and handed out in
/// small chunks. Output takes 24 kHz mono PCM16 from the model and plays it immediately.
final class AudioIO {
  static let sampleRate: Double = 24_000

  /// Called on the audio thread with PCM16 little-endian mono @ 24 kHz.
  var onMicAudio: ((Data) -> Void)?

  /// When true, mic audio is dropped (used to avoid the guide hearing itself).
  var micMuted = false

  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private let playFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
  private let micFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
  private var converter: AVAudioConverter?
  private var scheduledBuffers = 0
  private let lock = NSLock()

  private(set) var inputRouteName = "?"

  /// True while model speech is queued or playing.
  var isPlaying: Bool {
    lock.lock()
    defer { lock.unlock() }
    return scheduledBuffers > 0
  }

  func start() throws {
    let session = AVAudioSession.sharedInstance()
    // voiceChat mode turns on echo cancellation; allowBluetoothHFP routes mic + speaker to the glasses.
    try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
    try session.setActive(true)
    if let glasses = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
      try session.setPreferredInput(glasses)
    }
    inputRouteName = session.currentRoute.inputs.map { "\($0.portName) (\($0.portType.rawValue))" }
      .joined(separator: ", ")
    let outputs = session.currentRoute.outputs.map { $0.portName }.joined(separator: ", ")
    sbsiLog("audio route: in=\(inputRouteName) out=\(outputs)")

    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: playFormat)

    let input = engine.inputNode
    let inFormat = input.outputFormat(forBus: 0)
    sbsiLog("mic format: \(inFormat.sampleRate) Hz, \(inFormat.channelCount) ch")
    converter = AVAudioConverter(from: inFormat, to: micFormat)
    input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
      self?.handleMic(buffer)
    }

    engine.prepare()
    try engine.start()
    player.play()
  }

  func stop() {
    engine.inputNode.removeTap(onBus: 0)
    player.stop()
    engine.stop()
    lock.lock()
    scheduledBuffers = 0
    lock.unlock()
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  /// Queue model speech (PCM16 LE mono @ 24 kHz).
  func play(pcm16 data: Data) {
    let frames = data.count / 2
    guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(frames))
    else { return }
    buffer.frameLength = AVAudioFrameCount(frames)
    let out = buffer.floatChannelData![0]
    data.withUnsafeBytes { raw in
      let samples = raw.bindMemory(to: Int16.self)
      for i in 0..<frames {
        out[i] = Float(Int16(littleEndian: samples[i])) / 32768
      }
    }
    lock.lock()
    scheduledBuffers += 1
    lock.unlock()
    player.scheduleBuffer(buffer) { [weak self] in
      guard let self else { return }
      self.lock.lock()
      self.scheduledBuffers = max(0, self.scheduledBuffers - 1)
      self.lock.unlock()
    }
    if !player.isPlaying { player.play() }
  }

  /// Drop any queued speech immediately (user interrupted).
  func stopPlayback() {
    player.stop()
    lock.lock()
    scheduledBuffers = 0
    lock.unlock()
    player.play()
  }

  private func handleMic(_ buffer: AVAudioPCMBuffer) {
    guard !micMuted, let converter else { return }
    let ratio = micFormat.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
    guard let out = AVAudioPCMBuffer(pcmFormat: micFormat, frameCapacity: capacity) else { return }
    var consumed = false
    var error: NSError?
    converter.convert(to: out, error: &error) { _, status in
      if consumed {
        status.pointee = .noDataNow
        return nil
      }
      consumed = true
      status.pointee = .haveData
      return buffer
    }
    guard error == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }
    onMicAudio?(Data(bytes: ch[0], count: Int(out.frameLength) * 2))
  }
}
