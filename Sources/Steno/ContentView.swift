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
                switch model.preparationState {
                case .preparing:
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Preparing speech model…")
                    }
                    Text("First launch can take several minutes. Record will appear when ready.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                case .ready:
                    Button("Record") {
                        Task { await model.record() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                case let .failed(failure):
                    Text(failure.message)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Retry") {
                        Task { await model.prepare() }
                    }
                }

            case .recording:
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(.red)
                            .frame(width: 8, height: 8)
                        Text("Recording")
                            .foregroundStyle(.red)
                        ProgressView(value: Double(model.recordingLevel))
                            .progressViewStyle(.linear)
                            .tint(.red)
                    }
                }
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
