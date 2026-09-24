import AppKit
import AVFoundation
import Combine
import KeyboardShortcuts
import DcttCore

extension KeyboardShortcuts.Name {
    static let dictate = Self("dictate", initial: .init(.space, modifiers: [.control, .option]))
}

@MainActor final class Preferences: ObservableObject {
    @Published var modelID: String { didSet { defaults.set(modelID, forKey: "model") } }
    @Published var cleanup: Bool { didSet { defaults.set(cleanup, forKey: "cleanup") } }
    @Published var singleLine: Bool { didSet { defaults.set(singleLine, forKey: "singleLine") } }
    @Published var restoreClipboard: Bool { didSet { defaults.set(restoreClipboard, forKey: "restoreClipboard") } }
    @Published var historyEnabled: Bool { didSet { defaults.set(historyEnabled, forKey: "historyEnabled") } }
    @Published var historyFolder: String { didSet { defaults.set(historyFolder, forKey: "historyFolder") } }
    @Published var setupState: String { didSet { defaults.set(setupState, forKey: "setupState") } }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["model": "parakeet-v2", "cleanup": true,
                                    "historyFolder": AppPaths.history.path])
        setupState = defaults.string(forKey: "setupState") ?? "unseen"
        modelID = defaults.string(forKey: "model") ?? "parakeet-v2"
        cleanup = defaults.bool(forKey: "cleanup")
        singleLine = defaults.bool(forKey: "singleLine")
        restoreClipboard = defaults.bool(forKey: "restoreClipboard")
        historyEnabled = defaults.bool(forKey: "historyEnabled")
        historyFolder = defaults.string(forKey: "historyFolder") ?? AppPaths.history.path
    }
    var model: ModelDescriptor { ModelDescriptor.catalog.first { $0.id == modelID } ?? ModelDescriptor.catalog[0] }
}

struct SessionOptions {
    let model: ModelDescriptor
    let cleanup: Bool
    let singleLine: Bool
    let restoreClipboard: Bool
    let historyFolder: URL?
}

@MainActor final class Coordinator: ObservableObject {
    let preferences: Preferences
    private let permissionSnapshot: () -> (microphone: Bool, accessibility: Bool)
    init(preferences: Preferences? = nil, permissionSnapshot: (() -> (Bool, Bool))? = nil) {
        self.preferences = preferences ?? Preferences()
        self.permissionSnapshot = permissionSnapshot ?? { (AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, DeliveryService.trusted) }
    }
    let engine = SpeechEngine()
    let models = ModelStore()
    let recorder = AudioRecorder()
    let delivery = DeliveryService()
    let history = HistoryStore()
    @Published var status = "Prepare a model in Settings"
    @Published var busy = false
    @Published var preparing = false
    @Published var readyModel: String?
    @Published var latest = ""
    @Published var duration: Double = 0
    @Published var level: Float = 0
    @Published var microphoneAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @Published var accessibilityAllowed = DeliveryService.trusted
    @Published var lastTimings = ""
    @Published var historyNotice = ""
    @Published var recentHistory: [HistoryRecord] = []
    @Published var presentation = SessionPresentation()
    @Published var preparationProgress: ModelPreparationProgress?
    @Published var preparationError = ""
    @Published var localModels: Set<String> = []
    @Published var setupRequested = false
    @Published var settingsPage: SettingsPage = .general
    @Published var cancellingPreparation = false
    private var preparationID: UUID?
    private var dismissal: Task<Void, Never>?
    private var permissionTimer: Timer?
    private var permissionDeadline = Date.distantPast
    private var checkedInitialSetup = false
    private var historyRequestID = UUID()
    var gate = SessionGate()
    private var cancellationReason: String?
    private var destination: Destination?
    private var options: SessionOptions?
    private var monitor: Task<Void, Never>?
    private var preparingTask: Task<Void, Never>?
    private var observations: [NSObjectProtocol] = []
    private var pressTime = Date()
    private var diagnosticsTimer: Timer?
    private var pressCount = 0
    private var releaseCount = 0
    private var pasteRequestCount = 0
    private var panel: RecordingPanelController?
    var recording: Bool { gate.phase == .starting || gate.phase == .recording }
    var selectedModelReady: Bool { readyModel == preferences.model.id && !preparing }

