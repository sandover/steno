/*
 Owns Steno's one floating NSPanel and one menu-bar status item.
 Left click toggles the panel; right click exposes the sole Quit command.
 The panel floats above ordinary windows and follows the user across Spaces.
 Closing hides and resets the ephemeral session rather than destroying state UI.
 Panel size derives directly from SessionModel.State through PanelLayout.
*/
import AppKit
import Combine
import SwiftUI

enum PanelLayout {
    static let width: CGFloat = 420

    static func height(for state: SessionModel.State) -> CGFloat {
        switch state {
        case .idle:
            130
        case .recording:
            180
        case .transcribing:
            220
        case .complete:
            340
        case .error:
            210
        }
    }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private let model: SessionModel
    private let panel: NSPanel
    private let statusItem: NSStatusItem
    private let quitMenu = NSMenu()
    private var stateObservation: AnyCancellable?
    private var preparationObservation: AnyCancellable?

    init(model: SessionModel) {
        self.model = model
        panel = NSPanel(
            contentRect: NSRect(
                origin: .zero,
                size: NSSize(width: PanelLayout.width, height: PanelLayout.height(for: model.state))
            ),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        configurePanel()
        configureStatusItem()
        observeState()
    }

    private func configurePanel() {
        panel.title = AppIdentity.name
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = true
        panel.backgroundColor = .windowBackgroundColor
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: ContentView(model: model))
        panel.center()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        updateStatusIcon(for: model.preparationState)
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        let quit = NSMenuItem(title: "Quit Steno", action: #selector(quitApplication), keyEquivalent: "q")
        quit.target = self
        quitMenu.addItem(quit)
    }

    private func observeState() {
        stateObservation = model.$state.sink { [weak self] state in
            guard let self else { return }
            let size = NSSize(width: PanelLayout.width, height: PanelLayout.height(for: state))
            self.panel.setContentSize(size)
        }
        preparationObservation = model.$preparationState.sink { [weak self] state in
            self?.updateStatusIcon(for: state)
        }
    }

    private func updateStatusIcon(for state: SessionModel.PreparationState) {
        guard let button = statusItem.button else { return }
        let symbol: String
        let description: String
        switch state {
        case .preparing:
            symbol = "hourglass"
            description = "Steno is preparing its speech model"
        case .ready:
            symbol = "record.circle"
            description = "Steno is ready to record"
        case .failed:
            symbol = "exclamationmark.triangle"
            description = "Steno could not prepare its speech model"
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        button.image?.isTemplate = true
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApplication.shared.currentEvent?.type == .rightMouseUp {
            statusItem.menu = quitMenu
            sender.performClick(nil)
            statusItem.menu = nil
            return
        }
        togglePanel()
    }

    private func togglePanel() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            NSApplication.shared.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func quitApplication() {
        model.reset()
        NSApplication.shared.terminate(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        model.reset()
        panel.orderOut(nil)
        return false
    }
}
