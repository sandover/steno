/*
 Renders SessionModel.State as Steno's complete one-panel product interface.
 Each state contains only the controls needed for Record, Stop, Copy, or Reset.
 Transcript content is always read-only and selectable through one AppKit wrapper.
 Permission denial alone exposes the direct macOS microphone-settings link.
 No view owns parallel session state, files, history, settings, or navigation.
*/
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: SessionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.state {
            case .idle:
                Button("Record") {
                    Task { await model.record() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)

            case .recording:
                Text("Transcript appears after Stop.")
                    .foregroundStyle(.secondary)
                SelectableTranscriptView(text: "")
                Button("Stop") {
                    Task { await model.stop() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

            case .transcribing:
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Transcribing")
                }
                SelectableTranscriptView(text: "")
                Button("Reset", action: model.reset)

            case let .complete(text):
                SelectableTranscriptView(text: text)
                HStack {
                    if model.canCopy {
                        Button(model.didCopy ? "Copied" : "Copy") {
                            model.copy()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button("Reset", action: model.reset)
                }

            case let .error(failure):
                Text(failure.message)
                    .fixedSize(horizontal: false, vertical: true)
                if failure.showsMicrophoneSettings,
                   let settingsURL = URL(
                       string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
                   ) {
                    Link("Open Microphone Settings", destination: settingsURL)
                }
                Button("Reset", action: model.reset)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
