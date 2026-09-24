import Foundation

public enum TextPolicy {
    public static let terminalBundleIDs: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty"]
    public static func apply(_ text: String, cleanup: Bool, terminal: Bool, singleLine: Bool = false) -> String {
        if terminal || singleLine {
            let lineBreaks: Set<UInt32> = [9, 10, 11, 12, 13, 0x85, 0x2028, 0x2029]
            let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            let scalars = normalized.unicodeScalars.compactMap { scalar -> Unicode.Scalar? in
                if lineBreaks.contains(scalar.value) { return " " }
                if scalar.value < 32 || (127...159).contains(scalar.value) { return nil }
                return scalar
            }
            return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard cleanup else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum DeliveryStatus: String, Codable, Sendable {
    case pasteRequested = "paste_requested"
    case targetChanged = "target_changed"
    case permissionDenied = "permission_denied"
    case deliveryFailed = "delivery_failed"
    case copyOnly = "copy_only"
}

/// Value-type lifecycle gate also used by the native coordinator.
public struct SessionGate: Sendable {
    public enum Phase: Sendable { case idle, starting, recording, transcribing, finalizing, cancelling }
    public private(set) var phase: Phase = .idle
    public private(set) var id: UUID?
    public private(set) var held = false
    private var committed = false
    public init() {}
    public mutating func press() -> UUID? {
        guard phase == .idle else { return nil }
        let id = UUID(); self.id = id; phase = .starting; held = true; committed = false
        return id
    }
    public mutating func release() { held = false }
    public mutating func started(_ id: UUID) -> Bool {
        guard self.id == id, phase == .starting, held else { return false }
        phase = .recording; return true
    }
    public mutating func transcribe(_ id: UUID) -> Bool {
        guard self.id == id, phase == .recording else { return false }
        held = false; phase = .transcribing; return true
    }
    public mutating func finalize(_ id: UUID) -> Bool {
        guard self.id == id, phase == .transcribing else { return false }
        phase = .finalizing; return true
    }
    public mutating func claimCommit(_ id: UUID) -> Bool {
        guard self.id == id, phase == .finalizing, !committed else { return false }
        committed = true; return true
    }
    public func accepts(_ id: UUID) -> Bool { self.id == id && phase != .cancelling }
    public mutating func cancel() { guard phase != .idle else { return }; held = false; phase = .cancelling }
    public mutating func finish(_ id: UUID) {
        guard self.id == id else { return }
        self.id = nil; held = false; phase = .idle
    }
}
