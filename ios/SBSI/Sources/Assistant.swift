import Observation
import UIKit

/// Glues the glasses camera, audio and the realtime model together.
///
/// Flow: mic audio streams continuously (server-side voice activity detection decides turns);
/// every `frameInterval` seconds the newest glasses frame is added to the conversation as an
/// image item (only the last `maxImagesInContext` are kept, to bound cost); every
/// `proactiveInterval` seconds an out-of-band text-only check asks the model whether to speak up.
@Observable
@MainActor
final class Assistant {
  struct Line: Identifiable {
    let id = UUID()
    let who: String
    let text: String
  }

  // Settings (exposed in the UI).
  var frameInterval: Double = 2
  var proactiveEnabled = true
  /// Mic level (dBFS) the user must exceed to interrupt the guide; see AudioIO.echoGateDb.
  var interruptThresholdDb: Double = -30 {
    didSet { audio.echoGateDb = Float(interruptThresholdDb) }
  }

  // State shown in the UI.
  private(set) var isRunning = false
  private(set) var aiStatus = "idle"
  private(set) var lines: [Line] = []
  private(set) var imagesSent = 0
  private(set) var inputTokens = 0
  private(set) var outputTokens = 0
  private(set) var imageTokens = 0
  /// Last high-res photo the model took, shown in the UI.
  private(set) var lastPhoto: UIImage?

  let glasses = GlassesCamera()

  @ObservationIgnored private let audio = AudioIO()
  @ObservationIgnored private let realtime = RealtimeClient()
  @ObservationIgnored private var config: AppConfig?
  @ObservationIgnored private var speechStarts = 0
  /// The glasses ended the session mid-task; reconnecting. The model must not claim to see anything.
  @ObservationIgnored private var cameraLost = false
  @ObservationIgnored private var reconnectTask: Task<Void, Never>?
  /// Last thing the user said, passed to the vision model as the question behind a photo.
  @ObservationIgnored private var lastUserText = ""
  @ObservationIgnored private var frameTimer: Timer?
  @ObservationIgnored private var proactiveTimer: Timer?
  @ObservationIgnored private var lastSentFrameNumber = -1
  @ObservationIgnored private var lastProactiveFrameNumber = -1
  @ObservationIgnored private var imageItemIDs: [String] = []
  @ObservationIgnored private var responseInProgress = false
  @ObservationIgnored private var userSpeaking = false
  @ObservationIgnored private var lastActivity = Date()
  @ObservationIgnored private var assistantHasSpoken = false
  @ObservationIgnored private var assistantTranscript = ""
  @ObservationIgnored private var photoItemID: String?
  @ObservationIgnored private var photosTaken = 0
  @ObservationIgnored private var lastPhotoTime = Date.distantPast
  @ObservationIgnored private var photoInFlight = false
  @ObservationIgnored private var media: SessionMedia?
  /// Ignore Start/Stop taps closer together than this (a double tap left the camera off).
  @ObservationIgnored private var lastToggle = Date.distantPast
  @ObservationIgnored private var pauseRestartTask: Task<Void, Never>?
  private let pauseRestartDelay: TimeInterval = 5

  private let maxImagesInContext = 3
  private let proactiveInterval: TimeInterval = 8
  private let quietPeriodBeforeProactive: TimeInterval = 5

  init() {
    realtime.onOpen = { [weak self] in self?.handleOpen() }
    realtime.onClose = { [weak self] reason in self?.handleClose(reason) }
    realtime.onEvent = { [weak self] event in self?.handle(event) }
    glasses.onPausedChange = { [weak self] paused in
      Task { @MainActor in self?.handleCameraPaused(paused) }
    }
    glasses.onSessionLost = { [weak self] reason in self?.handleSessionLost(reason) }
    glasses.onStreaming = { [weak self] in self?.handleStreamingResumed() }
    audio.onRouteNote = { [weak self] note in
      Task { @MainActor in self?.add("app", note) }
    }
    audio.onMicAudio = { [weak self] pcm in
      // Audio thread. Encoding + send is thread-safe on the client.
      self?.realtime.send(["type": "input_audio_buffer.append", "audio": pcm.base64EncodedString()])
    }
  }

  // MARK: - Start / stop

