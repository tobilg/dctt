import AppKit
import ApplicationServices
import Carbon

public struct Destination {
    public let pid: pid_t
    public let bundleID: String
    public let name: String
    public let generation: Int
    public let window: AXUIElement?
    public let element: AXUIElement?
    public let secure: Bool
    public var fieldRole: String? = nil
    public var requiresTextFieldIdentity: Bool {
        ["com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox"].contains(bundleID)
    }
    public var hasTextFieldIdentity: Bool {
        window != nil && element != nil &&
            [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(fieldRole ?? "")
    }
    public var terminal: Bool { TextPolicy.terminalBundleIDs.contains(bundleID) }
}

/// Content-free explanations for diagnostics; delivery status remains unchanged.
public enum PasteBlockReason: String, Sendable {
    case cancelled, accessibilityDenied, secureInput, secureField, modifiersHeld
    case targetChanged, fieldIdentityUnavailable, eventCreationFailed, clipboardWriteFailed
}

@MainActor public final class DeliveryService {
    // Internal test seams exercise the actual paste path without posting keys.
    var hooks = DeliveryHooks()
    private(set) var generation = 0
    public private(set) var lastBlockReason: PasteBlockReason?
    private var observer: NSObjectProtocol?
    public init() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.generation += 1
                self?.prepareBrowserAccessibility()
            }
        }
        prepareBrowserAccessibility()
    }
    deinit { if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) } }
    public static var trusted: Bool { AXIsProcessTrusted() }
    public static var secureInput: Bool { IsSecureEventInputEnabled() }
    public static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        // Timeouts belong to each AX object; the app-root timeout is not inherited.
        AXUIElementSetMessagingTimeout(element, 0.15)
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }
    private func axElement(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private func prepareBrowserAccessibility() {
        guard Self.trusted, let app = NSWorkspace.shared.frontmostApplication,
              ["com.google.Chrome", "org.mozilla.firefox"].contains(app.bundleIdentifier ?? "") else { return }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        if app.bundleIdentifier == "org.mozilla.firefox" {
            // Firefox 121+ activates accessibility on application-role reads.
            // Reading only the focused container's role does not activate it.
            // Mozilla bug 1845364; no preference or VoiceOver mode is changed.
            _ = attribute(root, kAXRoleAttribute)
            return
        }
        // Chromium enables its lazy accessibility tree when an assistive client
        // requests this attribute. This does not alter a saved browser preference.
        AXUIElementSetMessagingTimeout(root, 0.15)
        if (attribute(root, "AXEnhancedUserInterface") as? Bool) != true {
            _ = AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }
    private func focusedElement(_ root: AXUIElement) -> AXUIElement? {
        var current = axElement(root, kAXFocusedUIElementAttribute)
        var seen: [AXUIElement] = []
        // Firefox can expose a root group/web area with a further focused child.
        // Follow only that focus chain; never walk or read page contents.
        for _ in 0..<4 {
            guard let element = current else { break }
            if [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(attribute(element, kAXRoleAttribute) as? String ?? "") { break }
            seen.append(element)
            guard let next = axElement(element, kAXFocusedUIElementAttribute),
                  !seen.contains(where: { CFEqual($0, next) }) else { break }
            current = next
        }
        return current
    }
    public func snapshot() -> Destination? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        prepareBrowserAccessibility()
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.15)
        let element = focusedElement(root)
        let secure = element.map { (attribute($0, kAXSubroleAttribute) as? String) == kAXSecureTextFieldSubrole } ?? false
        return Destination(pid: app.processIdentifier, bundleID: app.bundleIdentifier ?? "",
            name: app.localizedName ?? "Unknown app", generation: generation,
            window: axElement(root, kAXFocusedWindowAttribute), element: element, secure: secure,
            fieldRole: element.flatMap { attribute($0, kAXRoleAttribute) as? String })
    }
    public func matches(_ original: Destination) -> Bool {
        guard let current = hooks.snapshot?() ?? snapshot(), current.pid == original.pid,
              current.generation == original.generation, !current.secure else { return false }
        if original.requiresTextFieldIdentity {
            guard original.hasTextFieldIdentity, current.hasTextFieldIdentity else { return false }
        }
        if let old = original.window { guard let new = current.window, CFEqual(old, new) else { return false } }
        if let old = original.element { guard let new = current.element, CFEqual(old, new) else { return false } }
        return true
    }
    public static var physicalModifiersDown: Bool {
        let flags = CGEventSource.flagsState(.hidSystemState)
        return !flags.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]).isEmpty
    }
    public func paste(_ text: String, to destination: Destination, restoreClipboard: Bool,
               stillValid: () -> Bool) async -> DeliveryStatus {
        lastBlockReason = nil
        for _ in 0..<60 {
            guard stillValid() else { return blocked(.copyOnly, .cancelled) }
            if !hooks.modifiersDown() { break }
            await hooks.pause()
        }
        guard stillValid() else { return blocked(.copyOnly, .cancelled) }
        guard hooks.trusted() else { return blocked(.permissionDenied, .accessibilityDenied) }
        guard !hooks.secureInput() else { return blocked(.copyOnly, .secureInput) }
        guard !destination.secure else { return blocked(.copyOnly, .secureField) }
        guard !destination.requiresTextFieldIdentity || destination.hasTextFieldIdentity else {
            return blocked(.copyOnly, .fieldIdentityUnavailable)
        }
        guard !hooks.modifiersDown() else { return blocked(.copyOnly, .modifiersHeld) }
        guard targetMatches(destination) else { return blocked(.targetChanged, .targetChanged) }
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return blocked(.deliveryFailed, .eventCreationFailed) }
        // These are the only synthetic keys in the application: fixed Command–V.
        down.flags = .maskCommand
        up.flags = []
        let pasteboard = hooks.pasteboard
        let previous = restoreClipboard ? ClipboardSnapshot(pasteboard) : nil
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return blocked(.deliveryFailed, .clipboardWriteFailed) }
        let ownedCount = pasteboard.changeCount
        let finalBlock: PasteBlockReason?
        if !stillValid() { finalBlock = .cancelled }
        else if !targetMatches(destination) { finalBlock = .targetChanged }
        else if hooks.secureInput() { finalBlock = .secureInput }
        else if hooks.modifiersDown() { finalBlock = .modifiersHeld }
        else { finalBlock = nil }
        if let finalBlock {
            previous?.restore(to: pasteboard, ifOwned: ownedCount)
            return blocked(.targetChanged, finalBlock)
        }
        if let request = hooks.requestPaste { request() }
        else {
            // Inject into the session, below the physical HID state we inspect.
            // HID-level Command–V left Command latched and blocked later pastes.
            hooks.postEvents(down, up, .cgSessionEventTap)
        }
        if let previous {
            Task { @MainActor in
                try? await AppDelay.sleep(milliseconds: 1_000)
                previous.restore(to: pasteboard, ifOwned: ownedCount)
            }
        }
        return .pasteRequested
    }
    private func blocked(_ status: DeliveryStatus, _ reason: PasteBlockReason) -> DeliveryStatus {
        lastBlockReason = reason
        return status
    }
    private func targetMatches(_ destination: Destination) -> Bool {
        hooks.matches?(destination) ?? matches(destination)
    }
    @discardableResult public static func copy(_ text: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }
}

