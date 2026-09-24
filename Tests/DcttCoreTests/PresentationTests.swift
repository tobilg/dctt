import Foundation
import Testing
@testable import DcttCore

struct PresentationTests {
    @Test func staleCompletionAndDismissalCannotReplaceNewSession() {
        var presentation = SessionPresentation()
        let old = UUID(), current = UUID()
        presentation.begin(old)
        presentation.update(old, phase: .pasteRequested, message: "Paste requested")
        presentation.begin(current)
        presentation.update(old, phase: .recovery, message: "Old failure", text: "Old text")
        let dismissed = presentation.dismiss(old)
        #expect(!dismissed)
        #expect(presentation.id == current)
        #expect(presentation.phase == .starting)
        #expect(presentation.recoveryText.isEmpty)
    }
    @Test func recoveryOutlivesCaptureButNotNextSession() {
        var gate = SessionGate(), presentation = SessionPresentation()
        let id = gate.press()!
        presentation.begin(id)
        presentation.update(id, phase: .recovery, message: "Destination changed", text: "Retained result")
        gate.finish(id)
        #expect(gate.phase == .idle)
        #expect(presentation.recoveryText == "Retained result")
        presentation.begin(gate.press()!)
        #expect(presentation.recoveryText.isEmpty)
    }
    @Test func historySearchMatchesTextAndAppWithoutModifyingRecords() {
        let first = HistoryRecord(text: "Café meeting", model: ModelDescriptor.catalog[0], audioSeconds: 1,
            transcriptionSeconds: 1, cleanup: true, targetAppName: "TextEdit", deliveryStatus: .pasteRequested)
        let second = HistoryRecord(text: "Other words", model: ModelDescriptor.catalog[0], audioSeconds: 1,
            transcriptionSeconds: 1, cleanup: true, targetAppName: "Safari", deliveryStatus: .targetChanged)
        #expect(HistorySearch.filter([first, second], query: " CAFE ").map(\.id) == [first.id])
        #expect(HistorySearch.filter([first, second], query: "safari").map(\.id) == [second.id])
        #expect(HistorySearch.filter([first, second], query: "absent").isEmpty)
        #expect(HistorySearch.filter([first, second], query: " ").count == 2)
        #expect(DeliveryStatus.pasteRequested.label == "Paste requested")
    }
}
