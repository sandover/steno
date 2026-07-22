/*
 Wires Steno's one recorder, engine, session model, panel, and status item.
 AppDelegate creates no document, persistence layer, or background service.
 Launch cleanup removes only stale Steno WAVs before the first user action.
 Quitting invalidates the visible session before the process terminates.
*/
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: SessionModel?
    private var panelController: PanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        let audioStore = TemporaryAudioStore()
        _ = try? audioStore.removeStaleRecordings()
        let recorder = MicrophoneRecorder(audioStore: audioStore)
        let resourceRoot = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        let engine = TranscriptionEngine(resourceRoot: resourceRoot)
        let model = SessionModel(recorder: recorder, engine: engine)
        self.model = model
        panelController = PanelController(model: model)
        Task { await model.prepare() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model?.reset()
        return .terminateNow
    }
}
