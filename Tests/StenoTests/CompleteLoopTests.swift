/*
 Drives the complete product loop without an app host or microphone permission.
 The test asserts every visible state plus the exact clipboard and Reset effects.
 This is the authoritative automated proof of Record, Stop, Copy, Reset behavior.
 Hardware capture and selectable on-screen text remain final manual acceptance.
*/
import Testing
@testable import Steno

@Suite("CompleteLoopTests")
@MainActor
struct CompleteLoopTests {
    @Test func recordStopCopyResetLoop() async {
        let context = SessionTestContext(transcript: "Every exact spoken word.")
        #expect(context.model.state == .idle)

        await context.model.record()
        #expect(context.model.state == .recording)

        await context.model.stop()?.value
        #expect(context.model.state == .complete("Every exact spoken word."))
        #expect(context.model.canCopy)

        #expect(context.model.copy())
        #expect(context.clipboard == ["Every exact spoken word."])
        #expect(context.model.didCopy)

        context.model.reset()
        #expect(context.model.state == .idle)
        #expect(context.model.transcript.isEmpty)
        #expect(!context.model.didCopy)
    }
}
