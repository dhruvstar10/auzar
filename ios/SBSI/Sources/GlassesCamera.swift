import MWDATCamera
import MWDATCore
import NetworkExtension
import Observation
import UIKit

/// Owns the connection to the glasses: registration, device session and camera stream.
///
/// Lessons baked in (see docs/setup/01-meta-wearables-setup.md):
/// - Do NOT end the session when the app backgrounds; with the `external-accessory` background
///   mode the stream keeps running while the phone is locked.
/// - Handle `datAppOnTheGlassesUpdateRequired` by opening the Meta AI app's install page.
@Observable
@MainActor
final class GlassesCamera {
  var registrationState: RegistrationState
  var sessionState: DeviceSessionState = .idle
  var streamState: StreamState = .stopped
  var lastError: String?
  var needsGlassesAppUpdate = false

  /// True once video frames are arriving (the preview itself is drawn by `videoSink`).
  private(set) var hasVideo = false
  /// Full-rate preview: compressed frames go straight to a hardware display layer.
  @ObservationIgnored let videoSink = VideoSink()

  @ObservationIgnored private let wearables: WearablesInterface
  @ObservationIgnored private let deviceSelector: AutoDeviceSelector
  @ObservationIgnored private var session: DeviceSession?
  @ObservationIgnored private var camera: MWDATCamera.Camera?
  @ObservationIgnored private var sessionTokens = ListenerTokenBag()
  @ObservationIgnored private var streamTokens = ListenerTokenBag()
  @ObservationIgnored private var registrationTask: Task<Void, Never>?
  @ObservationIgnored private let decodeQueue = DispatchQueue(label: "sbsi.video-decode")
  /// Frames per second received from the glasses over the last couple of seconds (shown in the UI).
  private(set) var frameRate: Double = 0
  @ObservationIgnored private var rateWindowStart = Date()
  @ObservationIgnored private var rateWindowFrames = 0
  @ObservationIgnored private var lastRateLog = Date.distantPast
  @ObservationIgnored private var photoContinuation: CheckedContinuation<Data?, Never>?
  @ObservationIgnored private var photoWaitID = 0
  /// Full-quality stills via the experimental `camera.photo` (4032x3024) instead of the quick
  /// 1080x1440 `stream.capturePhoto`, whose small print is unreadable even up close. Detail test
  /// (2026-10-26): 12 MP read every label line at arm's length; ~1.1-1.4 MB, ~19 s total, video off
  /// meanwhile (an earlier run was ~23 KB/s, so allow up to 120 s).
  var fullResPhotos = true
  /// What the current photo is doing (e.g. "Transferring 32% of 1413 KB · 12 s"), shown in the UI; nil when idle.
  private(set) var photoStatus: String?
  @ObservationIgnored private var transferStartHandler: (() -> Void)?
  // Transfer diagnostics: 12 MP transfers ranged 16-75 KB/s for no known reason (2026-10-26).
  @ObservationIgnored private var transferSamples: [(time: Date, bytes: Double)] = []
  @ObservationIgnored private var photoStartedAt = Date()
  // Per Meta's docs: stop the stream, start Photo, capture, stop Photo, then restart the stream.
  // Restarting the stream while Photo was still started gave videoStreamingError and killed video.
  @ObservationIgnored private var photoTokens = ListenerTokenBag()
  @ObservationIgnored private var photoState: PhotoState = .stopped
  @ObservationIgnored private var photoListening = false
  @ObservationIgnored private var stopRequested = false
  @ObservationIgnored private var streamSetAside = false
  @ObservationIgnored private var lastProgressLog = Date.distantPast

  var isStreaming: Bool { streamState == .streaming }
  /// The glasses paused the camera (a tap on the side does this). They resume on their own or
  /// with another tap; per Meta's docs the app must not restart while paused.
  var isPaused: Bool { streamState == .paused || sessionState == .paused }
  /// Called when the camera pauses (true) or resumes (false).
  @ObservationIgnored var onPausedChange: ((Bool) -> Void)?
  /// Called when the glasses end the session on their own (not Stop or restart), e.g.
  /// "Session ended by device" mid-task (2026-10-27). The app should reconnect.
  @ObservationIgnored var onSessionLost: ((String) -> Void)?
  /// Called when video starts streaming (after a start, photo or reconnect).
  @ObservationIgnored var onStreaming: (() -> Void)?
  @ObservationIgnored private var lastSessionError: String?
  @ObservationIgnored private var lastDeviceState: DeviceState?
  @ObservationIgnored private var wasPaused = false
  @ObservationIgnored private var restartPending = false

