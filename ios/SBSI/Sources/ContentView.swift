import MWDATCore
import SwiftUI

struct ContentView: View {
  @Bindable var assistant: Assistant

  private var glasses: GlassesCamera { assistant.glasses }

  var body: some View {
    VStack(spacing: 12) {
      header
      preview
      if glasses.registrationState != .registered {
        Button("Connect glasses (opens Meta AI)") { glasses.register() }
          .buttonStyle(.bordered)
      }
      if glasses.needsGlassesAppUpdate {
        Button("Update app on glasses") { glasses.openGlassesAppUpdate() }
          .buttonStyle(.borderedProminent)
          .tint(.orange)
      }
      if let error = glasses.lastError {
        Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
      }
      transcript
      settings
      Button(assistant.isRunning ? "Stop" : "Start") {
        assistant.isRunning ? assistant.stop() : assistant.start()
      }
      .font(.title2.bold())
      .frame(maxWidth: .infinity, minHeight: 54)
      .background(assistant.isRunning ? Color.red : Color.accentColor)
      .foregroundStyle(.white)
      .clipShape(RoundedRectangle(cornerRadius: 14))
      .disabled(glasses.registrationState != .registered)
    }
    .padding(16)
  }

  private var header: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 2) {
        Text("SBSI Guide").font(.headline)
        status("Glasses", "\(glasses.registrationState == .registered ? "registered" : "not registered") · \(glasses.sessionState.description) · \(String(describing: glasses.streamState))")
        status("AI", assistant.aiStatus)
      }
      Spacer()
      VStack(alignment: .trailing, spacing: 2) {
        Text("images \(assistant.imagesSent)")
        Text("tokens in \(assistant.inputTokens) · out \(assistant.outputTokens)")
      }
      .font(.caption2.monospaced())
      .foregroundStyle(.secondary)
    }
  }

  private func status(_ label: String, _ value: String) -> some View {
    Text("\(label): \(value)").font(.caption.monospaced()).foregroundStyle(.secondary)
  }

  private var preview: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 12).fill(Color.black)
      if let frame = glasses.latestFrame {
        Image(uiImage: frame).resizable().scaledToFit()
      } else {
        Text(assistant.isRunning ? "Waiting for glasses video…" : "Glasses video appears here")
          .foregroundStyle(.white.opacity(0.6)).font(.callout)
      }
    }
    .overlay(alignment: .bottomTrailing) {
      if let photo = assistant.lastPhoto {
        Image(uiImage: photo).resizable().scaledToFit()
          .frame(height: 80)
          .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white, lineWidth: 2))
          .clipShape(RoundedRectangle(cornerRadius: 6))
          .padding(6)
      }
    }
    .frame(height: 220)
    .clipShape(RoundedRectangle(cornerRadius: 12))
  }

  private var transcript: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 6) {
          ForEach(assistant.lines) { line in
            HStack(alignment: .top, spacing: 6) {
              Text(line.who).font(.caption.bold()).frame(width: 44, alignment: .leading)
                .foregroundStyle(line.who == "guide" ? Color.accentColor : line.who == "error" ? .red : .secondary)
              Text(line.text).font(.callout)
            }
            .id(line.id)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .onChange(of: assistant.lines.count) {
        if let last = assistant.lines.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
      }
    }
  }

  private var settings: some View {
    VStack(spacing: 4) {
      Toggle("Speak up proactively", isOn: $assistant.proactiveEnabled)
      Toggle("Mute mic while guide talks", isOn: $assistant.muteMicWhileSpeaking)
      Stepper("Frame every \(Int(assistant.frameInterval)) s", value: $assistant.frameInterval, in: 1...10)
        .disabled(assistant.isRunning)
    }
    .font(.footnote)
  }
}
