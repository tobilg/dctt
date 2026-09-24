import AppKit
import Testing
@testable import DcttCore

@MainActor struct DeliveryTests {
    func service() -> DeliveryService {
        let service = DeliveryService()
        service.hooks.trusted = { true }
        service.hooks.secureInput = { false }
        service.hooks.modifiersDown = { false }
        service.hooks.matches = { _ in true }
        service.hooks.pause = {}
        service.hooks.requestPaste = { Issue.record("Unexpected paste request") }
        service.hooks.pasteboard = NSPasteboard(name: .init("dctt-tests-\(UUID())"))
        return service
    }
    var target: Destination {
        Destination(pid: 42, bundleID: "com.apple.TextEdit", name: "Test", generation: 1, window: nil, element: nil, secure: false)
    }
    @Test func changedTargetDoesNotTouchClipboard() async {
        let service = service()
        service.hooks.pasteboard.setString("original", forType: .string)
        service.hooks.matches = { _ in false }
        let result = await service.paste("test", to: target, restoreClipboard: false) { true }
        #expect(result == .targetChanged)
        #expect(service.hooks.pasteboard.string(forType: .string) == "original")
    }
    @Test func heldModifiersHaveBoundedWaitAndNeverPaste() async {
        let service = service()
        var pauses = 0
        service.hooks.modifiersDown = { true }
        service.hooks.pause = { pauses += 1 }
        let result = await service.paste("test", to: target, restoreClipboard: false) { true }
        #expect(result == .copyOnly)
        #expect(pauses == 60)
        #expect(service.lastBlockReason == .modifiersHeld)
    }
    @Test func cancellationDuringModifierWaitNeverPastes() async {
        let service = service()
        var valid = true
        service.hooks.modifiersDown = { true }
        service.hooks.pause = { valid = false }
        let result = await service.paste("test", to: target, restoreClipboard: false) { valid }
        #expect(result == .copyOnly)
    }
    @Test func finalTargetCheckClosesClipboardPreparationRace() async {
        let service = service()
        var checks = 0
        service.hooks.matches = { _ in checks += 1; return checks == 1 }
        service.hooks.pasteboard.setString("original", forType: .string)
        let result = await service.paste("test", to: target, restoreClipboard: true) { true }
        #expect(result == .targetChanged)
        #expect(service.hooks.pasteboard.string(forType: .string) == "original")
    }
    @Test func permittedDeliveryRequestsExactlyOnePaste() async {
        let service = service()
        var requests = 0
        service.hooks.requestPaste = { requests += 1 }
        let result = await service.paste("test", to: target, restoreClipboard: false) { true }
        #expect(result == .pasteRequested)
        #expect(requests == 1)
        #expect(service.hooks.pasteboard.string(forType: .string) == "test")
    }
    @Test func delayedClipboardRestorationActuallyRuns() async throws {
        let service = service()
        service.hooks.pasteboard.setString("original", forType: .string)
        service.hooks.requestPaste = {}
        let result = await service.paste("dictation", to: target, restoreClipboard: true) { true }
        #expect(result == .pasteRequested)
        #expect(service.hooks.pasteboard.string(forType: .string) == "dictation")
        try await AppDelay.sleep(milliseconds: 1_200)
        #expect(service.hooks.pasteboard.string(forType: .string) == "original")
    }
    @Test func syntheticPasteDoesNotLeaveCommandHeldOrEnterTheHIDStream() async {
        let service = service()
        service.hooks.requestPaste = nil
        var requests = 0
        service.hooks.postEvents = { down, up, tap in
            requests += 1
            #expect(tap == .cgSessionEventTap)
            #expect(down.type == .keyDown && up.type == .keyUp)
            #expect(down.getIntegerValueField(.keyboardEventKeycode) == 9)
            #expect(up.getIntegerValueField(.keyboardEventKeycode) == 9)
            #expect(down.flags == .maskCommand)
            #expect(up.flags.isEmpty)
        }
        let result = await service.paste("test", to: target, restoreClipboard: false) { true }
        #expect(result == .pasteRequested)
        #expect(requests == 1)
        #expect(service.lastBlockReason == nil)
    }
    @Test func secureFieldIsBlockedEvenWithoutGlobalSecureInput() async {
        let service = service()
        let password = Destination(pid: 42, bundleID: "com.apple.Safari", name: "Test", generation: 1,
                                   window: nil, element: nil, secure: true)
        let result = await service.paste("test", to: password, restoreClipboard: false) { true }
        #expect(result == .copyOnly)
        #expect(service.lastBlockReason == .secureField)
    }
    @Test func browserWithoutConcreteTextFieldNeverPastesOrTouchesClipboard() async {
        for role: String? in [nil, "AXGroup", "AXWebArea"] {
            let service = service()
            let browser = Destination(pid: 42, bundleID: "org.mozilla.firefox", name: "Test", generation: 1,
                window: AXUIElementCreateApplication(42), element: AXUIElementCreateApplication(42),
                secure: false, fieldRole: role)
            service.hooks.pasteboard.setString("original", forType: .string)
            let result = await service.paste("test", to: browser, restoreClipboard: false) { true }
            #expect(result == .copyOnly)
            #expect(service.lastBlockReason == .fieldIdentityUnavailable)
            #expect(service.hooks.pasteboard.string(forType: .string) == "original")
        }
    }
    @Test func browserIdentityCannotDegradeToWindowOnlyAtCommit() {
        let service = service()
        let field = AXUIElementCreateApplication(42)
        let original = Destination(pid: 42, bundleID: "com.google.Chrome", name: "Test", generation: 1,
            window: field, element: field, secure: false, fieldRole: "AXTextArea")
        service.hooks.snapshot = { original }
        #expect(service.matches(original))
        var degraded = original
        degraded.fieldRole = "AXWebArea"
        service.hooks.snapshot = { degraded }
        #expect(!service.matches(original))
        let changed = Destination(pid: 42, bundleID: "com.google.Chrome", name: "Test", generation: 1,
            window: field, element: AXUIElementCreateApplication(43), secure: false, fieldRole: "AXTextField")
        service.hooks.snapshot = { changed }
        #expect(!service.matches(original))
    }
    @Test func appWaitHonorsCancellation() async {
        let wait = Task { () -> Bool in
            do { try await AppDelay.sleep(milliseconds: 5_000); return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        wait.cancel()
        #expect(await wait.value)
    }
    @Test func permissionLossAndSecureInputBlockDelivery() async {
        let service = service()
        service.hooks.trusted = { false }
        let denied = await service.paste("test", to: target, restoreClipboard: false) { true }
        #expect(denied == .permissionDenied)
        service.hooks.trusted = { true }
        service.hooks.secureInput = { true }
        let secure = await service.paste("test", to: target, restoreClipboard: false) { true }
        #expect(secure == .copyOnly)
    }
    @Test func restorationPreservesNewerUserClipboardAndAllOriginalTypes() throws {
        let board = NSPasteboard(name: .init("dctt-tests-\(UUID())"))
        board.setString("original", forType: .string)
        let snapshot = try #require(ClipboardSnapshot(board))
        board.clearContents(); board.setString("dictation", forType: .string)
        let ownedCount = board.changeCount
        board.clearContents(); board.setString("newer user copy", forType: .string)
        snapshot.restore(to: board, ifOwned: ownedCount)
        #expect(board.string(forType: .string) == "newer user copy")
        snapshot.restore(to: board, ifOwned: board.changeCount)
        #expect(board.string(forType: .string) == "original")
    }
}