  init(wearables: WearablesInterface = Wearables.shared) {
    self.wearables = wearables
    self.deviceSelector = AutoDeviceSelector(wearables: wearables)
    self.registrationState = wearables.registrationState
    registrationTask = Task { [weak self] in
      for await state in wearables.registrationStateStream() {
        self?.registrationState = state
      }
    }
  }

  func register() {
    Task {
      do {
        try await wearables.startRegistration()
      } catch {
        report("Registration failed: \(error)")
      }
    }
  }

  /// Starts a device session, then the camera stream once the session is up.
  /// Returns false (with `lastError` set) if no glasses are available or a session is still closing.
  @discardableResult
  func start() -> Bool {
    guard session == nil else {
      report("Glasses session is still closing. Wait a moment and try again.")
      return false
    }
    lastError = nil
    stopRequested = false
    resetFrameRate()
    do {
      let newSession = try wearables.createSession(deviceSelector: deviceSelector)
      session = newSession
      newSession.statePublisher.listen { [weak self] state in
        Task { @MainActor in self?.handleSessionState(state) }
      }.store(in: sessionTokens)
      newSession.errorPublisher.listen { [weak self] error in
        Task { @MainActor in self?.handleSessionError(error) }
      }.store(in: sessionTokens)
      sessionState = .starting
      try newSession.start()
      return true
    } catch {
      let text = "\(error)"
      report(text.contains("noEligibleDevice")
        ? "Glasses not connected. Unfold them, put them on (or tap the side), check they're connected in Meta AI, then press Start again."
        : "Couldn't start glasses session: \(text)")
      teardown()
      return false
    }
  }

  func stop() {
    stopRequested = true
    restartPending = false
    if photoState != .stopped { camera?.photo.stop() }  // Meta: stop Photo before Camera
    camera?.stop()
    session?.stop()
  }

  /// Fully stop and start again. Used to get out of a pause the glasses don't resume from
  /// (seen after sliding on the touchpad to change volume, 2026-10-24). Meta's docs say not to
  /// *restart* while paused; a full stop then a fresh start is the allowed route.
  func restart() {
    guard session != nil else {
      start()
      return
    }
    sbsiLog("glasses: restarting session")
    restartPending = true
    if photoState != .stopped { camera?.photo.stop() }
    camera?.stop()
    session?.stop()
  }

  func openGlassesAppUpdate() {
    needsGlassesAppUpdate = false
    Task {
      do {
        try await wearables.openDATGlassesAppUpdate()
      } catch {
        report("Couldn't open glasses app update: \(error)")
      }
    }
  }

  // MARK: - Session

  private func handleSessionState(_ state: DeviceSessionState) {
    sbsiLog("glasses session -> \(state.description)")
    sessionState = state
    notifyPauseIfChanged()
    switch state {
    case .started:
      listenToDeviceState()
      Task { await startStream() }
    case .stopped:
      let lost = !stopRequested && !restartPending
      teardown()
      if lost {
        sbsiLog("glasses: session lost (\(lastSessionError ?? "no error"))")
        onSessionLost?(lastSessionError ?? "The glasses ended the session.")
      }
      lastSessionError = nil
      if restartPending {
        restartPending = false
        Task { @MainActor in
          try? await Task.sleep(for: .seconds(1))
          self.start()
        }
      }
    default:
      break
    }
  }

  /// Log glasses state changes (worn, hinge, battery, thermal, link) to explain session drops.
  private func listenToDeviceState() {
    guard let device = session?.device else { return }
    lastDeviceState = nil
    device.addDeviceStateListener { [weak self] state in
      Task { @MainActor in
        guard let self, state != self.lastDeviceState else { return }
        self.lastDeviceState = state
        sbsiLog("glasses state: worn=\(state.donState) hinge=\(state.hingeState) battery=\(state.batteryLevel.map { "\($0)%" } ?? "?") "
                + "\(state.chargingState) thermal=\(state.thermalLevel) link=\(state.linkState)")
      }
    }.store(in: sessionTokens)
  }

