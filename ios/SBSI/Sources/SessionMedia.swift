import UIKit

/// Saves what the model saw during a session, so it can be inspected afterwards:
/// Documents/sessions/<yyyy-MM-dd_HH-mm-ss>/photos (originals from the glasses + what was sent)
/// and /frames (the video frames sent to the model). Visible in the Files app under Auzar,
/// or pull with `devicectl device copy from ... --source Documents/sessions` (see AGENTS.md).
final class SessionMedia: @unchecked Sendable {
  let folder: URL
  private let queue = DispatchQueue(label: "sbsi.media", qos: .utility)

  init() {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("sessions/\(formatter.string(from: Date()))", isDirectory: true)
    for sub in ["photos", "frames"] {
      try? FileManager.default.createDirectory(
        at: folder.appendingPathComponent(sub), withIntermediateDirectories: true)
    }
  }

  /// Writes in the background; `path` is relative to the session folder, e.g. "photos/photo1.jpg".
  func save(_ data: Data, as path: String) {
    let url = folder.appendingPathComponent(path)
    queue.async { try? data.write(to: url) }
  }
}