  func start() {
    guard !isRunning, Date().timeIntervalSince(lastToggle) > 2 else { return }
    lastToggle = Date()
    guard let config = AppConfig.load() else {
      add("app", "Azure settings missing. Run tools/gen_ios_secrets.sh and rebuild.")
      return
    }
    self.config = config
    isRunning = true
    lines.removeAll()
    imagesSent = 0
    inputTokens = 0
    outputTokens = 0
    imageTokens = 0
    imageItemIDs.removeAll()
    photoItemID = nil
    photosTaken = 0
    media = SessionMedia()
    assistantHasSpoken = false

    // Without the glasses there's no video and audio falls back to the iPhone earpiece: don't
    // silently run blind. GlassesCamera has set a user-facing error.
    guard glasses.start() else {
      isRunning = false
      add("app", glasses.lastError ?? "Glasses not connected.")
      return
    }
    do {
      try audio.start()
      add("app", audio.isOnGlasses ? "Audio on glasses" : "Warning: audio is on the iPhone (\(audio.inputRouteName)), not the glasses")
    } catch {
      add("app", "Audio failed to start: \(error.localizedDescription)")
    }
    aiStatus = "connecting"
    realtime.connect(config: config)
  }

  func stop() {
    guard isRunning, Date().timeIntervalSince(lastToggle) > 1 else { return }
    lastToggle = Date()
    isRunning = false
    pauseRestartTask?.cancel()
    frameTimer?.invalidate()
    proactiveTimer?.invalidate()
    realtime.disconnect()
    audio.stop()
    reconnectTask?.cancel()
    cameraLost = false
    glasses.stop()
    aiStatus = "idle"
    sbsiLog("assistant stopped. images=\(imagesSent) in=\(inputTokens) out=\(outputTokens) imageTokens=\(imageTokens)")
  }

  // MARK: - Realtime session