  private func handleSessionError(_ error: DeviceSessionError) {
    sbsiLog("glasses session error: \(error)")
    lastSessionError = error.description
    if case .datAppOnTheGlassesUpdateRequired = error {
      needsGlassesAppUpdate = true
    }
    report(error.description)
  }

  // MARK: - Stream

  private func startStream() async {
    guard let session, camera == nil else { return }
    do {
      if try await wearables.checkPermissionStatus(.camera) != .granted {
        guard try await wearables.requestPermission(.camera) == .granted else {
          report("Camera permission denied in the Meta AI app.")
          return
        }
      }
      // Compressed HEVC, decoded ourselves (VideoDecoder). `.raw` saturated the glasses link:
      // the SDK cut it to 504x896 even at 2 fps, video stalled, and photos timed out
      // (field tests, 2026-10-24/25). The Meta sample's hvc1 @ 24 fps held 720x1280. hvc1 is also
      // the codec Meta documents as continuing in the background. Valid rates: 2, 7, 15, 24, 30.
      let config = StreamConfiguration(videoCodec: .hvc1, resolution: .high, frameRate: 15)
      guard let newCamera = try session.addCamera(config: config) else {
        report("Couldn't create the glasses camera.")
        return
      }
      camera = newCamera
      newCamera.stream.statePublisher.listen { [weak self] state in
        Task { @MainActor in self?.handleStreamState(state) }
      }.store(in: streamTokens)
      newCamera.stream.errorPublisher.listen { [weak self] error in
        Task { @MainActor in self?.report("Glasses video error: \(error). If video stops, press Stop, wait 3 s, Start again.") }
      }.store(in: streamTokens)
      newCamera.stream.photoDataPublisher.listen { [weak self] photo in
        Task { @MainActor in self?.finishPhoto(photo.data) }
      }.store(in: streamTokens)
      let decoder = VideoDecoder()
      let queue = decodeQueue
      let sink = videoSink
      sink.flush()
      var lastImage = Date.distantPast  // only touched on `queue`
      newCamera.stream.videoFramePublisher.listen { [weak self] frame in
        let buffer = frame.sampleBuffer
        sink.enqueue(buffer)
        queue.async {
          // Decode every frame (HEVC needs them all) but only build ~2 images/s, for the model
          // (one per 2 s by default) and the photo fallback. The preview no longer uses these.
          let now = Date()
          let wantImage = now.timeIntervalSince(lastImage) >= 0.5
          if wantImage { lastImage = now }
          decoder.decode(buffer, wantImage: wantImage) { image in
            Task { @MainActor in self?.handleFrame(image) }
          }
          Task { @MainActor in self?.countFrameForRate() }
        }
      }.store(in: streamTokens)
      streamState = .starting
      newCamera.stream.start()
    } catch {
      report("Couldn't start the camera stream: \(error)")
    }
  }

  private func handleStreamState(_ state: StreamState) {
    sbsiLog("glasses stream -> \(state)")
    streamState = state
    notifyPauseIfChanged()
    // Video is back: clear a stale video error so the banner doesn't contradict the live picture.
    if state == .streaming, lastError?.hasPrefix("Glasses video error") == true { lastError = nil }
    if state == .streaming && !streamSetAside { onStreaming?() }
    // Stopped on purpose for a photo: keep the camera and listeners, it comes straight back.
    if state == .stopped && !streamSetAside {
      streamTokens = ListenerTokenBag()
      photoTokens = ListenerTokenBag()
      photoState = .stopped
      photoListening = false
      camera = nil
      // Stopped on its own mid-session (e.g. a videoStreamingError): get video back.
      if sessionState == .started && !restartPending && !stopRequested {
        sbsiLog("glasses: stream stopped unexpectedly, restarting it")
        Task { @MainActor in
          try? await Task.sleep(for: .seconds(1))
          await self.startStream()
        }
      }
    }
  }

