import Foundation
import CryptoKit
import Testing
@testable import DcttCore

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ModelPreparationProgress] = []
    func append(_ value: ModelPreparationProgress) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    var events: [ModelPreparationProgress] { lock.lock(); defer { lock.unlock() }; return values }
}

private actor FixtureDownloader: ModelAssetDownloading {
    let contents: [String: Data]
    let pause: String?
    private(set) var requests: [String] = []
    init(_ contents: [String: Data], pause: String? = nil) { self.contents = contents; self.pause = pause }
    func download(_ url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        let name = url.lastPathComponent
        requests.append(name)
        if name == pause { while true { try await AppDelay.sleep(milliseconds: 10) } }
        guard let data = contents[name] else { throw DcttError.message("Synthetic network failure") }
        progress(Int64(data.count / 2)); progress(Int64(data.count))
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: temporary)
        return temporary
    }
}

struct ModelDownloadTests {
    private func fixture() throws -> (URL, ModelDescriptor, [String: Data]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let contents = ["first": Data("first fixture asset".utf8), "second": Data("second fixture asset".utf8)]
        let files = contents.keys.sorted().map { key in
            let bytes = contents[key]!
            return ModelAsset(path: key, url: URL(string: "https://example.invalid/\(key)")!, bytes: Int64(bytes.count),
                hash: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), algorithm: "sha256")
        }
        return (root, ModelDescriptor(id: "fixture", name: "Fixture", engine: "whisper", revision: "fixture", files: files), contents)
    }
    @Test(arguments: [false, true]) func nativeURLSessionReportsRealTransferBytes(cancel: Bool) async throws {
        // A loopback-only HTTP fixture exercises the production download delegate.
        let server = Process(), output = Pipe()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        server.arguments = ["python3", "-u", "-c", """
import http.server, time
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Length', '524288')
        self.end_headers()
        for _ in range(16):
            self.wfile.write(b'x' * 32768)
            self.wfile.flush()
            time.sleep(0.02)
    def log_message(self, *args): pass
server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
server.timeout = 10
print(server.server_port, flush=True)
server.handle_request()
server.server_close()
"""]
        server.standardOutput = output
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { if server.isRunning { server.terminate() }; server.waitUntilExit() }
        let line = output.fileHandleForReading.availableData
        let port = try #require(Int(String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        let log = ProgressLog()
        let download = Task {
            try await URLSessionModelDownloader().download(URL(string: "http://127.0.0.1:\(port)/fixture")!) {
                log.append(.init(stage: .downloading, receivedBytes: $0, totalBytes: 524288))
            }
        }
        if cancel {
            for _ in 0..<200 {
                if !log.events.isEmpty { break }
                try await AppDelay.sleep(milliseconds: 5)
            }
            download.cancel()
            await #expect(throws: CancellationError.self) { try await download.value }
            #expect(!log.events.isEmpty)
            return
        }
        let temporary = try await download.value
        defer { try? FileManager.default.removeItem(at: temporary) }
        #expect(try Data(contentsOf: temporary) == Data(repeating: 120, count: 524288))
        #expect(log.events.count >= 2)
        #expect(log.events.last?.receivedBytes == 524288)
        #expect(log.events.map(\.receivedBytes) == log.events.map(\.receivedBytes).sorted())
    }
    @Test func verifiedCacheExcludedFromDownloadByteTotal() async throws {
        let (root, model, contents) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent(model.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try contents["first"]!.write(to: folder.appendingPathComponent("first"))
        let transport = FixtureDownloader(contents), log = ProgressLog()
        let store = ModelStore(root: root, downloader: transport)
        try await store.prepare(model) { log.append($0) }
        try await store.validate(model)
        #expect(await transport.requests == ["second"])
        let downloads = log.events.filter { $0.stage == .downloading }
        #expect(!downloads.isEmpty)
        #expect(downloads.allSatisfy { $0.totalBytes == Int64(contents["second"]!.count) })
        #expect(downloads.map(\.receivedBytes) == downloads.map(\.receivedBytes).sorted())
        #expect(log.events.last?.completedFiles == 2)
        #expect(log.events.last?.fraction == nil)
    }
    @Test func corruptSameSizeFileIsDownloadedAgain() async throws {
        let (root, model, contents) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = FixtureDownloader(contents), store = ModelStore(root: root, downloader: transport)
        try await store.prepare(model)
        let file = root.appendingPathComponent(model.id).appendingPathComponent("first")
        try Data(repeating: 0, count: contents["first"]!.count).write(to: file)
        try await store.prepare(model)
        #expect(await transport.requests == ["first", "second", "first"])
        try await store.validate(model)
    }
    @Test func failedIntegrityDoesNotInstallDownloadedAsset() async throws {
        let (root, model, contents) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var corrupt = contents; corrupt["first"] = Data(repeating: 0, count: contents["first"]!.count)
        let store = ModelStore(root: root, downloader: FixtureDownloader(corrupt))
        await #expect(throws: (any Error).self) { try await store.prepare(model) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(model.id).appendingPathComponent("first").path))
    }
    @Test func cancellationKeepsVerifiedFilesForRetry() async throws {
        let (root, model, contents) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = FixtureDownloader(contents, pause: "second")
        let store = ModelStore(root: root, downloader: transport)
        let task = Task { try await store.prepare(model) }
        for _ in 0..<200 {
            if await transport.requests.contains("second") { break }
            try await AppDelay.sleep(milliseconds: 10)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await transport.requests.contains("second"))
        let retry = FixtureDownloader(contents)
        let retryStore = ModelStore(root: root, downloader: retry)
        try await retryStore.prepare(model)
        #expect(await retry.requests == ["second"])
        try await retryStore.validate(model)
    }
    @Test func insufficientSpaceStopsBeforeNetworkAndCachedModelNeedsNoSpace() async throws {
        let (root, model, contents) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = FixtureDownloader(contents)
        let store = ModelStore(root: root, downloader: transport, availableCapacity: { _ in 1 })
        await #expect(throws: (any Error).self) { try await store.prepare(model) }
        #expect(await transport.requests.isEmpty)
        try await ModelStore(root: root, downloader: transport).prepare(model)
        try await store.prepare(model)
        #expect(await transport.requests == ["first", "second"])
    }
    @Test func connectionFailureLeavesPreviouslyVerifiedAssets() async throws {
        let (root, model, contents) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModelStore(root: root, downloader: FixtureDownloader(["first": contents["first"]!]))
        await #expect(throws: (any Error).self) { try await store.prepare(model) }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(model.id).appendingPathComponent("first").path))
        #expect(!(await store.isPrepared(model)))
    }
}
