import Testing
import Foundation
@testable import DcttCore

struct CoreTests {
    @Test func testMissingAssetsAreNotPrepared() async {
        let store = ModelStore(root: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString))
        let prepared = await store.isPrepared(ModelDescriptor.catalog[0])
        #expect(!(prepared))
    }

    @Test func testReleaseBeforeStartupCannotRecord() {
        var gate = SessionGate()
        let id = gate.press()!
        gate.release()
        #expect(gate.started(id) == false)
        #expect((gate.press()) == nil, "Startup must drain before a new hold")
        gate.finish(id)
        #expect((gate.press()) != nil)
    }

    @Test func testCancellationDrainsAndRejectsLateResults() {
        var gate = SessionGate()
        let old = gate.press()!
        #expect(gate.started(old) == true)
        #expect(gate.transcribe(old) == true)
        gate.cancel()
        #expect((gate.press()) == nil)
        #expect(gate.finalize(old) == false)
        #expect(gate.claimCommit(old) == false)
        gate.finish(old)
        let new = gate.press()!
        #expect(gate.started(new) == true)
        gate.finish(old)
        #expect((gate.id) == (new), "A stale completion cannot clear a newer session")
        #expect(gate.finalize(old) == false)
    }

    @Test func testRepeatAndDuplicateCompletionCannotPasteTwice() {
        var gate = SessionGate()
        let id = gate.press()!
        #expect((gate.press()) == nil)
        #expect(gate.started(id) == true)
        #expect(gate.transcribe(id) == true)
        #expect(gate.transcribe(id) == false)
        #expect(gate.finalize(id) == true)
        #expect(gate.claimCommit(id) == true)
        #expect(gate.claimCommit(id) == false)
        #expect(gate.finalize(id) == false)
    }

    @Test func testCancellationAtEveryPhaseRejectsCommit() {
        for phase in 0..<4 {
            var gate = SessionGate()
            let id = gate.press()!
            if phase >= 1 { #expect(gate.started(id) == true) }
            if phase >= 2 { #expect(gate.transcribe(id) == true) }
            if phase >= 3 { #expect(gate.finalize(id) == true) }
            gate.cancel()
            #expect(!(gate.accepts(id)))
            #expect(gate.claimCommit(id) == false)
        }
    }

    @Test func testTerminalPayloadContainsNoSubmissionOrControlCharacters() {
        let input = "echo 'A'\\path\r\nnext\tline\u{2028}x\u{2029}y\u{85}z\u{1b}[31m\u{0}\u{7}\u{7f}\u{9b}31m"
        let output = TextPolicy.apply(input, cleanup: false, terminal: true)
        #expect((output) == ("echo 'A'\\path next line x y z[31m31m"))
        #expect(output.unicodeScalars.allSatisfy { $0.value >= 32 && !(127...159).contains($0.value) && $0.value != 0x2028 && $0.value != 0x2029 })
    }

    @Test func testTerminalPreservesLiteralUnicodeAndSyntax() {
        let literal = "DON'T fix My_ID 3.14 ~/a/b \\\"x\\\" https://example.org/a?b=c 👩‍💻 فارسی\u{200c}"
        #expect((TextPolicy.apply(literal, cleanup: true, terminal: true)) == (literal))
    }

    @Test func testCleanupPreservesMeaningAndInternalWhitespace() {
        let literal = "Do NOT delete 3.14. Very very good.  My_ID\t~/folder/a https://example.org"
        #expect((TextPolicy.apply(" \r\n" + literal + "\r\n ", cleanup: true, terminal: false)) == (literal))
        #expect((TextPolicy.apply("  x\r\n", cleanup: false, terminal: false)) == ("  x\r\n"))
    }

    @Test func testSilenceShortAndInvalidAudioAreRejectedWithoutDroppingQuietSignal() {
        #expect(!(AudioPolicy.hasSignal(Array(repeating: 0, count: 160000))))
        #expect(!(AudioPolicy.hasSignal(Array(repeating: 0.5, count: 1000))))
        #expect(!(AudioPolicy.hasSignal(Array(repeating: .nan, count: 16000))))
        #expect(AudioPolicy.hasSignal((0..<16000).map { 0.003 * sin(Float($0) * 0.1) }))
    }
}
