import Foundation

/// Diagnostics: printed to stdout so `xcrun devicectl device process launch --console` captures it.
/// (NSLog goes to the unified log on iOS and does NOT show up in `--console`.)
func sbsiLog(_ message: String) {
  let time = Date().formatted(.iso8601.time(includingFractionalSeconds: true))
  print("\(time) [SBSI] \(message)")
  fflush(stdout)
}
