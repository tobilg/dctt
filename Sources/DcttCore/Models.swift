import Foundation
import CryptoKit
import WhisperKit
import FluidAudio

public struct ModelAsset: Codable, Sendable {
    public let path: String
    public let url: URL
    public let bytes: Int64
    public let hash: String
    public let algorithm: String
}

public struct ModelDescriptor: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let engine: String
    public let revision: String
    public let files: [ModelAsset]
    public var size: Int64 { files.reduce(0) { $0 + $1.bytes } }
    public var engineVersion: String { engine == "whisper" ? "1.1.0+dctt-offline" : "0.16.1+dctt-private" }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public static let catalog: [Self] = {
        let resources = Bundle.main.resourceURL.flatMap { Bundle(url: $0.appendingPathComponent("dctt_DcttCore.bundle")) } ?? Bundle.module
        let url = resources.url(forResource: "models", withExtension: "json")!
        return try! JSONDecoder().decode([Self].self, from: Data(contentsOf: url))
    }()
}

public enum DcttError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

public enum AppPaths {
    public static let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/dctt", isDirectory: true)
    public static let models = support.appendingPathComponent("Models", isDirectory: true)
    public static let history = support.appendingPathComponent("History", isDirectory: true)
}

/// Only prepare() performs network I/O. Loading and transcription cannot fetch assets.
public actor ModelStore {
    public let root: URL
    private let downloader: any ModelAssetDownloading
    private let availableCapacity: @Sendable (URL) throws -> Int64?
    public init(root: URL = AppPaths.models) {
        self.root = root
        downloader = URLSessionModelDownloader()
        availableCapacity = { try $0.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage }
    }
    init(root: URL, downloader: any ModelAssetDownloading, availableCapacity: @escaping @Sendable (URL) throws -> Int64? = { _ in nil }) {
        self.root = root; self.downloader = downloader; self.availableCapacity = availableCapacity
    }
    public func folder(_ model: ModelDescriptor) -> URL { root.appendingPathComponent(model.id) }

    public func isPrepared(_ model: ModelDescriptor) -> Bool {
        let directory = folder(model)
        return model.files.allSatisfy {
            let u = directory.appendingPathComponent($0.path)
            return (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int($0.bytes)
        }
    }

    public func validate(_ model: ModelDescriptor) throws {
        for file in model.files {
            try Task.checkCancellation()
            guard try valid(file, at: folder(model).appendingPathComponent(file.path)) else {
                throw DcttError.message("Model assets are missing or damaged. Choose Repair in Settings → Models.")
            }
        }
    }

    private func valid(_ file: ModelAsset, at url: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count == file.bytes else { return false }
        let digest: String
        if file.algorithm == "sha256" {
            digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        } else {
            var hasher = Insecure.SHA1()
            hasher.update(data: Data("blob \(data.count)\0".utf8))
            hasher.update(data: data)
            digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return digest == file.hash
    }

    public func prepare(_ model: ModelDescriptor,
                        progress: @escaping @Sendable (ModelPreparationProgress) -> Void = { _ in }) async throws {
        let directory = folder(model)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var missing: [ModelAsset] = []
        for (index, file) in model.files.enumerated() {
            try Task.checkCancellation()
            progress(.init(stage: .checking, completedFiles: index, totalFiles: model.files.count))
            if (try? valid(file, at: directory.appendingPathComponent(file.path))) != true { missing.append(file) }
        }
        let totalBytes = missing.reduce(Int64(0)) { $0 + $1.bytes }
        if !missing.isEmpty, let free = try availableCapacity(directory), free < totalBytes + 512_000_000 {
            throw DcttError.message("Not enough disk space. Free at least \(ByteCountFormatter.string(fromByteCount: totalBytes + 512_000_000, countStyle: .file)), then retry.")
        }
        var received: Int64 = 0
        var verified = model.files.count - missing.count
        for file in missing {
            try Task.checkCancellation()
            let base = received, count = verified
            progress(.init(stage: .downloading, completedFiles: count, totalFiles: model.files.count,
                           receivedBytes: base, totalBytes: totalBytes))
            let temporary = try await downloader.download(file.url) { bytes in
                progress(.init(stage: .downloading, completedFiles: count, totalFiles: model.files.count,
                               receivedBytes: base + max(0, min(bytes, file.bytes)), totalBytes: totalBytes))
            }
            defer { try? FileManager.default.removeItem(at: temporary) }
            try Task.checkCancellation()
            received += file.bytes
            progress(.init(stage: .verifying, completedFiles: verified, totalFiles: model.files.count,
                           receivedBytes: received, totalBytes: totalBytes))
            guard try valid(file, at: temporary) else {
                throw DcttError.message("A model download failed its integrity check. Retry to download it again.")
            }
            try Task.checkCancellation()
            let destination = directory.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: temporary, to: destination)
            verified += 1
        }
        progress(.init(stage: .verifying, completedFiles: verified, totalFiles: model.files.count,
                       receivedBytes: received, totalBytes: totalBytes))
    }

}

public struct Recognition: Sendable {
    public let text: String
    public let detectedLanguage: String?
    public let seconds: Double
    public init(text: String, detectedLanguage: String? = nil, seconds: Double) {
        self.text = text; self.detectedLanguage = detectedLanguage; self.seconds = seconds
    }
}

public protocol SpeechRecognizing: Sendable {
    func transcribe(_ samples: [Float]) async throws -> Recognition
}

/// Coordinator enforces one job across awaits; this actor owns all SDK objects.
public actor SpeechEngine: SpeechRecognizing {
    private var whisper: WhisperKit?
    private var parakeet: AsrManager?
    private var busy = false
    public private(set) var loadedID: String?
    public init() {}

    public func load(_ model: ModelDescriptor, from folder: URL) async throws {
        guard !busy else { throw DcttError.message("Recognition is still finishing. Try again shortly.") }
        busy = true
        defer { busy = false }
        whisper = nil
        await parakeet?.cleanup()
        parakeet = nil
        loadedID = nil
        if model.engine == "whisper" {
            whisper = try await WhisperKit(WhisperKitConfig(
                modelFolder: folder.path, tokenizerFolder: folder,
                verbose: false, logLevel: .none, prewarm: false, load: true, download: false))
        } else {
            let models = try AsrModels.loadLocal(from: folder, version: .v2)
            let manager = AsrManager(config: ASRConfig(parallelChunkConcurrency: 1, streamingEnabled: false))
            try await manager.loadModels(models)
            parakeet = manager
        }
        loadedID = model.id
    }

    public func transcribe(_ samples: [Float]) async throws -> Recognition {
        guard !busy else { throw DcttError.message("Recognition is busy.") }
        busy = true
        defer { busy = false }
        let start = ContinuousClock.now
        let text: String
        if let whisper {
            let options = DecodingOptions(verbose: false, task: .transcribe, language: "en",
                temperatureFallbackCount: 2, detectLanguage: false, skipSpecialTokens: true,
                withoutTimestamps: false, wordTimestamps: false, concurrentWorkerCount: 1)
            let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
            text = results.map(\.text).joined(separator: " ")
        } else if let parakeet {
            var state = try TdtDecoderState()
            text = try await parakeet.transcribe(samples, decoderState: &state).text
        } else {
            throw DcttError.message("Prepare a model in Settings first.")
        }
        let duration = start.duration(to: .now)
        return Recognition(text: text, seconds: Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
    }
}
