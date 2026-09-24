import Foundation

/// UI lifetime is independent of the capture gate: recovery can outlive a session.
public struct SessionPresentation: Sendable, Equatable {
    public enum Phase: Sendable { case hidden, starting, listening, transcribing, waiting, cancelling, pasteRequested, recovery, failure, cancelled }
    public private(set) var id: UUID?
    public private(set) var phase: Phase = .hidden
    public private(set) var message = ""
    public private(set) var recoveryText = ""
    public init() {}
    public mutating func begin(_ id: UUID) {
        self.id = id; phase = .starting; message = "Starting microphone"; recoveryText = ""
    }
    public mutating func update(_ id: UUID, phase: Phase, message: String, text: String = "") {
        guard self.id == id else { return }
        self.phase = phase; self.message = message; recoveryText = text
    }
    @discardableResult public mutating func dismiss(_ id: UUID) -> Bool {
        guard self.id == id else { return false }
        self.id = nil; phase = .hidden; recoveryText = ""
        return true
    }
}

extension DeliveryStatus {
    public var label: String {
        switch self {
        case .pasteRequested: return "Paste requested"
        case .targetChanged: return "Destination changed · Copy required"
        case .permissionDenied: return "Permission needed · Copy required"
        case .deliveryFailed: return "Paste unavailable · Copy required"
        case .copyOnly: return "Copy required"
        }
    }
}

public enum HistorySearch {
    public static func filter(_ records: [HistoryRecord], query: String) -> [HistoryRecord] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return records }
        return records.filter { $0.text.localizedStandardContains(query) || ($0.targetAppName?.localizedStandardContains(query) ?? false) }
    }
}
