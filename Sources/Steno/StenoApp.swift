/*
 Provides the native SwiftUI application entry point for Steno.
 Exports StenoApp and, for now, the smallest buildable placeholder scene.
 Later UI work replaces the placeholder without adding another app lifecycle.
 The application must remain a local process with no account or network setup.
*/
import SwiftUI

@main
struct StenoApp: App {
    var body: some Scene {
        WindowGroup(AppIdentity.name) {
            Text(AppIdentity.name)
                .padding()
        }
    }
}
