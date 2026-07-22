/*
 Renders every panel state offscreen with injected deterministic session data.
 The test proves each state has a valid native view without an Xcode app host.
 Set STENO_UI_RENDER_DIR to retain PNGs for the required manual visual review.
 Production actions remain inert because rendering never invokes a control.
*/
import AppKit
import SwiftUI
import Testing
@testable import Steno

@Suite("PanelRenderingTests", .serialized)
@MainActor
struct PanelRenderingTests {
    @Test func rendersEveryState() throws {
        let states: [(String, SessionModel.State)] = [
            ("idle", .idle),
            ("recording", .recording),
            ("transcribing", .transcribing),
            ("complete", .complete("A selectable meeting transcript appears here.")),
            ("empty", .complete("")),
            ("permission-error", .error(.init(
                message: "Microphone access is denied.",
                showsMicrophoneSettings: true
            ))),
            ("error", .error(.init(
                message: "Steno could not transcribe this recording.",
                showsMicrophoneSettings: false
            ))),
        ]
        let renderDirectory = ProcessInfo.processInfo.environment["STENO_UI_RENDER_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let renderDirectory {
            try FileManager.default.createDirectory(
                at: renderDirectory,
                withIntermediateDirectories: true
            )
        }

        for (name, state) in states {
            let model = previewModel(state: state)
            let size = NSSize(width: PanelLayout.width, height: PanelLayout.height(for: state))
            let hostingView = NSHostingView(rootView: ContentView(model: model))
            hostingView.appearance = NSAppearance(named: .aqua)
            hostingView.frame = NSRect(origin: .zero, size: size)
            hostingView.layoutSubtreeIfNeeded()
            let bitmap = try #require(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
            hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            #expect(!png.isEmpty)
            if let renderDirectory {
                try png.write(to: renderDirectory.appendingPathComponent("\(name).png"))
            }
        }
    }

    private func previewModel(state: SessionModel.State) -> SessionModel {
        SessionModel(
            initialState: state,
            startRecording: { URL(fileURLWithPath: "/tmp/preview.wav") },
            stopRecording: { URL(fileURLWithPath: "/tmp/preview.wav") },
            resetRecording: {},
            transcribe: { _ in "Preview transcript" },
            writeClipboard: { _ in }
        )
    }
}
