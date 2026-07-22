/*
 Provides Steno's sole application entry point and AppKit lifecycle bridge.
 The SwiftUI scene intentionally creates no ordinary window or Dock workflow.
 AppDelegate owns the one status item, floating panel, and ephemeral session.
 The application remains a local accessory with no account or network setup.
*/
import SwiftUI

@main
struct StenoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
