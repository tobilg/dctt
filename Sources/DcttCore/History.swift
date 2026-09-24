import Foundation

public struct HistoryRecord: Codable, Identifiable, Sendable {
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", id, timestampUTC = "timestamp_utc", text
        case engineID = "engine_id", engineVersion = "engine_version", modelID = "model_id", modelRevision = "model_revision"
        case requestedLanguage = "requested_language", detectedLanguage = "detected_language"
        case audioDurationMS = "audio_duration_ms", transcriptionDurationMS = "transcription_duration_ms"
        case cleanupMode = "cleanup_mode", targetAppName = "target_app_name", targetBundleID = "target_bundle_id"
        case deliveryStatus = "delivery_status"
    }
    public let schemaVersion: Int
    public let id: UUID
    public let timestampUTC: Date
    public let text: String
    public let engineID: String
    public let engineVersion: String
    public let modelID: String
    public let modelRevision: String
    public let requestedLanguage: String
    public let detectedLanguage: String?
    public let audioDurationMS: Int
    public let transcriptionDurationMS: Int
    public let cleanupMode: String
    public let targetAppName: String?
    public let targetBundleID: String?
    public let deliveryStatus: DeliveryStatus

    public init(id: UUID = UUID(), text: String, model: ModelDescriptor, detectedLanguage: String? = nil,
                audioSeconds: Double, transcriptionSeconds: Double, cleanup: Bool,
                targetAppName: String? = nil, targetBundleID: String? = nil, deliveryStatus: DeliveryStatus) {
        schemaVersion = 1; self.id = id; timestampUTC = Date(); self.text = text
        engineID = model.engine; engineVersion = model.engineVersion; modelID = model.id; modelRevision = model.revision
        requestedLanguage = "en"; self.detectedLanguage = detectedLanguage
        audioDurationMS = Int(audioSeconds * 1000); transcriptionDurationMS = Int(transcriptionSeconds * 1000)
        cleanupMode = cleanup ? "basic" : "literal"
        self.targetAppName = targetAppName; self.targetBundleID = targetBundleID; self.deliveryStatus = deliveryStatus
    }
}

/// Synchronous file operations on one actor serialize append, reads, and deletion.
/// Every mutation verifies the app-owned header and refuses symlinks/unrelated files.
public actor HistoryStore {
    public static let filename = "dctt-history-v1.jsonl"
    // Only accept v1 files owned by the current app identity.
    private static let header = Data("{\"app_id\":\"com.tobilg.dctt\",\"history_schema\":1}\n".utf8)
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    public init() {
        encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    }
    private func ownedFile(in folder: URL, create: Bool) throws -> URL? {
        let file = folder.appendingPathComponent(Self.filename)
        let fm = FileManager.default
        if let attributes = try? fm.attributesOfItem(atPath: file.path), attributes[.type] as? FileAttributeType != .typeRegular {
            throw DcttError.message("History file is not a regular file. Choose another folder.")
        }
        if !fm.fileExists(atPath: file.path) {
            guard create else { return nil }
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard fm.createFile(atPath: file.path, contents: Self.header, attributes: [.posixPermissions: 0o600]) else {
                throw DcttError.message("History folder is not writable. Choose another folder; your latest text remains available.")
            }
        }
        let attributes = try fm.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw DcttError.message("History file is not a regular file. Choose another folder.")
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        guard try handle.read(upToCount: Self.header.count) == Self.header else {
            throw DcttError.message("A different file already uses dctt's history filename. Choose another folder.")
        }
        return file
    }
    public func append(_ record: HistoryRecord, folder: URL?) throws {
        guard let folder else { return }
        let file = try ownedFile(in: folder, create: true)!
        let handle = try FileHandle(forUpdating: file)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            if try handle.read(upToCount: 1) != Data([10]) {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data([10])) // Isolate an incomplete crash tail.
            }
        }
        try handle.seekToEnd()
        var bytes = try encoder.encode(record)
        bytes.append(10)
        try handle.write(contentsOf: bytes)
        try handle.synchronize()
    }
    public func recent(folder: URL, limit: Int = 200) throws -> [HistoryRecord] {
        guard let file = try ownedFile(in: folder, create: false) else { return [] }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        let offset = end > 4_194_304 ? end - 4_194_304 : 0
        try handle.seek(toOffset: offset)
        let data = try handle.readToEnd() ?? Data()
        var lines = data.split(separator: 10)
        if offset > 0, !lines.isEmpty { lines.removeFirst() }
        return lines.reversed().compactMap { try? decoder.decode(HistoryRecord.self, from: Data($0)) }.prefix(max(0, min(limit, 200))).map { $0 }
    }
    public func deleteAll(folder: URL) throws {
        guard let file = try ownedFile(in: folder, create: false) else { return }
        try FileManager.default.removeItem(at: file)
    }
    public func delete(id: UUID, folder: URL) throws {
        guard let file = try ownedFile(in: folder, create: false) else { return }
        let temporary = folder.appendingPathComponent(".dctt-history-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw DcttError.message("Could not update history. Check folder access and disk space.")
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let input = try FileHandle(forReadingFrom: file)
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? input.close(); try? output.close() }
        var pending = Data()
        while let chunk = try input.read(upToCount: 65_536), !chunk.isEmpty {
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline])
                if (try? decoder.decode(HistoryRecord.self, from: line).id) != id {
                    try output.write(contentsOf: line + Data([10]))
                }
                pending.removeSubrange(...newline)
            }
            guard pending.count <= 4_194_304 else { throw DcttError.message("A history line is damaged or too large. Use Reveal to inspect the file.") }
        }
        if !pending.isEmpty { try output.write(contentsOf: pending) }
        try output.synchronize()
        try output.close()
        _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
    }
    public func export(_ record: HistoryRecord, to url: URL) throws {
        try Data(record.text.utf8).write(to: url, options: .atomic)
    }
}
