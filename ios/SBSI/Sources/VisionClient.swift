import Foundation

/// Second opinion on photos from a high-detail vision model (full-resolution photo + OCR text) (Azure chat-completions deployment,
/// `SBSIAzureVisionDeployment`). gpt-realtime-mini shrinks every image to ~512 px, so it can't read
/// the fine print a 12 MP photo captures; this model gets the photo and the label close-up at high
/// detail and its answer goes to the realtime model as text (2026-10-26).
/// Same request shape as tools/vision_test.py, so desk results carry over.
struct VisionClient {
  let config: AppConfig
  let deployment: String

  static let system = """
    You analyse a photo from the user's smart-glasses camera for a hands-on repair guide. \
    Answer the question about the object the user is holding or looking at. Read all text on it \
    exactly, including small print, numbers, part or model numbers and barcodes' human-readable \
    digits. If on-device OCR text is given, use it to confirm your reading but correct obvious OCR \
    errors from what you see. Ignore text on screens or papers in the background unless asked. \
    Say plainly what you can't read; never guess brand names or codes you can't actually make out \
    (on a low-resolution photo this produced confident wrong readings). Be factual and compact: short \
    lines, no preamble.
    """

  /// Returns the model's answer, or nil on error/timeout (logged).
  func analyze(question: String, ocr: String, photo: Data, closeUp: Data?) async -> String? {
    var content: [[String: Any]] = [
      ["type": "text", "text": "Question: \(question)"],
      ["type": "text", "text": "On-device OCR of the full photo:\n\(ocr)"],
    ]
    for (label, data) in [("Whole photo:", photo), ("Close-up of the main label:", closeUp)] {
      guard let data else { continue }
      content.append(["type": "text", "text": label])
      // "original" keeps the photo's full resolution; "high" shrinks a 12 MP photo to ~1024x768, which
      // lost a printer's model badge that "original" read (MF269dw), for ~3.4k tokens (2026-10-27).
      content.append(["type": "image_url",
                      "image_url": ["url": "data:image/jpeg;base64,\(data.base64EncodedString())", "detail": "original"]])
    }
    var body: [String: Any] = [
      "model": deployment,
      "max_completion_tokens": 2000,
      "reasoning_effort": "low",
      "messages": [["role": "system", "content": Self.system], ["role": "user", "content": content]],
    ]
    let started = Date()
    var result = await send(body)
    if case .failure(let message) = result, message.contains("reasoning_effort") {
      body["reasoning_effort"] = nil  // non-reasoning models (e.g. gpt-4.1) reject it
      result = await send(body)
    }
    switch result {
    case .success(let (text, usage)):
      sbsiLog(String(format: "vision (%@): %.1f s, %@", deployment, Date().timeIntervalSince(started), usage))
      return text
    case .failure(let message):
      sbsiLog("vision (\(deployment)) failed after \(String(format: "%.1f", Date().timeIntervalSince(started))) s: \(message)")
      return nil
    }
  }

  private enum Outcome { case success((String, String)), failure(String) }

  private func send(_ body: [String: Any]) async -> Outcome {
    var request = URLRequest(url: URL(string: "https://\(config.azureHost)/openai/v1/chat/completions")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue(config.azureKey, forHTTPHeaderField: "api-key")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      guard (response as? HTTPURLResponse)?.statusCode == 200,
        let choice = (json?["choices"] as? [[String: Any]])?.first,
        let text = (choice["message"] as? [String: Any])?["content"] as? String, !text.isEmpty
      else {
        return .failure(String(data: data.prefix(500), encoding: .utf8) ?? "HTTP error")
      }
      let usage = (json?["usage"] as? [String: Any]).map { "in \($0["prompt_tokens"] ?? "?") out \($0["completion_tokens"] ?? "?")" } ?? ""
      return .success((text, usage))
    } catch {
      return .failure("\(error.localizedDescription)")
    }
  }
}