  private func listenToPhoto(_ photo: Photo) {
    guard !photoListening else { return }
    photoListening = true
    photo.statePublisher.listen { [weak self] state in
      Task { @MainActor in
        sbsiLog("glasses photo -> \(state)")
        self?.photoState = state
      }
    }.store(in: photoTokens)
    photo.photoDataPublisher.listen { [weak self] data in
      Task { @MainActor in self?.finishPhoto(data.imageData) }
    }.store(in: photoTokens)
    photo.errorPublisher.listen { [weak self] error in
      Task { @MainActor in
        sbsiLog("glasses photo error: \(error)")
        self?.finishPhoto(nil)
      }
    }.store(in: photoTokens)
    photo.transferProgressPublisher.listen { [weak self] progress in
      Task { @MainActor in
        guard let self else { return }
        self.transferSamples.append((Date(), progress.fraction * Double(progress.totalBytes)))
        if let handler = self.transferStartHandler {
          self.transferStartHandler = nil
          handler()
        }
        self.photoStatus = String(format: "Transferring %.0f%% of %d KB · %.0f s", progress.fraction * 100,
                                  Int(progress.totalBytes / 1024), Date().timeIntervalSince(self.photoStartedAt))
        guard Date().timeIntervalSince(self.lastProgressLog) > 2 else { return }
        self.lastProgressLog = Date()
        sbsiLog(String(format: "photo transfer %.0f%% of %d KB", progress.fraction * 100, Int(progress.totalBytes / 1024)))
      }
    }.store(in: photoTokens)
  }

