import Foundation
import DcttCore
import Darwin

@main struct DcttCheck {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 3, let model = ModelDescriptor.catalog.first(where: { $0.id == args[2] }) else {
            print("Usage: dctt-check prepare|load|benchmark <whisper-small-en|parakeet-v2> [model-directory] [fixture-directory]")
            return
        }
        let root = args.count > 3 ? URL(fileURLWithPath: args[3]) : AppPaths.models
        let store = ModelStore(root: root)
        let start = Date()
        if args[1] == "prepare" { try await store.prepare(model) { progress in print("\(progress.stage.rawValue): \(progress.completedFiles)/\(progress.totalFiles) files · \(progress.receivedBytes)/\(progress.totalBytes) download bytes") } }
        try await store.validate(model)
        let engine = SpeechEngine()
        try await engine.load(model, from: store.folder(model))
        let loadSeconds = Date().timeIntervalSince(start)
        if args[1] != "benchmark" { print("Loaded \(model.id) in \(loadSeconds) seconds"); return }
        guard args.count > 4 else { throw DcttError.message("Pass the fixture directory after the model directory.") }
        let fixtureRoot = URL(fileURLWithPath: args[4])
        var measurements: [[String: Any]] = []
        for (name, runs) in [("short", 6), ("long", 3), ("maximum", 1)] {
            let samples = try AudioRecorder.readFixture(fixtureRoot.appendingPathComponent(name + ".wav"))
            let reference = try String(contentsOf: fixtureRoot.appendingPathComponent(name + ".txt"), encoding: .utf8)
            for index in 0..<runs {
                let result = try await engine.transcribe(samples)
                measurements.append(["fixture": name, "iteration": index, "audio_seconds": Double(samples.count) / 16000,
                    "inference_seconds": result.seconds, "word_error_rate": wordErrorRate(reference: reference, hypothesis: result.text)])
            }
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        var memory = rusage_info_v4()
        let memoryStatus = withUnsafeMutablePointer(to: &memory) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        let report: [String: Any] = ["model": model.id, "revision": model.revision,
            "engine_version": model.engineVersion, "validated_load_seconds": loadSeconds,
            "peak_resident_bytes": usage.ru_maxrss, "peak_physical_footprint_bytes": memoryStatus == 0 ? memory.ri_lifetime_max_phys_footprint : 0,
            "measurements": measurements,
            "silence_gate_rejects": !AudioPolicy.hasSignal(Array(repeating: 0, count: 160000))]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if args.count > 5 {
            try data.write(to: URL(fileURLWithPath: args[5]), options: .atomic)
        } else {
            FileHandle.standardOutput.write(data)
            print("")
        }
    }

    static func wordErrorRate(reference: String, hypothesis: String) -> Double {
        func words(_ value: String) -> [String] {
            value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        }
        let a = words(reference), b = words(hypothesis)
        var row = Array(0...b.count)
        for (i, word) in a.enumerated() {
            var next = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, other) in b.enumerated() { next[j + 1] = min(next[j] + 1, row[j + 1] + 1, row[j] + (word == other ? 0 : 1)) }
            row = next
        }
        return Double(row.last!) / Double(max(1, a.count))
    }
}
