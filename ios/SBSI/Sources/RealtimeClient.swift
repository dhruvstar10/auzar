import Foundation

/// Minimal WebSocket client for the Azure OpenAI realtime API (GA event shapes).
/// Events are delivered as decoded JSON dictionaries on the main actor.
final class RealtimeClient: NSObject, URLSessionWebSocketDelegate {
  var onEvent: (@MainActor ([String: Any]) -> Void)?
  var onOpen: (@MainActor () -> Void)?
  var onClose: (@MainActor (String) -> Void)?

  private var task: URLSessionWebSocketTask?
  private lazy var urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

  func connect(config: AppConfig) {
    var request = URLRequest(url: config.realtimeURL)
    request.setValue(config.azureKey, forHTTPHeaderField: "api-key")
    let task = urlSession.webSocketTask(with: request)
    task.maximumMessageSize = 16 * 1024 * 1024
    self.task = task
    task.resume()
    receive()
  }

  func disconnect() {
    task?.cancel(with: .normalClosure, reason: nil)
    task = nil
  }

  func send(_ event: [String: Any]) {
    guard let task, let data = try? JSONSerialization.data(withJSONObject: event),
      let text = String(data: data, encoding: .utf8)
    else { return }
    task.send(.string(text)) { error in
      if let error { sbsiLog("realtime send error: \(error.localizedDescription)") }
    }
  }

  private func receive() {
    task?.receive { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(let message):
        var data: Data?
        switch message {
        case .string(let text): data = text.data(using: .utf8)
        case .data(let d): data = d
        @unknown default: break
        }
        if let data, let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
          Task { @MainActor in self.onEvent?(event) }
        }
        self.receive()
      case .failure(let error):
        Task { @MainActor in self.onClose?(error.localizedDescription) }
      }
    }
  }

  func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
    Task { @MainActor in self.onOpen?() }
  }

  func urlSession(
    _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
  ) {
    let why = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    Task { @MainActor in self.onClose?("closed (\(closeCode.rawValue)) \(why)") }
  }
}
