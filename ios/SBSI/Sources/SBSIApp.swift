import MWDATCore
import SwiftUI

@main
struct SBSIApp: App {
  @State private var assistant: Assistant

  init() {
    do {
      try Wearables.configure()
    } catch {
      sbsiLog("Wearables.configure failed: \(error)")
    }
    _assistant = State(wrappedValue: Assistant())
  }

  var body: some Scene {
    WindowGroup {
      ContentView(assistant: assistant)
        .onOpenURL { url in
          // Callback from the Meta AI app during registration / permission flows.
          guard URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .contains(where: { $0.name == "metaWearablesAction" }) == true
          else { return }
          Task {
            do {
              _ = try await Wearables.shared.handleUrl(url)
            } catch {
              sbsiLog("handleUrl failed: \(error)")
            }
          }
        }
    }
  }
}
