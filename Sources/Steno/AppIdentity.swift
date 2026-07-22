/*
 Holds the stable identity shared by Steno's app shell and packaging metadata.
 Exports AppIdentity as the single source for the visible application name.
 Keep this type free of UI, storage, and process-global mutable state.
 The bundle identifier remains in Info.plist because macOS owns that contract.
*/
enum AppIdentity {
    static let name = "Steno"
}
