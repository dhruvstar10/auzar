import Foundation

/// Diagnostics: printed to stdout so `xcrun devicectl device process launch --console` captures it.
/// (NSLog goes to the unified log on iOS and does NOT show up in `--console`.)
/// Also appended to Documents/logs/<date>.log so runs away from the Mac can be pulled later
/// (see AGENTS.md, "Pull logs from the phone"). Visible in the Files app under SBSI Guide.
func sbsiLog(_ message: String) {
  let time = Date().formatted(.iso8601.time(includingFractionalSeconds: true))
  let line = "\(time) [SBSI] \(message)"
  print(line)
  fflush(stdout)
  LogFile.shared.append(line)
}

private final class LogFile: @unchecked Sendable {
  static let shared = LogFile()
  private let queue = DispatchQueue(label: "sbsi.log")
  private var handle: FileHandle?

  private init() {
    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("logs", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("\(Date().formatted(.iso8601.year().month().day())).log")
    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    handle = try? FileHandle(forWritingTo: url)
    _ = try? handle?.seekToEnd()
  }

  func append(_ line: String) {
    queue.async { [handle] in
      try? handle?.write(contentsOf: Data((line + "\n").utf8))
    }
  }
}