  private func handleOpen() {
    aiStatus = "connected"
    sbsiLog("realtime connected")
    realtime.send([
      "type": "session.update",
      "session": [
        "type": "realtime",
        "instructions": Prompts.guide,
        "output_modalities": ["audio"],
        "audio": [
          "input": [
            "format": ["type": "audio/pcm", "rate": 24000],
            // Transcribe the user's speech for the on-screen log.
            "transcription": ["model": "whisper-1"],
            "turn_detection": [
              "type": "server_vad",
              "threshold": 0.5,
              "prefix_padding_ms": 300,
              "silence_duration_ms": 600,
              "create_response": true,
              "interrupt_response": true,
            ],
          ],
          "output": [
            "format": ["type": "audio/pcm", "rate": 24000],
            "voice": "alloy",
          ],
        ],
        "tools": Tools.definitions,
        "tool_choice": "auto",
      ],
    ])
    frameTimer = Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.sendFrameIfNew() }
    }
    proactiveTimer = Timer.scheduledTimer(withTimeInterval: proactiveInterval, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.proactiveCheckIfIdle() }
    }
    // Open with a short spoken greeting so the user knows it's live.
    realtime.send([
      "type": "response.create",
      "response": ["instructions": "Greet the user in one short sentence and ask what they'd like to work on."],
    ])
  }

  private func handleClose(_ reason: String) {
    sbsiLog("realtime closed: \(reason)")
    if isRunning {
      add("app", "AI connection closed: \(reason)")
      aiStatus = "disconnected"
    }
  }

  private func handle(_ event: [String: Any]) {
    let type = event["type"] as? String ?? ""
    switch type {
    case "session.created", "session.updated":
      sbsiLog(type)

    case "input_audio_buffer.speech_started":
      sbsiLog("server heard speech start")
      userSpeaking = true
      speechStarts += 1
      lastActivity = Date()
      // Barge-in: stop the guide talking as soon as the user speaks.
      audio.stopPlayback()

    case "input_audio_buffer.speech_stopped":
      userSpeaking = false
      lastActivity = Date()

    case "conversation.item.input_audio_transcription.completed":
      if let text = event["transcript"] as? String, !text.isEmpty {
        add("you", text)
        lastUserText = text
      } else {
        sbsiLog("you: (no words; noise or echo was taken as speech)")
      }

    case "response.created":
      // Two greetings were heard (2026-10-27) though the app asks for one; log who starts each response.
      let response = event["response"] as? [String: Any]
      let purpose = (response?["metadata"] as? [String: Any])?["purpose"] as? String
      sbsiLog("response started\(purpose.map { " (\($0))" } ?? "")")
      if purpose == nil, !assistantTranscript.isEmpty {
        add("guide", assistantTranscript)  // keep overlapping replies as separate lines
        assistantTranscript = ""
      }
      responseInProgress = true

    case "response.output_audio.delta":
      if let b64 = event["delta"] as? String, let pcm = Data(base64Encoded: b64) {
        audio.play(pcm16: pcm)
      }

    case "response.output_audio_transcript.delta":
      assistantTranscript += event["delta"] as? String ?? ""

    case "response.output_audio_transcript.done":
      if !assistantTranscript.isEmpty { add("guide", assistantTranscript) }
      assistantTranscript = ""
      assistantHasSpoken = true

    case "response.function_call_arguments.done":
      if let name = event["name"] as? String, let callID = event["call_id"] as? String {
        handleToolCall(name: name, callID: callID, arguments: event["arguments"] as? String ?? "{}")
      }

    case "response.done":
      responseInProgress = false
      lastActivity = Date()
      handleResponseDone(event["response"] as? [String: Any] ?? [:])

    case "error":
      let err = event["error"] as? [String: Any]
      let message = err?["message"] as? String ?? "\(event)"
      sbsiLog("realtime error: \(message)")
      // Cancelling when nothing is active is harmless; don't clutter the transcript with it.
      // Benign races (a proactive reply colliding with another response) aren't worth showing.
      if !(message.contains("no active response") || message.contains("already has an active response")) {
        add("error", message)
      }

    default:
      break
    }
  }

  private func handleResponseDone(_ response: [String: Any]) {
    if let usage = response["usage"] as? [String: Any] {
      inputTokens += usage["input_tokens"] as? Int ?? 0
      outputTokens += usage["output_tokens"] as? Int ?? 0
      let details = usage["input_token_details"] as? [String: Any]
      imageTokens += details?["image_tokens"] as? Int ?? 0
    }
    let metadata = response["metadata"] as? [String: Any]
    guard metadata?["purpose"] as? String == "proactive" else { return }

    // Out-of-band check result: read the forced proactive_decision call and, if needed, speak.
    let outputs = response["output"] as? [[String: Any]] ?? []
    let arguments = outputs.first { $0["name"] as? String == Tools.proactiveDecision }?["arguments"] as? String
    sbsiLog("proactive check: status=\(response["status"] as? String ?? "?") \(arguments ?? "no decision")")
    guard let data = arguments?.data(using: .utf8),
      let decision = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      decision["speak"] as? Bool == true, let say = decision["say"] as? String, !say.isEmpty,
      !userSpeaking, !responseInProgress
    else { return }
    realtime.send([
      "type": "response.create",
      "response": ["instructions": "Without waiting to be asked, tell the user briefly: \(say)"],
    ])
  }

  // MARK: - Tools

  private func handleToolCall(name: String, callID: String, arguments: String) {
    sbsiLog("tool call: \(name) \(arguments)")
    switch name {
    case Tools.endSession:
      // Let the guide say goodbye, then stop.
      sendToolOutput(callID: callID, output: "Ending the session now. Say a two- or three-word goodbye.")
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(3))
        self.stop()
      }
    case Tools.proactiveDecision:
      break  // handled from response.done of the out-of-band check
    case Tools.takePhoto:
      // The model sometimes asks again right after a photo arrives; reuse the fresh one.
      if photoInFlight {
        // Was the "already in the conversation" message below, so the model answered from old images
        // while a 12 MP photo was still transferring (2026-10-26).
        sendToolOutput(callID: callID, output: "A photo is still being taken and transferred; it will arrive in the conversation shortly. Don't take another. Tell the user it's still coming, in a few words.")
        sbsiLog("take_photo skipped: one is in flight")
      } else if photoItemID != nil && Date().timeIntervalSince(lastPhotoTime) < 8 {
        sendToolOutput(callID: callID, output: "You took a photo a few seconds ago; it is already in the conversation. Use it. Only take another if the user has moved or asks for one.")
        sbsiLog("take_photo skipped: duplicate")
      } else {
        let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any]
        let region = ZoomRegion(rawValue: args?["zoom"] as? String ?? "") ?? .center
        // Tiered (owner, 2026-10-26): quick by default; 12 MP only when asked for after the user agrees.
        let quick = args?["detail"] as? String != "full"
        let reason = args?["reason"] as? String ?? ""
        Task { await takePhoto(callID: callID, zoom: region, quick: quick, reason: reason) }
      }
    default:
      sendToolOutput(callID: callID, output: "Unknown tool \(name).")
    }
  }

  /// Captures a still on the glasses and adds it to the conversation.
  private func takePhoto(callID: String, zoom: ZoomRegion, quick: Bool, reason: String) async {
    if let reason = glasses.photoUnavailableReason {
      add("app", "Can't take photo: \(reason)")
      sendToolOutput(callID: callID, output: "Photo not taken. \(reason)")
      return
    }
    let full = !quick && glasses.fullResPhotos
    add("app", full ? "Taking a 12 MP photo (20–60 s, video off)…" : "Taking a quick photo…")
    photoInFlight = true
    defer { photoInFlight = false }
    let appState = UIApplication.shared.applicationState == .active ? "foreground" : "background/locked"
    var image: UIImage?
    var isFallback = false
    // Audio cues (owner, 2026-10-26): "hold still until the chime" left the user guessing through a
    // long silence. So: soft beeps while the photo is being taken, a chime when the shutter has fired,
    // then the guide's voice says the answer will take a while (transfer 17-70 s + ~5 s reading).
    // Audio cues the app owns (owner, 2026-10-26/27): an announcement saying which kind of photo,
    // soft beeps while it's being taken, then a clear outcome: chime + "Got it" (12 MP: "you can move,
    // processing… up to a minute") or a fail tone + "Sorry, the photo didn't come through". Beeps that
    // just stopped left the user guessing; a live spoken cue was once doubled. All pre-recorded.
    // Wait for the guide to finish first: the tool call arrives while its audio is still playing, and
    // the shutter cut it off mid-sentence (2026-10-27).
    func waitForQuiet(_ limit: Double = 8) async {
      let start = Date()
      while audio.isPlaying, Date().timeIntervalSince(start) < limit { try? await Task.sleep(for: .milliseconds(100)) }
    }
    systemNote("A photo is being taken now. Until its result arrives, if the user speaks, only say it's still coming; don't answer from older images.")
    await waitForQuiet()
    audio.play(full ? .fullStart : .quickStart)
    await waitForQuiet()
    let playedBefore = audio.playedSeconds, speechBefore = speechStarts, photoStart = Date()
    let beeper = Task { @MainActor [audio] in
      // A quick photo usually lands in ~2 s (the glasses play their own shutter sound), so only beep
      // if it's taking longer (owner, 2026-10-27). 12 MP beeps from the start.
      if quick { try? await Task.sleep(for: .seconds(3)) }
      while !Task.isCancelled {
        if !audio.isPlaying { audio.playBeep() }
        try? await Task.sleep(for: .milliseconds(700))
      }
    }
    let data = await glasses.capturePhoto(quick: quick) { [weak self] in
      // 12 MP: the shutter has fired; the transfer doesn't need the user to keep still.
      Task { @MainActor in
        guard let self else { return }
        beeper.cancel()
        self.audio.playChime()
        self.audio.play(.fullDone)
      }
    }
    sbsiLog(String(format: "photo-diag audio: %.1f s of guide audio and %d user utterances during the %.0f s photo; route %@",
                   audio.playedSeconds - playedBefore, speechStarts - speechBefore, Date().timeIntervalSince(photoStart),
                   audio.inputRouteName))
    let shutterCued = beeper.isCancelled
    beeper.cancel()
    if data == nil {
      audio.playFailTone()
      audio.play(.failed)
    } else if !shutterCued {
      audio.playChime()
      audio.play(.quickDone)
    }
    if let data, let photo = UIImage(data: data) {
      image = photo
      // camera.photo delivers HEIC (starts with an "ftyp" box), the in-stream photo JPEG.
      let isHEIC = data.count > 12 && data[4..<8].elementsEqual("ftyp".utf8)
      media?.save(data, as: "photos/photo\(photosTaken + 1)-original.\(isHEIC ? "heic" : "jpg")")
    } else if let frame = glasses.newestFrame {
      // Photo capture failed (seen with the phone locked in a pocket). Fall back to the newest
      // video frame at full stream resolution: softer than a photo, but sharper than the 768 px
      // frames the model normally gets.
      sbsiLog("photo failed (app \(appState)); sending newest video frame instead")
      add("app", "Photo failed; sent the sharpest video frame instead")
      image = frame
      isFallback = true
    }
    // The model downsizes every image to roughly 512 px (~323 tokens; "detail": "high" is ignored),
    // so it can't read small text from a whole 1080x1440 photo. So: read text/barcodes on-device
    // (PhotoReader) and pass them as text, and send an overview plus a zoom crop around the text.
    // A fixed centre crop missed hand-held labels, which sit low-right in the glasses' view (2026-10-26).
    guard let upright = image?.uprighted() else {
      sbsiLog("photo failed (app \(appState)), no frame to fall back to")
      add("app", "Photo failed")
      sendToolOutput(callID: callID, output: "The glasses didn't return a photo (capture error or timeout, not the user's fault). Say so briefly and offer to try once more.")
      return
    }
    let started = Date()
    let reading = await PhotoReader.read(upright)
    let zoomImage = reading.textRegion.map { upright.cropped(around: $0) } ?? upright.cropped(to: zoom)
    let zoomLabel = reading.textRegion != nil ? "close-up of the main label at full resolution" : "2x zoom of the \(zoom.rawValue) region"
    guard let overview = upright.scaled(maxSide: 1024).jpegData(compressionQuality: 0.85),
      let zoomed = zoomImage.jpegData(compressionQuality: 0.9)
    else { return }
    sbsiLog(String(format: "photo read on-device in %.2f s: %d lines (%d on the main label), %d barcodes, close-up %dx%d",
                   Date().timeIntervalSince(started), reading.lines.count, reading.mainLines.count, reading.barcodes.count,
                   Int(zoomImage.size.width), Int(zoomImage.size.height)))
    photosTaken += 1
    let itemID = "photo\(photosTaken)"
    media?.save(overview, as: "photos/photo\(photosTaken)-sent-overview.jpg")
    media?.save(zoomed, as: "photos/photo\(photosTaken)-sent-zoom.jpg")
    let ocrText = (["Main label (largest text and the lines around it):"] + reading.mainLines
      + (reading.barcodes.isEmpty ? [] : ["Barcodes:"] + reading.barcodes)
      + (reading.otherLines.isEmpty ? [] : ["Other text in view (often screens or background; ignore unless relevant):"] + reading.otherLines))
      .joined(separator: "\n")
    media?.save(Data(ocrText.utf8), as: "photos/photo\(photosTaken)-text.txt")
    // The function output must come right after the call; the photo follows as a user message.
    let what = isFallback
      ? "The full photo failed, so this comes from the newest video frame (softer than a real photo). If still unreadable, ask the user to take the phone out of their pocket and unlock it, then try again."
      : "Photo taken (\(Int(upright.size.width))x\(Int(upright.size.height)))."
        + (full ? "" : " This was a quick photo.")
    // High-detail second opinion (VisionClient): the realtime model can't see fine print.
    var analysis: String?
    if let config, let deployment = config.visionDeployment {
      add("app", "Reading the photo…")
      // Full resolution, no close-up: at full resolution the close-up adds nothing, and when it framed the
      // wrong text (a "Canon" logo, not the model badge) it misled the model (desk tests, 2026-10-27).
      let photoJPEG = upright.jpegData(compressionQuality: 0.9) ?? overview
      let question = "The user said: \"\(lastUserText)\". The guide wants: \(reason)"
      analysis = await VisionClient(config: config, deployment: deployment)
        .analyze(question: question, ocr: ocrText, photo: photoJPEG, closeUp: nil)
      if let analysis { media?.save(Data(analysis.utf8), as: "photos/photo\(photosTaken)-vision.txt") }
    }
    // The model didn't offer a sharper photo on its own when the reading was incomplete (2026-10-27).
    let unreadable = analysis.map { text in
      ["can't read", "cannot read", "can’t read", "unreadable", "not readable", "too blurry", "can't make out", "can’t make out", "not legible"]
        .contains { text.lowercased().contains($0) }
    } ?? false
    let offer = !full && glasses.fullResPhotos && (unreadable || analysis == nil)
      ? "\nSome text the user may need is unreadable in this quick photo. After answering what you can, ask the user in one short sentence whether to take a sharper 12 MP photo (it takes about a minute). Take it only if they say yes."
      : ""
    let analysisText = analysis.map {
      "\nHigh-detail analysis of the full-resolution photo by a vision model (most reliable for small text; prefer it over your own view and the OCR):\n\($0)"
    } ?? ""
    let ocrSummary = reading.lines.isEmpty && reading.barcodes.isEmpty
      ? "On-device text recognition found no text."
      : "On-device text recognition read the full-resolution photo (trust it over your own reading of small text, but it can garble a word or mix in text from the background):\n\(ocrText)"
    realtime.send([
      "type": "conversation.item.create",
      "item": ["type": "function_call_output", "call_id": callID,
               "output": "\(what)\n\(ocrSummary)\(analysisText)\(offer)\nNext message: the whole view, then a \(zoomLabel)."],
    ])
    realtime.send([
      "type": "conversation.item.create",
      "item": [
        "id": itemID,
        "type": "message",
        "role": "user",
        "content": [
          ["type": "input_text", "text": "Photo, whole view:"],
          ["type": "input_image", "image_url": "data:image/jpeg;base64,\(overview.base64EncodedString())"],
          ["type": "input_text", "text": "Same photo, \(zoomLabel):"],
          ["type": "input_image", "image_url": "data:image/jpeg;base64,\(zoomed.base64EncodedString())"],
        ],
      ],
    ])
    // Keep only the newest high-res photo; they're expensive.
    if let old = photoItemID { realtime.send(["type": "conversation.item.delete", "item_id": old]) }
    photoItemID = itemID
    lastPhotoTime = Date()
    lastPhoto = upright
    realtime.send(["type": "response.create"])
  }

  /// The glasses paused or resumed the camera. Tell the user and the model, so neither waits on
  /// frames that aren't coming.
  func restartCamera() {
    guard isRunning else { return }
    add("app", "Restarting camera (join the glasses Wi-Fi if asked)")
    glasses.restart()
  }

  private func handleCameraPaused(_ paused: Bool) {
    guard isRunning else { return }
    let note = paused
      ? "The glasses camera is now paused (touching the side of the glasses, even to change volume, can do this). You can't see anything new until it resumes; the app will restart it in a few seconds."
      : "The glasses camera has resumed; new images are live again."
    add("app", paused ? "Camera paused by the glasses. Restarting it in \(Int(pauseRestartDelay)) s…" : "Camera live")
    pauseRestartTask?.cancel()
    if paused {
      // The glasses don't reliably resume on their own; restart the camera if still paused.
      pauseRestartTask = Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(self?.pauseRestartDelay ?? 5))
        guard let self, !Task.isCancelled, self.isRunning, self.glasses.isPaused else { return }
        self.add("app", "Restarting camera (join the glasses Wi-Fi if asked)")
        self.glasses.restart()
      }
    }
    realtime.send([
      "type": "conversation.item.create",
      "item": ["type": "message", "role": "system", "content": [["type": "input_text", "text": note]]],
    ])
    if paused, !responseInProgress {
      realtime.send([
        "type": "response.create",
        "response": ["instructions": "In one short sentence, tell the user the camera paused and you're restarting it."],
      ])
    }
  }

  /// The glasses ended the session on their own ("Session ended by device", 2026-10-27). Without this
  /// the app carried on with no video and the model claimed it could see the user moving around.
  private func handleSessionLost(_ reason: String) {
    guard isRunning else { return }
    cameraLost = true
    add("app", "Glasses disconnected (\(reason)). Reconnecting…")
    systemNote("The glasses camera disconnected. You can't see anything new: don't describe the scene, read anything or claim to see changes until you're told the camera is back. The app is reconnecting.")
    if !responseInProgress {
      realtime.send(["type": "response.create",
                     "response": ["instructions": "In one short sentence, tell the user the glasses disconnected and you're reconnecting."]])
    }
    reconnectTask?.cancel()
    reconnectTask = Task { @MainActor [weak self] in
      for attempt in 1...10 {
        try? await Task.sleep(for: .seconds(3))
        guard let self, !Task.isCancelled, self.isRunning, self.cameraLost else { return }
        guard self.glasses.sessionState == .stopped || self.glasses.sessionState == .idle else { continue }
        sbsiLog("reconnect attempt \(attempt)")
        guard self.glasses.start() else { continue }  // e.g. glasses folded: noEligibleDevice
        for _ in 0..<50 where !self.glasses.isStreaming { try? await Task.sleep(for: .milliseconds(200)) }
        if self.glasses.isStreaming { return }
      }
      guard let self, self.isRunning, self.cameraLost else { return }
      self.add("app", "Couldn't reconnect to the glasses. Make sure they're on and unfolded, then press Stop and Start.")
      self.systemNote("The glasses could not be reconnected. Tell the user briefly to check the glasses are on and unfolded, then restart the session.")
      if !self.responseInProgress { self.realtime.send(["type": "response.create"]) }
    }
  }

  private func handleStreamingResumed() {
    guard isRunning, cameraLost else { return }
    cameraLost = false
    reconnectTask?.cancel()
    add("app", "Glasses reconnected")
    systemNote("The glasses camera is back; new images are live again.")
  }

  private func systemNote(_ text: String) {
    realtime.send([
      "type": "conversation.item.create",
      "item": ["type": "message", "role": "system", "content": [["type": "input_text", "text": text]]],
    ])
  }

  private func sendToolOutput(callID: String, output: String) {
    realtime.send([
      "type": "conversation.item.create",
      "item": ["type": "function_call_output", "call_id": callID, "output": output],
    ])
    realtime.send(["type": "response.create"])
  }

  // MARK: - Frames

  private func sendFrameIfNew() {
    guard isRunning, aiStatus == "connected", !detailTestRunning else { return }
    let number = glasses.newestFrameNumber
    guard number != lastSentFrameNumber, let image = glasses.newestFrame,
      let jpeg = image.scaled(maxSide: 768).jpegData(compressionQuality: 0.6)
    else { return }
    lastSentFrameNumber = number

    imagesSent += 1
    media?.save(jpeg, as: "frames/frame\(imagesSent).jpg")
    let itemID = "img\(imagesSent)"
    realtime.send([
      "type": "conversation.item.create",
      "item": [
        "id": itemID,
        "type": "message",
        "role": "user",
        "content": [
          ["type": "input_image", "image_url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"]
        ],
      ],
    ])
    imageItemIDs.append(itemID)
    // Keep only the newest few images in the model's context.
    while imageItemIDs.count > maxImagesInContext {
      let old = imageItemIDs.removeFirst()
      realtime.send(["type": "conversation.item.delete", "item_id": old])
    }
    if imagesSent == 1 || imagesSent % 30 == 0 {
      sbsiLog("frames sent: \(imagesSent) (last \(jpeg.count / 1024) KB)")
    }
  }

  private func proactiveCheckIfIdle() {
    guard isRunning, proactiveEnabled, aiStatus == "connected", assistantHasSpoken,
      !responseInProgress, !photoInFlight, !userSpeaking, !audio.isPlaying, !detailTestRunning,
      Date().timeIntervalSince(lastActivity) > quietPeriodBeforeProactive,
      lastSentFrameNumber != lastProactiveFrameNumber
    else { return }
    lastProactiveFrameNumber = lastSentFrameNumber
    realtime.send([
      "type": "response.create",
      "response": [
        "conversation": "none",
        "output_modalities": ["text"],
        "instructions": Prompts.proactiveCheck,
        "tools": [Tools.proactiveDefinition],
        "tool_choice": ["type": "function", "name": Tools.proactiveDecision],
        "metadata": ["purpose": "proactive"],
      ],
    ])
  }

  // MARK: - Helpers


  private func add(_ who: String, _ text: String) {
    sbsiLog("\(who): \(text)")
    lines.append(Line(who: who, text: text))
    if lines.count > 60 { lines.removeFirst(lines.count - 60) }
  }

  // MARK: - Detail test

  /// Is the quick photo detailed enough, and how much does distance or 12 MP help? (2026-10-26)
  /// Spoken cues on the glasses walk the user through quick photos of a label at 40, 25 and 15 cm,
  /// then one 12 MP photo. Each image is saved to Documents/phototest/ and read with on-device OCR;
  /// the line count and text in the log are the readability score. The guide is muted meanwhile.
  private(set) var detailTestRunning = false
  @ObservationIgnored private let speaker = Speaker()

  func runDetailTest() async {
    guard isRunning, !detailTestRunning else { return }
    detailTestRunning = true
    if responseInProgress { realtime.send(["type": "response.cancel"]) }
    audio.stopPlayback()
    audio.muteMic = true
    defer {
      audio.muteMic = false
      detailTestRunning = false
    }
    let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("phototest", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let stamp = Int(Date().timeIntervalSince1970)
    sbsiLog("detail test: start")
    add("app", "Detail test running; the guide is muted.")

    func score(_ data: Data, _ name: String) async {
      try? data.write(to: folder.appendingPathComponent(name))
      guard let image = UIImage(data: data)?.uprighted() else { return }
      let reading = await PhotoReader.read(image)
      let text = (reading.lines + reading.barcodes).joined(separator: "\n")
      try? text.write(to: folder.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
      sbsiLog("detail test: \(name) \(Int(image.size.width))x\(Int(image.size.height)), \(data.count / 1024) KB, "
              + "\(reading.lines.count) lines, \(reading.barcodes.count) barcodes: "
              + (reading.lines + reading.barcodes).joined(separator: " | "))
    }

    for cm in [40, 25, 15] {
      guard isRunning else { break }
      // The camera is at the left front corner of the frame: a label centred in front of the face lands
      // to the right of the photo and drops out of view up close (15 cm run, 2026-10-26).
      await speaker.say("Hold the label about \(cm) centimetres away, in front of your left eye. Photo in three, two, one.")
      try? await Task.sleep(for: .milliseconds(300))
      if let data = await glasses.quickStill() {
        await speaker.say("Got it.")
        await score(data, "\(stamp)-quick-\(cm)cm.jpg")
      } else {
        sbsiLog("detail test: quick photo at \(cm) cm failed")
        await speaker.say("That photo failed.")
      }
    }
    if isRunning {
      await speaker.say("Now one twelve megapixel photo. Hold the label about 25 centimetres away, in front of your left eye, and keep still until I say you can move.")
      let started = Date()
      let data = await glasses.fullStill { [speaker] in
        sbsiLog(String(format: "detail test: 12 MP transfer started after %.1f s", Date().timeIntervalSince(started)))
        Task { await speaker.say("You can move. It takes about a minute to arrive.") }
      }
      if let data {
        await score(data, "\(stamp)-full-25cm.heic")
        await speaker.say("Twelve megapixel photo received. Test done.")
      } else {
        sbsiLog("detail test: 12 MP photo failed")
        await speaker.say("The twelve megapixel photo failed. Test done.")
      }
    }
    sbsiLog("detail test: done")
    add("app", "Detail test done.")
  }
}

/// Which half-size region of a photo to zoom into (2x).
enum ZoomRegion: String, CaseIterable {
  case center, top, bottom, left, right
  case topLeft = "top-left", topRight = "top-right", bottomLeft = "bottom-left", bottomRight = "bottom-right"
}

extension UIImage {
  /// Half-width, half-height crop at `region` (a 2x zoom), at native resolution.
  func cropped(to region: ZoomRegion) -> UIImage {
    // Bake in any EXIF rotation first so "top" means top as the user saw it.
    guard let cg = uprighted().cgImage else { return self }
    let w = CGFloat(cg.width), h = CGFloat(cg.height)
    let cw = w / 2, ch = h / 2
    let x: CGFloat, y: CGFloat
    switch region {
    case .center: (x, y) = ((w - cw) / 2, (h - ch) / 2)
    case .top: (x, y) = ((w - cw) / 2, 0)
    case .bottom: (x, y) = ((w - cw) / 2, h - ch)
    case .left: (x, y) = (0, (h - ch) / 2)
    case .right: (x, y) = (w - cw, (h - ch) / 2)
    case .topLeft: (x, y) = (0, 0)
    case .topRight: (x, y) = (w - cw, 0)
    case .bottomLeft: (x, y) = (0, h - ch)
    case .bottomRight: (x, y) = (w - cw, h - ch)
    }
    guard let crop = cg.cropping(to: CGRect(x: x, y: y, width: cw, height: ch)) else { return self }
    return UIImage(cgImage: crop)
  }

  /// Same pixels with orientation applied (cgImage ignores imageOrientation).
  func uprighted() -> UIImage {
    guard imageOrientation != .up else { return self }
    let format = UIGraphicsImageRendererFormat()
    format.scale = scale
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in draw(at: .zero) }
  }

  func scaled(maxSide: CGFloat) -> UIImage {
    let longest = max(size.width, size.height)
    guard longest > maxSide else { return self }
    let factor = maxSide / longest
    let target = CGSize(width: size.width * factor, height: size.height * factor)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: target, format: format).image { _ in
      draw(in: CGRect(origin: .zero, size: target))
    }
  }
}
