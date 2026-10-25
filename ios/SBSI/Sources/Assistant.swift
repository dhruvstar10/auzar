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
  var muteMicWhileSpeaking = true

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

  private let maxImagesInContext = 3
  private let proactiveInterval: TimeInterval = 8
  private let quietPeriodBeforeProactive: TimeInterval = 5

  init() {
    realtime.onOpen = { [weak self] in self?.handleOpen() }
    realtime.onClose = { [weak self] reason in self?.handleClose(reason) }
    realtime.onEvent = { [weak self] event in self?.handle(event) }
    audio.onMicAudio = { [weak self] pcm in
      // Audio thread. Encoding + send is thread-safe on the client.
      self?.realtime.send(["type": "input_audio_buffer.append", "audio": pcm.base64EncodedString()])
    }
  }

  // MARK: - Start / stop

  func start() {
    guard !isRunning else { return }
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
    assistantHasSpoken = false

    glasses.start()
    do {
      try audio.start()
      add("app", "Mic: \(audio.inputRouteName)")
    } catch {
      add("app", "Audio failed to start: \(error.localizedDescription)")
    }
    aiStatus = "connecting"
    realtime.connect(config: config)
  }

  func stop() {
    guard isRunning else { return }
    isRunning = false
    frameTimer?.invalidate()
    proactiveTimer?.invalidate()
    realtime.disconnect()
    audio.stop()
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
      userSpeaking = true
      lastActivity = Date()
      // Barge-in: stop the guide talking as soon as the user speaks.
      audio.stopPlayback()

    case "input_audio_buffer.speech_stopped":
      userSpeaking = false
      lastActivity = Date()

    case "conversation.item.input_audio_transcription.completed":
      if let text = event["transcript"] as? String, !text.isEmpty { add("you", text) }

    case "response.created":
      responseInProgress = true

    case "response.output_audio.delta":
      if let b64 = event["delta"] as? String, let pcm = Data(base64Encoded: b64) {
        if muteMicWhileSpeaking { audio.micMuted = true }
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
      unmuteMicWhenPlaybackEnds()

    case "error":
      let err = event["error"] as? [String: Any]
      let message = err?["message"] as? String ?? "\(event)"
      sbsiLog("realtime error: \(message)")
      // Cancelling when nothing is active is harmless; don't clutter the transcript with it.
      if !(message.contains("no active response")) { add("error", message) }

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

  private func unmuteMicWhenPlaybackEnds() {
    guard audio.micMuted else { return }
    Task { @MainActor in
      while audio.isPlaying { try? await Task.sleep(for: .milliseconds(100)) }
      try? await Task.sleep(for: .milliseconds(300))  // let the speaker tail die out
      if !responseInProgress { audio.micMuted = false }
    }
  }

  // MARK: - Tools

  private func handleToolCall(name: String, callID: String, arguments: String) {
    sbsiLog("tool call: \(name) \(arguments)")
    switch name {
    case Tools.proactiveDecision:
      break  // handled from response.done of the out-of-band check
    case Tools.takePhoto:
      // The model sometimes asks again right after a photo arrives; reuse the fresh one.
      if photoInFlight || (photoItemID != nil && Date().timeIntervalSince(lastPhotoTime) < 8) {
        sendToolOutput(callID: callID, output: "You took a photo a few seconds ago; it is already in the conversation. Use it. Only take another if the user has moved or asks for one.")
        sbsiLog("take_photo skipped: duplicate")
      } else {
        Task { await takePhoto(callID: callID) }
      }
    default:
      sendToolOutput(callID: callID, output: "Unknown tool \(name).")
    }
  }

  /// Captures a full-resolution still on the glasses and adds it to the conversation.
  private func takePhoto(callID: String) async {
    add("app", "Taking a photo…")
    photoInFlight = true
    defer { photoInFlight = false }
    guard let data = await glasses.capturePhoto(), let image = UIImage(data: data),
      let jpeg = image.scaled(maxSide: 2048).jpegData(compressionQuality: 0.85)
    else {
      add("app", "Photo failed")
      sendToolOutput(callID: callID, output: "Photo capture failed. Ask the user to hold still and try again, or use the video frames.")
      return
    }
    photosTaken += 1
    let itemID = "photo\(photosTaken)"
    // The function output must come right after the call; the photo follows as a user image.
    realtime.send([
      "type": "conversation.item.create",
      "item": ["type": "function_call_output", "call_id": callID,
               "output": "Photo taken (\(Int(image.size.width))x\(Int(image.size.height))). It is the next image in the conversation."],
    ])
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
    // Keep only the newest high-res photo; they're expensive.
    if let old = photoItemID { realtime.send(["type": "conversation.item.delete", "item_id": old]) }
    photoItemID = itemID
    lastPhotoTime = Date()
    lastPhoto = image
    realtime.send(["type": "response.create"])
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
    guard isRunning, aiStatus == "connected" else { return }
    let number = glasses.newestFrameNumber
    guard number != lastSentFrameNumber, let image = glasses.newestFrame,
      let jpeg = image.scaled(maxSide: 768).jpegData(compressionQuality: 0.6)
    else { return }
    lastSentFrameNumber = number

    imagesSent += 1
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
      !responseInProgress, !userSpeaking, !audio.isPlaying,
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
}

extension UIImage {
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
