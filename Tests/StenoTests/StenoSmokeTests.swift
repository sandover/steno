/*
 Proves SwiftPM discovers Steno's test target and imports the executable module.
 The test intentionally covers only the stable identity added by the skeleton.
 Behavioral tests live beside the recorder, engine, session, and UI they prove.
 This target must continue to run with `swift test` and no Xcode project.
*/
import Testing
@testable import Steno

@Test func applicationIdentityIsStable() {
    #expect(AppIdentity.name == "Steno")
}