    func start() {
        panel = RecordingPanelController(coordinator: self)
        KeyboardShortcuts.onKeyDown(for: .dictate) { [weak self] in self?.press() }
        KeyboardShortcuts.onKeyUp(for: .dictate) { [weak self] in self?.release() }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observations.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            })
        }
        observations.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.busy == true { self?.cancel() } }
        })
        observations.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        })
        observations.append(DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        })
        loadModel(download: false)
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--diagnostics-file"), args.indices.contains(index + 1) {
            let url = URL(fileURLWithPath: args[index + 1])
            diagnosticsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.writeDiagnostics(to: url) }
            }
        }
        // Explicit local troubleshooting action. macOS still owns the prompt
        // and requires the user to approve microphone access.
        if args.contains("--request-microphone") { requestMicrophone() }
    }
    func refreshPermissions() {
        let wasAllowed = microphoneAllowed && accessibilityAllowed
        let permissions = permissionSnapshot()
        microphoneAllowed = permissions.microphone
        accessibilityAllowed = permissions.accessibility
        let allowed = microphoneAllowed && accessibilityAllowed
        if wasAllowed != allowed, !busy, selectedModelReady {
            status = allowed ? "Ready · English" : "Allow \(microphoneAllowed ? "Accessibility" : "Microphone") in Settings"
        }
    }
    func requestAccessibility() {
        guard !accessibilityAllowed else { return }
        DeliveryService.requestPermission()
        pollPermissions()
    }
    private func pollPermissions() {
        permissionDeadline = Date().addingTimeInterval(180)
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.refreshPermissions()
                if (self.microphoneAllowed && self.accessibilityAllowed) || Date() > self.permissionDeadline {
                    timer.invalidate(); self.permissionTimer = nil
                }
            }
        }
    }
    func requestMicrophone() {
        guard !microphoneAllowed else { return }
        pollPermissions()
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            refreshPermissions()
            if !microphoneAllowed {
                status = "Enable dctt in Privacy & Security → Microphone, then refresh permissions"
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
    func refreshModelAvailability() {
        Task {
            var found: Set<String> = []
            for model in ModelDescriptor.catalog where await models.isPrepared(model) { found.insert(model.id) }
            localModels = found // File presence only; Use always verifies checksums.
        }
    }
    func loadModel(download: Bool, model selected: ModelDescriptor? = nil) {
        guard !busy, !preparing else { return }
        if let selected { preferences.modelID = selected.id }
        let model = preferences.model, operation = UUID()
        preparationID = operation
        preparing = true; cancellingPreparation = false; readyModel = nil; preparationError = ""
        preparationProgress = .init(stage: .checking)
        status = "Checking local model…"
        preparingTask = Task {
            let (stream, continuation) = AsyncStream<ModelPreparationProgress>.makeStream()
            let updates = Task { @MainActor in
                for await progress in stream {
                    guard preparationID == operation, !cancellingPreparation else { continue }
                    preparationProgress = progress
                    status = progress.stage.rawValue + "…"
                }
            }
            do {
                if download {
                    try await models.prepare(model) { continuation.yield($0) }
                } else { try await models.validate(model) }
                continuation.finish()
                await updates.value
                try Task.checkCancellation()
                preparationProgress = .init(stage: .loading)
                status = "Preparing model…"
                let start = Date()
                try await engine.load(model, from: models.folder(model))
                try Task.checkCancellation()
                readyModel = model.id
                localModels.insert(model.id)
                lastTimings = String(format: "Model load: %.2f s", Date().timeIntervalSince(start))
                refreshPermissions()
                status = microphoneAllowed && accessibilityAllowed ? "Ready · English" : "Model ready · finish permissions in Settings"
            } catch {
                continuation.finish()
                await updates.value
                if Task.isCancelled { status = "Model preparation cancelled" }
                else { preparationError = error.localizedDescription; status = preparationError }
            }
            guard preparationID == operation else { return }
            preparing = false; cancellingPreparation = false; preparationProgress = nil
            preparingTask = nil; preparationID = nil
            refreshModelAvailability()
            if !checkedInitialSetup {
                checkedInitialSetup = true
                if preferences.setupState == "unseen" {
                    if selectedModelReady && microphoneAllowed && accessibilityAllowed {
                        preferences.setupState = "dismissed"
                    } else { setupRequested = true }
                }
            }
        }
    }
    func cancelPreparation() {
        guard preparing else { return }
        cancellingPreparation = true
        status = "Cancelling preparation…"
        preparingTask?.cancel()
    }
    func dismissSetup(completed: Bool = false) {
        preferences.setupState = completed ? "completed" : "dismissed"
        setupRequested = false
    }
    func showSetup() { setupRequested = true; settingsPage = .general }
    func dismissPanel() {
        dismissal?.cancel()
        if let id = presentation.id, presentation.dismiss(id) { panel?.hide() }
    }
    func clearLatest() {
        guard !busy else { return }
        latest = ""
        dismissPanel()
    }
    func copyRecovery() {
        guard !presentation.recoveryText.isEmpty else { return }
        if DeliveryService.copy(presentation.recoveryText) { dismissPanel() }
        else if let id = presentation.id {
            presentation.update(id, phase: .recovery, message: "Could not copy. Try again.", text: presentation.recoveryText)
        }
    }

    func press() {
        pressCount += 1
        refreshPermissions()
        guard !busy, !preparing else { return }
        guard selectedModelReady else { status = "Prepare the selected model in Settings"; return }
        guard microphoneAllowed else { status = "Allow Microphone in Settings"; return }
        guard accessibilityAllowed else { status = "Allow Accessibility in Settings for cross-app paste"; return }
        guard !DeliveryService.secureInput else { status = "Secure input is active. Dictation is unavailable here."; return }
        guard let target = delivery.snapshot(), !target.secure else { status = "Focus a text field in another app first"; return }
        guard let id = gate.press() else { return }
        cancellationReason = nil
        destination = target
        options = SessionOptions(model: preferences.model, cleanup: preferences.cleanup,
            singleLine: preferences.singleLine, restoreClipboard: preferences.restoreClipboard,
            historyFolder: preferences.historyEnabled ? URL(fileURLWithPath: preferences.historyFolder) : nil)
        pressTime = Date(); busy = true; duration = 0; level = 0
        dismissal?.cancel()
        presentation.begin(id)
        status = "Starting microphone…"
        panel?.show()
        Task {
            do {
                try await recorder.start(startedAt: pressTime)
                // Continuity microphones can start slowly. Keep the UI in Starting
                // until real audio arrives, and honor release during that wait.
                while gate.accepts(id), gate.held, Date().timeIntervalSince(pressTime) < 3 {
                    if await recorder.status().firstBufferDelay != nil { break }
                    try? await AppDelay.sleep(milliseconds: 15)
                }
                if await recorder.status().firstBufferDelay == nil, gate.held {
                    _ = try? await recorder.stop()
                    finish(id, message: "No microphone audio arrived. Check the default input.")
                    return
                }
                guard gate.started(id) else {
                    _ = try? await recorder.stop()
                    finish(id, message: "Cancelled before recording", phase: .cancelled)
                    return
                }
                status = "Listening — release to transcribe"
                presentation.update(id, phase: .listening, message: "Listening")
                beginMonitoring(id)
            } catch { finish(id, message: error.localizedDescription) }
        }
    }
    private func beginMonitoring(_ id: UUID) {
        monitor = Task {
            while !Task.isCancelled && gate.id == id && gate.phase == .recording {
                let audio = await recorder.status()
                guard gate.id == id, gate.phase == .recording else { break }
                duration = audio.duration; level = audio.level
                if audio.error || !microphonePermissionStillAllowed {
                    cancel(reason: "Microphone became unavailable. Check the default input."); break
                }
                if audio.duration >= 120 || Date().timeIntervalSince(pressTime) >= 120 { release(); break }
                if audio.duration == 0 && Date().timeIntervalSince(pressTime) > 3 {
                    cancel(reason: "No microphone audio arrived. Check the default input."); break
                }
                try? await AppDelay.sleep(milliseconds: 60)
            }
        }
    }
    private var microphonePermissionStillAllowed: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    func release() {
        releaseCount += 1
        gate.release()
        guard let id = gate.id, gate.phase == .recording, let target = destination, let options else { return }
        guard gate.transcribe(id) else { return }
        monitor?.cancel(); monitor = nil
        status = "Transcribing locally…"
        presentation.update(id, phase: .transcribing, message: "Transcribing locally")
        let released = Date()
        Task {
            do {
                let metrics = await recorder.status()
                let samples = try await recorder.stop()
                guard gate.accepts(id) else { finish(id, message: "Cancelled", phase: .cancelled); return }
                guard AudioPolicy.hasSignal(samples) else { finish(id, message: "No speech captured — try a longer or clearer utterance"); return }
                let result = try await engine.transcribe(samples)
                guard gate.finalize(id) else { finish(id, message: "Cancelled", phase: .cancelled); return }
                let text = TextPolicy.apply(result.text, cleanup: options.cleanup, terminal: target.terminal, singleLine: options.singleLine)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { finish(id, message: "No speech recognized"); return }
                latest = text
                status = "Waiting to paste…"
                presentation.update(id, phase: .waiting, message: DeliveryService.physicalModifiersDown ? "Waiting for shortcut release" : "Requesting paste")
                guard gate.claimCommit(id) else { finish(id, message: "Cancelled", phase: .cancelled); return }
                let outcome = await delivery.paste(text, to: target, restoreClipboard: options.restoreClipboard) { self.gate.accepts(id) }
                if outcome == .pasteRequested { pasteRequestCount += 1 }
                guard gate.accepts(id) else {
                    finish(id, message: outcome == .pasteRequested ? "Paste requested" : "Cancelled · Copy text available",
                           phase: outcome == .pasteRequested ? .pasteRequested : .recovery, text: text)
                    return
                }
                lastTimings = String(format: "First audio: %.0f ms · Recognition: %.2f s · Release to outcome: %.2f s",
                    (metrics.firstBufferDelay ?? 0) * 1000, result.seconds, Date().timeIntervalSince(released))
                if let folder = options.historyFolder {
                    let record = HistoryRecord(id: id, text: text, model: options.model,
                        detectedLanguage: result.detectedLanguage, audioSeconds: Double(samples.count) / 16000,
                        transcriptionSeconds: result.seconds, cleanup: options.cleanup,
                        targetAppName: target.name, targetBundleID: target.bundleID, deliveryStatus: outcome)
                    do { try await history.append(record, folder: folder) }
                    catch { historyNotice = "History could not be saved: \(error.localizedDescription) Latest text is still available to Copy." }
                }
                let message: String
                if outcome == .pasteRequested { message = "Paste requested" }
                else if delivery.lastBlockReason == .fieldIdentityUnavailable {
                    message = "Text field unavailable — Copy text"
                } else if outcome == .targetChanged { message = "Destination changed — Copy text" }
                else if outcome == .permissionDenied { message = "Accessibility needed — Copy text" }
                else { message = "Paste unavailable — Copy text" }
                finish(id, message: message, phase: outcome == .pasteRequested ? .pasteRequested : .recovery, text: text)
            } catch { finish(id, message: error.localizedDescription) }
        }
    }
    func cancel(reason: String? = nil) {
        guard let id = gate.id else { return }
        if let reason { cancellationReason = reason }
        let wasRecording = gate.phase == .recording
        gate.cancel(); monitor?.cancel(); monitor = nil
        status = "Cancelling…"
        presentation.update(id, phase: .cancelling, message: "Cancelling")
        if wasRecording {
            Task { _ = try? await recorder.stop(); finish(id, message: "Cancelled") }
        }
        // Startup and inference drain in their owning tasks before returning to ready.
    }
    private func finish(_ id: UUID, message: String, phase: SessionPresentation.Phase = .failure, text: String = "") {
        guard gate.id == id else { return }
        let resultPhase: SessionPresentation.Phase = phase == .pasteRequested ? .pasteRequested : cancellationReason != nil ? .failure :
            (gate.phase == .cancelling && phase == .failure ? .cancelled : phase)
        let message = phase == .pasteRequested ? message : cancellationReason ?? message
        cancellationReason = nil
        gate.finish(id); busy = false; destination = nil; options = nil
        status = message; level = 0
        presentation.update(id, phase: resultPhase, message: message, text: text)
        if resultPhase == .pasteRequested || resultPhase == .cancelled {
            dismissal = Task {
                do { try await AppDelay.sleep(milliseconds: 2_000) } catch { return }
                if presentation.dismiss(id) { panel?.hide() }
            }
        }
    }
    func quit() {
        cancel(); preparingTask?.cancel()
        Task { _ = try? await recorder.stop(); NSApplication.shared.terminate(nil) }
    }
    func refreshHistory() {
        let folder = URL(fileURLWithPath: preferences.historyFolder), request = UUID()
        historyRequestID = request
        Task {
            do {
                let records = try await history.recent(folder: folder)
                guard folder.path == preferences.historyFolder, historyRequestID == request else { return }
                recentHistory = records
                historyNotice = ""
            } catch {
                guard folder.path == preferences.historyFolder, historyRequestID == request else { return }
                historyNotice = error.localizedDescription
            }
        }
    }
    func chooseHistoryFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.preferences.historyFolder = url.path
            self.recentHistory = []
            self.refreshHistory()
        }
    }
    func deleteHistory(_ id: UUID? = nil) {
        let folder = URL(fileURLWithPath: preferences.historyFolder)
        Task {
            do {
                if let id { try await history.delete(id: id, folder: folder) }
                else { try await history.deleteAll(folder: folder) }
                if folder.path == preferences.historyFolder { refreshHistory() }
            } catch { if folder.path == preferences.historyFolder { historyNotice = error.localizedDescription } }
        }
    }
    func exportHistory(_ record: HistoryRecord) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "dctt-transcript.txt"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task { @MainActor in
                do { try await self.history.export(record, to: url) }
                catch { self.historyNotice = "Export failed: \(error.localizedDescription)" }
            }
        }
    }
    private func writeDiagnostics(to url: URL) {
        let microphoneStatus: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphoneStatus = "authorized"
        case .notDetermined: microphoneStatus = "not_requested"
        case .denied: microphoneStatus = "denied"
        case .restricted: microphoneStatus = "restricted"
        @unknown default: microphoneStatus = "unknown"
        }
        let data: [String: Any] = ["microphone_authorized": AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            "microphone_status": microphoneStatus,
            "accessibility_authorized": DeliveryService.trusted, "secure_input": DeliveryService.secureInput,
            "model_ready": readyModel ?? "", "busy": busy, "preparing": preparing,
            "phase": String(describing: gate.phase), "captured_seconds": duration,
            "level": level, "shortcut_down_count": pressCount, "shortcut_up_count": releaseCount,
            "paste_request_count": pasteRequestCount, "latest_available": !latest.isEmpty,
            "paste_block_reason": delivery.lastBlockReason?.rawValue ?? "",
            "timings": lastTimings]
        if let bytes = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]) {
            try? bytes.write(to: url, options: .atomic)
        }
    }
}
