import Foundation

public struct ModelPreparationProgress: Sendable, Equatable {
    public enum Stage: String, Sendable { case checking = "Checking files", downloading = "Downloading", verifying = "Verifying", loading = "Preparing model" }
    public let stage: Stage
    public let completedFiles: Int
    public let totalFiles: Int
    public let receivedBytes: Int64
    public let totalBytes: Int64
    public init(stage: Stage, completedFiles: Int = 0, totalFiles: Int = 0, receivedBytes: Int64 = 0, totalBytes: Int64 = 0) {
        self.stage = stage; self.completedFiles = completedFiles; self.totalFiles = totalFiles
        self.receivedBytes = receivedBytes; self.totalBytes = totalBytes
    }
    public var fraction: Double? {
        guard stage == .downloading, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(receivedBytes) / Double(totalBytes)))
    }
}

/// Injectable transport for deterministic download, cancellation, and integrity tests.
protocol ModelAssetDownloading: Sendable {
    func download(_ url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL
}

struct URLSessionModelDownloader: ModelAssetDownloading {
    func download(_ url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        try await DownloadOperation(progress).run(url)
    }
}

/// Owns one delegate-backed task. Async download(from:) does not forward byte
/// callbacks reliably; retaining the delegate at the session level is essential.
private final class DownloadOperation: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let progress: @Sendable (Int64) -> Void
    private var lastUpdate = Date.distantPast
    private var cancelled = false
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?
    init(_ progress: @escaping @Sendable (Int64) -> Void) { self.progress = progress }

    func run(_ url: URL) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !cancelled else {
                    lock.unlock(); continuation.resume(throwing: CancellationError()); return
                }
                self.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.urlCache = nil
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                configuration.timeoutIntervalForResource = 1800
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                let task = session.downloadTask(with: url)
                self.session = session; self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: { self.cancel() }
    }
    private func cancel() {
        lock.lock(); cancelled = true; let task = task; lock.unlock()
        task?.cancel()
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let value: Result<URL, Error>
        do {
            guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else {
                throw DcttError.message("Model download failed. Check your connection and retry.")
            }
            // The delegate's temporary file expires on return; take ownership.
            let owned = FileManager.default.temporaryDirectory.appendingPathComponent("dctt-model-" + UUID().uuidString)
            try FileManager.default.moveItem(at: location, to: owned)
            value = .success(owned)
        } catch { value = .failure(error) }
        lock.lock(); result = value; lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = continuation
        let saved = result
        let outcome: Result<URL, Error> = cancelled ? .failure(CancellationError()) :
            error.map { .failure($0) } ?? saved ?? .failure(DcttError.message("Model download did not complete. Retry."))
        self.continuation = nil; self.result = nil; self.task = nil; self.session = nil
        lock.unlock()
        if case .failure = outcome, case .success(let url) = saved { try? FileManager.default.removeItem(at: url) }
        session.finishTasksAndInvalidate()
        continuation?.resume(with: outcome)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock()
        let now = Date()
        let publish = !cancelled && (now.timeIntervalSince(lastUpdate) >= 0.1 || totalBytesWritten == totalBytesExpectedToWrite)
        if publish { lastUpdate = now }
        lock.unlock()
        if publish { progress(totalBytesWritten) }
    }
}
