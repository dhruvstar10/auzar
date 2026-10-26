import AVFoundation

/// Microphone in / speech out, routed through the glasses (Bluetooth HFP).
///
/// Input is converted to 24 kHz mono PCM16 (what the realtime API expects) and handed out in
/// small chunks. Output takes 24 kHz mono PCM16 from the model and plays it immediately.
///
/// iOS stops the engine whenever the audio route or hardware format changes (e.g. the glasses'
/// Bluetooth link drops and comes back). We rebuild the graph on those notifications; without
/// that, speech went silent and the mic stayed muted forever (field test, 2026-10-24).
final class AudioIO {
  static let sampleRate: Double = 24_000

  /// Called on the audio thread with PCM16 little-endian mono @ 24 kHz.
  var onMicAudio: ((Data) -> Void)?
  /// Called (any thread) with a human-readable note when the route changes or audio restarts.
  var onRouteNote: ((String) -> Void)?

  /// Echo gate: while the guide is speaking, mic audio quieter than this (dBFS) is replaced with
  /// silence, so the guide's own voice leaking from the open-ear speakers doesn't trigger the
  /// server's voice detection, but the user speaking up close still gets through (barge-in).
  /// A full mute here made barge-in impossible (field test, 2026-10-24). nil = no gate.
  var echoGateDb: Float? = -30
  /// Send silence instead of the mic (e.g. while the app runs a scripted test). Read on the audio thread.
  var muteMic = false

  // Level stats for tuning the gate, logged periodically.
  private var peakDbWhilePlaying: Float = -120
  private var peakDbWhileQuiet: Float = -120
  private var lastLevelLog = Date()

  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private let playFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
  private let micFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
  private var converter: AVAudioConverter?
  private var scheduledBuffers = 0
  /// When queued speech should finish; a fallback in case buffer callbacks never fire.
  private var queuedUntil = Date.distantPast
  private let lock = NSLock()
  private var observers: [NSObjectProtocol] = []
  private var running = false

  /// Seconds of audio queued for playback so far (photo diagnostics: does guide audio slow transfers?).
  private(set) var playedSeconds: Double = 0
  private(set) var inputRouteName = "?"
  /// True when both mic and speaker are on the glasses.
  private(set) var isOnGlasses = false

  init() {
    engine.attach(player)
  }

  /// True while model speech is queued or playing.
  var isPlaying: Bool {
    lock.lock()
    defer { lock.unlock() }
    return scheduledBuffers > 0 && Date() < queuedUntil.addingTimeInterval(1)
  }

