import MWDATCamera
import MWDATCore
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

  /// Most recent decoded frame and a counter so consumers can tell when it changed.
  private(set) var latestFrame: UIImage?
  private(set) var frameNumber = 0

  @ObservationIgnored private let wearables: WearablesInterface
  @ObservationIgnored private let deviceSelector: AutoDeviceSelector
  @ObservationIgnored private var session: DeviceSession?
  @ObservationIgnored private var camera: MWDATCamera.Camera?
  @ObservationIgnored private var sessionTokens = ListenerTokenBag()
  @ObservationIgnored private var streamTokens = ListenerTokenBag()
  @ObservationIgnored private var registrationTask: Task<Void, Never>?
  @ObservationIgnored private var lastPreviewUpdate = Date.distantPast
  @ObservationIgnored private var photoContinuation: CheckedContinuation<Data?, Never>?

  var isStreaming: Bool { streamState == .streaming }

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
  func start() {
    guard session == nil else { return }
    lastError = nil
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
    } catch {
      report("Couldn't start glasses session: \(error)")
      teardown()
    }
  }

  func stop() {
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
    switch state {
    case .started:
      Task { await startStream() }
    case .stopped:
      teardown()
    default:
      break
    }
  }

  private func handleSessionError(_ error: DeviceSessionError) {
    sbsiLog("glasses session error: \(error)")
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
      // raw codec so frames convert straight to UIImage. We only sample ~1 frame every few
      // seconds for the model, so a modest frame rate is plenty for the on-screen preview.
      let config = StreamConfiguration(videoCodec: .raw, resolution: .high, frameRate: 15)
      guard let newCamera = try session.addCamera(config: config) else {
        report("Couldn't create the glasses camera.")
        return
      }
      camera = newCamera
      newCamera.stream.statePublisher.listen { [weak self] state in
        Task { @MainActor in self?.handleStreamState(state) }
      }.store(in: streamTokens)
      newCamera.stream.errorPublisher.listen { [weak self] error in
        Task { @MainActor in self?.report("Stream error: \(error)") }
      }.store(in: streamTokens)
      newCamera.stream.photoDataPublisher.listen { [weak self] photo in
        Task { @MainActor in self?.finishPhoto(photo.data) }
      }.store(in: streamTokens)
      newCamera.stream.videoFramePublisher.listen { [weak self] frame in
        guard let image = frame.makeUIImage() else { return }
        Task { @MainActor in self?.handleFrame(image) }
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
    if state == .stopped {
      streamTokens = ListenerTokenBag()
      camera = nil
    }
  }

  private func handleFrame(_ image: UIImage) {
    newestFrame = image
    newestFrameNumber += 1
    // The preview only needs a few updates per second; avoid re-rendering SwiftUI at 15 fps.
    let now = Date()
    if now.timeIntervalSince(lastPreviewUpdate) > 0.2 {
      latestFrame = image
      frameNumber = newestFrameNumber
      lastPreviewUpdate = now
    }
  }

  // MARK: - Photo

  /// Takes a full-resolution still on the glasses while the stream keeps running.
  /// Returns JPEG data, or nil if capture failed or timed out.
  func capturePhoto(timeout: Duration = .seconds(10)) async -> Data? {
    guard let camera, isStreaming, photoContinuation == nil else { return nil }
    return await withCheckedContinuation { continuation in
      photoContinuation = continuation
      guard camera.stream.capturePhoto(format: .jpeg) else {
        finishPhoto(nil)
        return
      }
      Task { [weak self] in
        try? await Task.sleep(for: timeout)
        self?.finishPhoto(nil)
      }
    }
  }

  private func finishPhoto(_ data: Data?) {
    guard let continuation = photoContinuation else { return }
    photoContinuation = nil
    sbsiLog("photo captured: \(data.map { "\($0.count / 1024) KB" } ?? "failed")")
    continuation.resume(returning: data)
  }

  /// Newest frame (updated at full rate, not observed by SwiftUI), for sending to the model.
  @ObservationIgnored private(set) var newestFrame: UIImage?
  @ObservationIgnored private(set) var newestFrameNumber = 0

  private func teardown() {
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