@MainActor struct DeliveryHooks {
    var trusted: () -> Bool = { DeliveryService.trusted }
    var secureInput: () -> Bool = { DeliveryService.secureInput }
    var modifiersDown: () -> Bool = { DeliveryService.physicalModifiersDown }
    var pause: () async -> Void = { try? await AppDelay.sleep(milliseconds: 25) }
    var matches: ((Destination) -> Bool)?
    var snapshot: (() -> Destination?)?
    var requestPaste: (() -> Void)?
    var postEvents: (CGEvent, CGEvent, CGEventTapLocation) -> Void = { down, up, tap in
        down.post(tap: tap); up.post(tap: tap)
    }
    var pasteboard = NSPasteboard.general
}

/// Copy data, never retain live pasteboard items. Skip huge clipboard payloads.
@MainActor struct ClipboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]
    init?(_ pasteboard: NSPasteboard) {
        var result: [[NSPasteboard.PasteboardType: Data]] = []
        var bytes = 0
        for item in pasteboard.pasteboardItems ?? [] {
            var values: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                bytes += data.count
                guard bytes <= 8_000_000 else { return nil }
                values[type] = data
            }
            result.append(values)
        }
        items = result
    }
    func restore(to pasteboard: NSPasteboard, ifOwned count: Int) {
        guard pasteboard.changeCount == count else { return }
        let restored = items.map { data -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, bytes) in data { item.setData(bytes, forType: type) }
            return item
        }
        pasteboard.clearContents()
        pasteboard.writeObjects(restored)
    }
}
