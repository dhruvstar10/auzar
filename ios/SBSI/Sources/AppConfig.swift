import Foundation

/// Azure settings injected at build time from Config/Secrets.xcconfig via Info.plist.
/// v0 only: the key ships inside the app binary. Before sharing builds, replace with
/// short-lived tokens from a backend.
struct AppConfig {
  let azureHost: String
  let azureKey: String
  let deployment: String

  static func load() -> AppConfig? {
    let info = Bundle.main.infoDictionary ?? [:]
    func value(_ key: String) -> String? {
      guard let v = info[key] as? String, !v.isEmpty, !v.hasPrefix("$(") else { return nil }
      return v
    }
    guard let host = value("SBSIAzureHost"), let key = value("SBSIAzureKey"),
      let deployment = value("SBSIAzureDeployment")
    else { return nil }
    return AppConfig(azureHost: host, azureKey: key, deployment: deployment)
  }

  var realtimeURL: URL {
    URL(string: "wss://\(azureHost)/openai/v1/realtime?model=\(deployment)")!
  }
}