  func start() throws {
    let session = AVAudioSession.sharedInstance()
    // voiceChat mode turns on echo cancellation; allowBluetoothHFP routes mic + speaker to the glasses.
    try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
    try session.setActive(true)
    preferGlassesInput()
    try startEngine()
    running = true

    let center = NotificationCenter.default
    observers = [
      center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) {
        [weak self] _ in self?.restart(reason: "audio configuration changed")
      },
      center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) {
        [weak self] note in
        let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
        let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
        // New device (glasses back) or old one gone: re-pick the glasses and rebuild.
        if reason == .newDeviceAvailable || reason == .oldDeviceUnavailable {
          self?.restart(reason: "audio route changed")
        }
      },
      center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) {
        [weak self] note in
        let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
        if AVAudioSession.InterruptionType(rawValue: raw) == .ended {
          try? AVAudioSession.sharedInstance().setActive(true)
          self?.restart(reason: "audio interruption ended")
        }
      },
    ]
  }

  func stop() {
    running = false
    observers.forEach(NotificationCenter.default.removeObserver)
    observers = []
    stopEngine()
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  /// Queue model speech (PCM16 LE mono @ 24 kHz).
  func play(pcm16 data: Data) {
    let frames = data.count / 2
    guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(frames))
    else { return }
    if running && !engine.isRunning { restart(reason: "audio engine was stopped") }
    buffer.frameLength = AVAudioFrameCount(frames)
    let out = buffer.floatChannelData![0]
    data.withUnsafeBytes { raw in
      let samples = raw.bindMemory(to: Int16.self)
      for i in 0..<frames {
        out[i] = Float(Int16(littleEndian: samples[i])) / 32768
      }
    }
    lock.lock()
    playedSeconds += Double(frames) / Self.sampleRate
    scheduledBuffers += 1
    queuedUntil = max(queuedUntil, Date()).addingTimeInterval(Double(frames) / Self.sampleRate)
    lock.unlock()
    player.scheduleBuffer(buffer) { [weak self] in
      guard let self else { return }
      self.lock.lock()
      self.scheduledBuffers = max(0, self.scheduledBuffers - 1)
      self.lock.unlock()
    }
    if !player.isPlaying { player.play() }
  }

  /// Short rising two-note chime ("photo taken"), played like model speech so it reaches the glasses.
  func playChime() {
    play(pcm16: Self.tones([(880, 110), (1320, 170)], volume: 0.3))
  }

  /// Soft short beep, repeated while a photo is being taken so the user knows something's happening.
  func playBeep() {
    play(pcm16: Self.tones([(1000, 70)], volume: 0.15))
  }

  /// Sine tones (Hz, ms) in sequence with a soft attack and tail, as PCM16 @ 24 kHz.
  private static func tones(_ notes: [(Double, Double)], volume: Double) -> Data {
    var samples = [Int16]()
    for (freq, ms) in notes {
      let count = Int(sampleRate * ms / 1000)
      for i in 0..<count {
        let envelope = min(1, Double(i) / 240) * min(1, Double(count - i) / min(1200, Double(count) / 2))
        samples.append(Int16(volume * 32767 * envelope * sin(2 * .pi * freq * Double(i) / sampleRate)))
      }
    }
    return samples.withUnsafeBufferPointer { Data(buffer: $0) }
  }

  /// Drop any queued speech immediately (user interrupted).
  func stopPlayback() {
    player.stop()
    resetQueue()
    if engine.isRunning { player.play() }
  }

  // MARK: - Engine

  private func startEngine() throws {
    let input = engine.inputNode
    let inFormat = input.outputFormat(forBus: 0)
    guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
      throw NSError(domain: "AudioIO", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone available"])
    }
    engine.connect(player, to: engine.mainMixerNode, format: playFormat)
    converter = AVAudioConverter(from: inFormat, to: micFormat)
    input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
      self?.handleMic(buffer)
    }
    engine.prepare()
    try engine.start()
    player.play()

    let session = AVAudioSession.sharedInstance()
    inputRouteName = session.currentRoute.inputs.map { "\($0.portName) (\($0.portType.rawValue))" }
      .joined(separator: ", ")
    let outputs = session.currentRoute.outputs
    isOnGlasses = session.currentRoute.inputs.contains { $0.portType == .bluetoothHFP }
      && outputs.contains { $0.portType == .bluetoothHFP }
    sbsiLog("audio route: in=\(inputRouteName) out=\(outputs.map(\.portName).joined(separator: ", ")) mic=\(inFormat.sampleRate) Hz")
  }

  private func stopEngine() {
    engine.inputNode.removeTap(onBus: 0)
    player.stop()
    engine.stop()
    resetQueue()
  }

  private func restart(reason: String) {
    guard running else { return }
    sbsiLog("audio restart: \(reason)")
    stopEngine()
    preferGlassesInput()
    do {
      try startEngine()
      onRouteNote?(isOnGlasses ? "Audio reconnected to glasses" : "Audio is on the iPhone (\(inputRouteName))")
    } catch {
      sbsiLog("audio restart failed: \(error)")
      onRouteNote?("Audio restart failed: \(error.localizedDescription)")
    }
  }

  private func preferGlassesInput() {
    let session = AVAudioSession.sharedInstance()
    if let glasses = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
      try? session.setPreferredInput(glasses)
    }
  }

  private func resetQueue() {
    lock.lock()
    scheduledBuffers = 0
    queuedUntil = .distantPast
    lock.unlock()
  }

  private func handleMic(_ buffer: AVAudioPCMBuffer) {
    guard let converter else { return }
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
    let count = Int(out.frameLength)
    let db = Self.levelDb(ch[0], count: count)
    let playing = isPlaying
    trackLevel(db, playing: playing)
    if muteMic || (playing && echoGateDb.map { db < $0 } == true) {
      onMicAudio?(Data(count: count * 2))  // silence keeps the audio timeline continuous
      return
    }
    onMicAudio?(Data(bytes: ch[0], count: count * 2))
  }

  private static func levelDb(_ samples: UnsafePointer<Int16>, count: Int) -> Float {
    var sum: Float = 0
    for i in 0..<count {
      let v = Float(samples[i]) / 32768
      sum += v * v
    }
    let rms = (sum / Float(max(count, 1))).squareRoot()
    return 20 * log10(max(rms, 1e-6))
  }

  private func trackLevel(_ db: Float, playing: Bool) {
    if playing { peakDbWhilePlaying = max(peakDbWhilePlaying, db) } else { peakDbWhileQuiet = max(peakDbWhileQuiet, db) }
    guard Date().timeIntervalSince(lastLevelLog) >= 10 else { return }
    sbsiLog(String(format: "mic peak dBFS (10 s): guide speaking %.0f, otherwise %.0f, gate %@",
                   peakDbWhilePlaying, peakDbWhileQuiet, echoGateDb.map { String(format: "%.0f", $0) } ?? "off"))
    peakDbWhilePlaying = -120
    peakDbWhileQuiet = -120
    lastLevelLog = Date()
  }
}
