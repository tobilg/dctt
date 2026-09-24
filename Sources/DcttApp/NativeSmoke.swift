import AppKit
import ApplicationServices
import AVFoundation
import DcttCore
import CryptoKit

/// Explicit developer-only integration check. Creates disposable inputs, uses a
/// supplied synthetic fixture, and reports booleans/timings, never recognized text.
/// It does not substitute for the microphone/physical-shortcut test.
@MainActor enum NativeSmoke {
    // Runs in the fully linked release executable without privacy permissions.
    // A unit-test executable alone did not expose the cross-module Swift crash.
    static func checkWaitRuntime(report: URL) async {
        var output: [String: Any] = [:]
        do {
            for delay: UInt64 in [15, 25, 60, 350, 500, 600, 1_000] {
                try await AppDelay.sleep(milliseconds: delay)
            }
            let cancelled = Task { () -> Bool in
                do { try await AppDelay.sleep(milliseconds: 5_000); return false }
                catch is CancellationError { return true }
                catch { return false }
            }
            cancelled.cancel()
            output["waits_completed"] = true
            output["cancellation_observed"] = await cancelled.value
        } catch { output["error"] = error.localizedDescription }
        if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: report, options: .atomic)
        }
        NSApplication.shared.terminate(nil)
    }

    static func run(target: String, fixture: URL, report: URL) async {
        var output: [String: Any] = ["target": target, "microphone_test": false]
        do {
            // Let AppKit finish launching and allow a recent OS grant to propagate.
            for _ in 0..<20 {
                if DeliveryService.trusted { break }
                try await AppDelay.sleep(milliseconds: 250)
            }
            output["microphone_authorized"] = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            output["accessibility_authorized"] = DeliveryService.trusted
            guard DeliveryService.trusted else { throw DcttError.message("Accessibility permission is required for this native check.") }
            let browser = BrowserFixture(target: target)
            let model = ModelDescriptor.catalog.first { $0.id == "parakeet-v2" }!
            let store = ModelStore(), engine = SpeechEngine()
            try await store.validate(model)
            try await engine.load(model, from: store.folder(model))
            let samples = try AudioRecorder.readFixture(fixture)
            let service = DeliveryService()
            let app = try await createTarget(target, browser: browser)
            output["browser_version"] = app.bundleURL.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
            let destination = try await readyDestination(service, app: app, browser: browser)
            output["snapshot_secure_field"] = destination.secure
            output["snapshot_secure_input"] = DeliveryService.secureInput
            output["snapshot_modifiers_down"] = DeliveryService.physicalModifiersDown
            output["text_field_identity_available"] = destination.hasTextFieldIdentity
            // AXRole is classified, not logged verbatim; no field contents,
            // labels, URLs, or ordinary document titles enter this report.
            output["focused_role_kind"] = destination.fieldRole == kAXTextFieldRole ? "text_field" :
                destination.fieldRole == kAXTextAreaRole ? "text_area" :
                destination.fieldRole == kAXComboBoxRole ? "combo_box" :
                destination.fieldRole == kAXGroupRole ? "container" :
                destination.fieldRole == "AXWebArea" ? "web_area" :
                destination.element == nil ? "unavailable" : "other"
            let panelCoordinator = Coordinator()
            let panelSession = UUID()
            panelCoordinator.presentation.begin(panelSession)
            let recordingPanel = RecordingPanelController(coordinator: panelCoordinator)
            recordingPanel.show()
            defer { recordingPanel.hide() }
            try await AppDelay.sleep(milliseconds: 100)
            let afterPanel = service.snapshot()
            func sameElement(_ original: AXUIElement?, _ current: AXUIElement?) -> Bool {
                switch (original, current) {
                case (nil, nil): return true
                case (.some(let original), .some(let current)): return CFEqual(original, current)
                default: return false
                }
            }
            // Identity checks must also work for the deliberately protected test
            // field. matches() additionally rejects secure fields by design.
            let preserved = afterPanel.map {
                $0.pid == destination.pid && $0.generation == destination.generation &&
                sameElement(destination.window, $0.window) && sameElement(destination.element, $0.element)
            } ?? false
            output["recording_panel_preserved_destination"] = preserved
            guard preserved else { throw DcttError.message("Recording panel changed the destination.") }
            panelCoordinator.presentation.update(panelSession, phase: .transcribing, message: "Transcribing locally")
            let result = try await engine.transcribe(samples)
            let text = TextPolicy.apply(result.text, cleanup: true, terminal: destination.terminal)
            guard !text.isEmpty else { throw DcttError.message("Fixture produced no text.") }
            if let browser, browser.field == .switchField {
                var changed = false
                for _ in 0..<80 {
                    if pageState(browser, destination: destination)?.focus == 2 { changed = true; break }
                    try await AppDelay.sleep(milliseconds: 100)
                }
                guard changed else { throw DcttError.message("The fixture did not change focus; no paste requested.") }
            }
            let outcome = await service.paste(text, to: destination, restoreClipboard: true) { true }
            output["delivery_status"] = outcome.rawValue
            output["block_reason"] = service.lastBlockReason?.rawValue ?? ""
            output["inference_seconds"] = result.seconds
            output["field_identity_available"] = destination.element != nil
            output["window_identity_available"] = destination.window != nil
            output["terminal_payload_has_no_controls"] = !text.unicodeScalars.contains { $0.value < 32 || (127...159).contains($0.value) || $0.value == 0x2028 || $0.value == 0x2029 }
            try await AppDelay.sleep(milliseconds: 350)
            output["post_paste_modifiers_down"] = DeliveryService.physicalModifiersDown
            // Read only the newly created, dedicated test field, and only while
            // it still has the captured identity. Never persist its contents.
            if let browser {
                let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
                var state: BrowserFixture.State?
                for _ in 0..<30 {
                    state = pageState(browser, destination: destination)
                    // A paste event can precede input processing and async digest
                    // publication. Wait for actual contents, not just that event.
                    if outcome != .pasteRequested ||
                        (state?.pasteCount == 1 && state?.digest == digest) { break }
                    try await AppDelay.sleep(milliseconds: 100)
                }
                output["dom_state_available"] = state != nil
                output["dom_paste_count"] = state?.pasteCount ?? -1
                output["dom_value_matches"] = state?.digest == digest
                output["dom_focus"] = state?.focus ?? -1
                if browser.field == .password {
                    output["check_passed"] = outcome != .pasteRequested && state?.pasteCount == 0 &&
                        [.secureField, .secureInput].contains(service.lastBlockReason)
                } else if browser.field == .switchField {
                    output["check_passed"] = outcome == .targetChanged && state?.pasteCount == 0 && state?.focus == 2
                } else {
                    output["check_passed"] = outcome == .pasteRequested && state?.pasteCount == 1 &&
                        state?.digest == digest && !DeliveryService.physicalModifiersDown
                }
            } else if outcome == .pasteRequested, service.matches(destination), let element = destination.element {
                let value = attribute(element, kAXValueAttribute) as? String
                output["destination_contains_fixture_transcript"] = value?.contains(text) ?? false
                output["destination_value_available"] = value != nil
                output["destination_fixture_occurrences"] = value.map { $0.components(separatedBy: text).count - 1 } ?? 0
                output["check_passed"] = value.map { $0.components(separatedBy: text).count - 1 == 1 } ?? false
            }
            try await AppDelay.sleep(milliseconds: 1_000) // Allow owned clipboard restoration.
        } catch {
            output["error"] = error.localizedDescription
        }
        if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: report, options: .atomic)
        }
        NSApplication.shared.terminate(nil)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.15)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private static func pageState(_ browser: BrowserFixture, destination: Destination) -> BrowserFixture.State? {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == destination.pid,
              let window = destination.window else { return nil }
        // Only parse our UUID-tagged document title; never persist a title.
        return browser.state(title: attribute(window, kAXTitleAttribute) as? String)
    }
    private static func readyDestination(_ service: DeliveryService, app: NSRunningApplication,
                                         browser: BrowserFixture?) async throws -> Destination {
        if let browser {
            var unavailableField: Destination?
            for _ in 0..<80 {
                if let destination = service.snapshot(), destination.pid == app.processIdentifier,
                   pageState(browser, destination: destination)?.focus == 1 {
                    if destination.hasTextFieldIdentity || destination.secure || DeliveryService.secureInput { return destination }
                    unavailableField = destination
                } else { unavailableField = nil }
                try await AppDelay.sleep(milliseconds: 100)
            }
            // Exercise production Copy recovery if our dedicated page is ready
            // but the browser never exposes a text field. Positive/switch cases
            // still fail: fallback must not be reported as verified insertion.
            if let destination = unavailableField { return destination }
            throw DcttError.message("The dedicated browser input did not become ready; no paste requested.")
        }
        try await AppDelay.sleep(milliseconds: 1_000)
        guard let destination = service.snapshot(), destination.pid == app.processIdentifier else {
            throw DcttError.message("The dedicated target did not retain focus. No paste requested.")
        }
        return destination
    }
    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }
    private static func newWindowItem(_ element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth < 8 else { return nil }
        if let key = attribute(element, kAXMenuItemCmdCharAttribute) as? String,
           key.lowercased() == "n",
           (attribute(element, kAXMenuItemCmdModifiersAttribute) as? Int ?? -1) == 0 {
            return element
        }
        for child in children(element) {
            if let found = newWindowItem(child, depth: depth + 1) { return found }
        }
        return nil
    }
    private static func createTarget(_ target: String, browser: BrowserFixture?) async throws -> NSRunningApplication {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let bundleID: String
        if let browser { bundleID = browser.bundleID }
        else { switch target {
        case "textedit": bundleID = "com.apple.TextEdit"
        case "terminal": bundleID = "com.apple.Terminal"
        case "iterm2": bundleID = "com.googlecode.iterm2"
        default: throw DcttError.message("Unknown smoke target.")
        } }
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw DcttError.message("The requested test application is not installed.")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dctt-native-\(UUID())")
        if target == "textedit" || browser != nil {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(target == "textedit" ? "dctt-smoke.txt" : "dctt-smoke.html")
            try Data((browser?.html ?? "").utf8).write(to: file)
            return try await NSWorkspace.shared.open([file], withApplicationAt: application, configuration: configuration)
        }
        let app = try await NSWorkspace.shared.openApplication(at: application, configuration: configuration)
        try await AppDelay.sleep(milliseconds: 500)
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let before = attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
        guard let menuValue = attribute(root, kAXMenuBarAttribute), CFGetTypeID(menuValue) == AXUIElementGetTypeID(),
              let item = newWindowItem(menuValue as! AXUIElement),
              AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else {
            throw DcttError.message("Could not create a dedicated terminal window. No paste requested.")
        }
        try await AppDelay.sleep(milliseconds: 600)
        guard let focused = attribute(root, kAXFocusedWindowAttribute),
              !before.contains(where: { CFEqual($0, focused) }) else {
            throw DcttError.message("A new terminal window could not be verified. No paste requested.")
        }
        return app
    }
}
