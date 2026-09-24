@preconcurrency import AVFoundation
import Foundation

public struct AudioStatus: Sendable {
    public var duration: Double = 0
    public var level: Float = 0
    public var firstBufferDelay: Double?
    public var error: Bool = false
}

public enum AudioPolicy {
    public static let sampleRate = 16_000.0
    public static let maximumSamples = 120 * 16_000
    public static func hasSignal(_ samples: [Float]) -> Bool {
        guard samples.count >= 4_000, samples.allSatisfy(\.isFinite) else { return false }
        // Conservative digital-silence gate, not a claim to distinguish all noise from speech.
        let energy = samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count)
        return energy > 0.000_000_09 && (samples.map(abs).max() ?? 0) > 0.001
    }
}

private final class AudioBuffer: @unchecked Sendable {
    let lock = NSLock()
    var samples: [Float] = []
    var status = AudioStatus()
    var started = Date()
    var accepting = true
    init(startedAt: Date) { started = startedAt; samples.reserveCapacity(AudioPolicy.maximumSamples) }
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { fail(); return }
        lock.lock(); defer { lock.unlock() }
        guard accepting else { return }
        if status.firstBufferDelay == nil { status.firstBufferDelay = Date().timeIntervalSince(started) }
        let count = min(Int(buffer.frameLength), AudioPolicy.maximumSamples - samples.count)
        if count > 0 {
            samples.append(contentsOf: UnsafeBufferPointer(start: data, count: count))
            var energy: Float = 0
            for i in 0..<count { energy += data[i] * data[i] }
            status.level = min(1, sqrt(energy / Float(count)) * 8)
        }
        status.duration = Double(samples.count) / AudioPolicy.sampleRate
    }
    func fail() { lock.lock(); status.error = true; lock.unlock() }
    func snapshot() -> AudioStatus { lock.lock(); defer { lock.unlock() }; return status }
    func finish() -> ([Float], Bool) {
        lock.lock(); defer { lock.unlock() }
        accepting = false
        let result = samples
        samples = []
        return (result, status.error)
    }
}

/// The engine and its startup/teardown live away from the UI executor.
public actor AudioRecorder {
    private var engine: AVAudioEngine?
    private var buffer: AudioBuffer?
    public init() {}

    public func start(startedAt: Date = Date()) throws {
        guard engine == nil else { throw DcttError.message("Microphone is already in use by dctt.") }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw DcttError.message("Allow Microphone access in Settings before dictating.")
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioPolicy.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: output) else {
            throw DcttError.message("No usable default microphone. Select an input in macOS Sound settings.")
        }
        let buffer = AudioBuffer(startedAt: startedAt)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { inputBuffer, _ in
            let capacity = AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * output.sampleRate / format.sampleRate)) + 64
            guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { buffer.fail(); return }
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, inputStatus in
                if supplied { inputStatus.pointee = .noDataNow; return nil }
                supplied = true
                inputStatus.pointee = .haveData
                return inputBuffer
            }
            if error != nil || status == .error { buffer.fail() }
            else if converted.frameLength > 0 { buffer.append(converted) }
        }
        do {
            engine.prepare()
            try engine.start()
            self.engine = engine
            self.buffer = buffer
        } catch {
            input.removeTap(onBus: 0)
            throw DcttError.message("Microphone could not start. Check the default input and Microphone permission.")
        }
    }

    public func status() -> AudioStatus { buffer?.snapshot() ?? AudioStatus() }
    public func stop() throws -> [Float] {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        let result = buffer?.finish()
        buffer = nil
        if result?.1 == true { throw DcttError.message("Audio conversion failed. Check your microphone and try again.") }
        return result?.0 ?? []
    }

    /// Explicit development fixtures only; the dictation recorder never uses files.
    public static func readFixture(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard file.length <= AVAudioFramePosition(file.processingFormat.sampleRate * 121),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: format) else { throw DcttError.message("Invalid fixture format or duration.") }
        try file.read(into: input)
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16_000 / file.processingFormat.sampleRate)) + 64
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}