  /// Waits until `condition` holds or `seconds` pass; returns whether it held.
  private func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
      if Date() >= deadline { return false }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return true
  }

  /// Called ~2 times a second with a decoded frame (throttled in the decode queue).
  private func handleFrame(_ image: UIImage) {
    newestFrame = image
    newestFrameNumber += 1
    if !hasVideo { hasVideo = true }
  }

  private func notifyPauseIfChanged() {
    let paused = isPaused
    guard paused != wasPaused else { return }
    wasPaused = paused
    onPausedChange?(paused)
  }

  // MARK: - Photo

  /// Why a photo can't be taken right now, in words the model can relay; nil if it can.
  var photoUnavailableReason: String? {
    if isPaused {
      return "The glasses camera is paused (touching the side of the glasses, even to change volume, can do this). The app is restarting the camera; ask the user to wait a few seconds and try again."
    }
    if camera == nil || !isStreaming { return "The glasses camera isn't streaming right now (state: \(streamState))." }
    if photoContinuation != nil { return "A photo is already being taken." }
    return nil
  }

  /// Takes a still: 12 MP via `camera.photo` (default; video stops ~20 s), or the quick 1080x1440
  /// in-stream capture when `quick` or `fullResPhotos` is off. Falls back to quick if 12 MP fails.
  /// `onTransferStart` fires when a 12 MP shutter has fired and the user can move.
  /// Returns JPEG/HEIC data, or nil (check `photoUnavailableReason` first).
  func capturePhoto(quick: Bool = false, onTransferStart: @escaping () -> Void = {}) async -> Data? {
    guard camera != nil, photoUnavailableReason == nil else { return nil }
    if !quick && fullResPhotos, let data = await fullStill(onTransferStart: onTransferStart) { return data }
    guard let camera, await waitUntil(10, { isStreaming }) else { return nil }
    photoStatus = "Quick photo: capturing…"
    defer { photoStatus = nil }
    let started = Date()
    let data = await waitForPhoto(timeout: .seconds(15)) { camera.stream.capturePhoto(format: .jpeg) }
    sbsiLog(String(format: "quick photo took %.1f s (video %@)", Date().timeIntervalSince(started),
                   newestFrame.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "?"))
    return data
  }

  /// One `camera.photo` capture, logging size, timing and the network link. With `stopStream`
  /// false, Photo runs alongside the stream (Meta says they compete for the sensor; untested).
  private func captureStill(_ camera: MWDATCamera.Camera, resolution: PhotoResolution, quality: PhotoQuality,
                            stopStream: Bool, timeout: Duration = .seconds(120)) async -> Data? {
    let label = "\(resolution.rawValue)/\(quality.rawValue)\(stopStream ? ", stream stopped" : ", stream running")"
    let started = Date()
    photoStartedAt = started
    transferSamples = []
    sbsiLog("photo-diag before: \(diagnosticsSnapshot())")
    photoStatus = "Photo \(resolution.rawValue): starting…"
    defer { photoStatus = nil }
    if stopStream {
      photoStatus = "Photo \(resolution.rawValue): pausing video…"
      streamSetAside = true
      camera.stream.stop()
      _ = await waitUntil(3) { streamState == .stopped }
    }
    await logLink("photo \(label): before")
    listenToPhoto(camera.photo)
    camera.photo.start()
    var data: Data?
    if await waitUntil(5, { photoState == .started }) {
      // captureFailure sometimes comes back within ~0.1 s of the request (cause unknown, 2026-10-26);
      // a quick failure gets one retry.
      for attempt in 1...2 {
        photoStatus = "Photo \(resolution.rawValue): capturing…"
        let attemptStart = Date()
        data = await waitForPhoto(timeout: timeout) {
          camera.photo.capturePhoto(resolution: resolution, quality: quality)
          return true
        }
        guard data == nil, attempt == 1, Date().timeIntervalSince(attemptStart) < 3, photoState == .started else { break }
        sbsiLog("photo \(label): failed fast, retrying in 1 s")
        try? await Task.sleep(for: .seconds(1))
      }
    } else {
      sbsiLog("photo \(label): Photo didn't start (state \(photoState))")
    }
    sbsiLog("photo-diag transfer: \(transferSummary(since: started))")
    sbsiLog("photo-diag after: \(diagnosticsSnapshot())")
    let seconds = Date().timeIntervalSince(started)
    let kb = (data?.count ?? 0) / 1024
    sbsiLog(String(format: "photo %@: %@ in %.1f s (%.0f KB/s)", label, data == nil ? "FAILED" : "\(kb) KB", seconds,
                   Double(kb) / max(seconds, 0.1)))
    await logLink("photo \(label): after")
    photoStatus = "Photo \(resolution.rawValue): restarting video…"
    camera.photo.stop()
    _ = await waitUntil(3) { photoState == .stopped }
    streamSetAside = false
    // Restarting the same stream after Photo failed with videoStreamingError every time, while a
    // fresh camera (what the unexpected-stop restart does) worked within ~1 s (2026-10-26).
    // So drop this camera and build a new one.
    if self.camera === camera && sessionState == .started {
      // The old camera must be fully stopped first, or addCamera throws capabilityAlreadyActive.
      camera.stop()
      if !(await waitUntil(3, { camera.state == .stopped })) { sbsiLog("photo: old camera still \(camera.state)") }
      streamTokens = ListenerTokenBag()
      photoTokens = ListenerTokenBag()
      photoState = .stopped
      photoListening = false
      self.camera = nil
      await startStream()
      // Last resort so video never stays dead after a photo (seen 2026-10-26): full session restart.
      if !(await waitUntil(6, { streamState == .streaming })) {
        sbsiLog("photo: video didn't come back, restarting the glasses session")
        restart()
      }
    }
    return data
  }

  /// Glasses + phone conditions that might explain slow photo transfers, as one log line.
  private func diagnosticsSnapshot() -> String {
    var parts: [String] = []
    if let device = session?.device {
      parts.append("glasses battery=\(device.batteryLevel.map { "\($0)%" } ?? "?") \(device.chargingState)")
      parts.append("thermal=\(device.thermalLevel) worn=\(device.donState) hinge=\(device.hingeState) link=\(device.linkState)")
    }
    // The SDK lowers video resolution (720x1280 -> 504x896) when the link is congested.
    let size = newestFrame?.size ?? .zero
    parts.append(String(format: "video %dx%d @ %.0f fps", Int(size.width), Int(size.height), frameRate))
    UIDevice.current.isBatteryMonitoringEnabled = true
    let app = UIApplication.shared.applicationState
    parts.append(String(format: "phone battery=%.0f%%%@ thermal=%@ app=%@",
                        UIDevice.current.batteryLevel * 100,
                        ProcessInfo.processInfo.isLowPowerModeEnabled ? " lowPower" : "",
                        "\(ProcessInfo.processInfo.thermalState.rawValue)",
                        app == .active ? "foreground" : app == .background ? "background" : "inactive"))
    return parts.joined(separator: ", ")
  }

  /// Time to first byte and transfer speed over the photo, with the slowest and fastest stretches.
  private func transferSummary(since start: Date) -> String {
    guard let first = transferSamples.first, let last = transferSamples.last else { return "no transfer progress" }
    let seconds = last.time.timeIntervalSince(first.time)
    var rates: [Double] = []
    var anchor = first
    for sample in transferSamples.dropFirst() where sample.time.timeIntervalSince(anchor.time) >= 3 {
      rates.append((sample.bytes - anchor.bytes) / 1024 / sample.time.timeIntervalSince(anchor.time))
      anchor = sample
    }
    return String(format: "first byte after %.1f s, %.0f KB in %.1f s (%.0f KB/s), 3 s windows %.0f-%.0f KB/s, %d updates",
                  first.time.timeIntervalSince(start), (last.bytes - first.bytes) / 1024, seconds,
                  (last.bytes - first.bytes) / 1024 / max(seconds, 0.1),
                  rates.min() ?? 0, rates.max() ?? 0, transferSamples.count)
  }

  /// Which link is up: the SDK's link state, and the Wi-Fi network iOS is on (the glasses' own
  /// network while their Wi-Fi link is in use).
  private func logLink(_ context: String) async {
    let link = session?.device.map { "\($0.linkState)" } ?? "?"
    let ssid = await NEHotspotNetwork.fetchCurrent()?.ssid ?? "none"
    sbsiLog("\(context): link=\(link) wifi=\(ssid) stream=\(streamState)")
  }

  /// Quick 1080x1440 in-stream still, regardless of `fullResPhotos` (detail test).
  func quickStill() async -> Data? {
    guard let camera, isStreaming, photoContinuation == nil else { return nil }
    return await waitForPhoto(timeout: .seconds(15)) { camera.stream.capturePhoto(format: .jpeg) }
  }

  /// 12 MP `camera.photo` still (HEIC). `onTransferStart` fires once the image starts coming over,
  /// i.e. the shutter has fired and the user can move (detail test).
  func fullStill(onTransferStart: @escaping () -> Void) async -> Data? {
    guard await waitUntil(10, { isStreaming }), let camera, photoContinuation == nil else { return nil }
    transferStartHandler = onTransferStart
    defer { transferStartHandler = nil }
    return await captureStill(camera, resolution: .full, quality: .high, stopStream: true)
  }

  private func waitForPhoto(timeout: Duration, trigger: () -> Bool) async -> Data? {
    await withCheckedContinuation { continuation in
      photoContinuation = continuation
      guard trigger() else {
        finishPhoto(nil)
        return
      }
      // Only time out *this* photo: a stale 15 s timer from an earlier quick photo once killed a
      // 12 MP transfer mid-way (2026-10-26).
      photoWaitID += 1
      let id = photoWaitID
      Task { [weak self] in
        try? await Task.sleep(for: timeout)
        guard let self, self.photoWaitID == id else { return }
        if self.photoContinuation != nil { sbsiLog("photo: timed out after \(timeout)") }
        self.finishPhoto(nil)
      }
    }
  }

  private func finishPhoto(_ data: Data?) {
    guard let continuation = photoContinuation else { return }
    photoContinuation = nil
    let dims = data.flatMap { UIImage(data: $0) }.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? ""
    sbsiLog("photo captured: \(data.map { "\($0.count / 1024) KB \(dims)" } ?? "failed")")
    continuation.resume(returning: data)
  }

  /// Newest frame (updated at full rate, not observed by SwiftUI), for sending to the model.
  @ObservationIgnored private(set) var newestFrame: UIImage?
  @ObservationIgnored private(set) var newestFrameNumber = 0

  private func countFrameForRate() {
    rateWindowFrames += 1
    let now = Date()
    let elapsed = now.timeIntervalSince(rateWindowStart)
    guard elapsed >= 2 else { return }
    frameRate = Double(rateWindowFrames) / elapsed
    rateWindowFrames = 0
    rateWindowStart = now
    if now.timeIntervalSince(lastRateLog) >= 10 {
      let size = newestFrame?.size ?? .zero
      sbsiLog(String(format: "glasses video: %.1f fps, %dx%d", frameRate, Int(size.width), Int(size.height)))
      lastRateLog = now
    }
  }

  private func resetFrameRate() {
    frameRate = 0
    rateWindowFrames = 0
    rateWindowStart = Date()
  }

  private func teardown() {
    hasVideo = false
    videoSink.flush()
    photoTokens = ListenerTokenBag()
    photoState = .stopped
    photoListening = false
    streamSetAside = false
    frameRate = 0
    wasPaused = false
    finishPhoto(nil)
    streamTokens = ListenerTokenBag()
    sessionTokens = ListenerTokenBag()
    camera = nil
    session = nil
    streamState = .stopped
  }

  private func report(_ message: String) {
    sbsiLog("glasses: \(message)")
    lastError = message
  }
}
