import AppKit
import SwiftUI
import DcttCore

/// Developer-only rendering fixtures. This checks UI, not recognition or OS grants.
/// Uses an isolated defaults domain and synthetic text; never loads user history.
@MainActor enum UISmoke {
    static func run(directory: URL) async {
        let suite = "com.tobilg.dctt.ui-check.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        var allowed = true
        let coordinator = Coordinator(preferences: preferences, permissionSnapshot: { (allowed, allowed) })
        var report: [String: Any] = ["synthetic_ui_only": true]
        do {
            NSApp.activate(ignoringOtherApps: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            coordinator.readyModel = preferences.model.id
            coordinator.microphoneAllowed = true; coordinator.accessibilityAllowed = true
            coordinator.status = "Ready · English"
            coordinator.localModels = Set(ModelDescriptor.catalog.map(\.id))
            for page in SettingsPage.allCases {
                coordinator.settingsPage = page
                try await render(SettingsView(coordinator: coordinator, preferences: preferences), name: "settings-\(page.id)",
                                 size: NSSize(width: 820, height: 640), directory: directory)
            }
            allowed = false
            coordinator.settingsPage = .general; coordinator.setupRequested = true
            coordinator.microphoneAllowed = false; coordinator.accessibilityAllowed = false; coordinator.readyModel = nil
            try await render(SettingsView(coordinator: coordinator, preferences: preferences), name: "setup",
                             size: NSSize(width: 700, height: 520), directory: directory)
            allowed = true
            coordinator.setupRequested = false
            coordinator.microphoneAllowed = true; coordinator.accessibilityAllowed = true
            coordinator.readyModel = preferences.model.id; coordinator.status = "Ready · English"
            coordinator.latest = "This is a synthetic interface example."
            coordinator.settingsPage = .models; coordinator.preparing = true
            coordinator.preparationProgress = .init(stage: .downloading, completedFiles: 2, totalFiles: 21, receivedBytes: 120_000_000, totalBytes: 464_000_000)
            try await render(SettingsView(coordinator: coordinator, preferences: preferences), name: "download",
                             size: NSSize(width: 820, height: 640), directory: directory)
            coordinator.preparing = false; coordinator.preparationProgress = nil
            preferences.historyFolder = directory.appendingPathComponent("synthetic-history").path
            preferences.historyEnabled = true
            let record = HistoryRecord(text: coordinator.latest, model: preferences.model, audioSeconds: 3,
                transcriptionSeconds: 0.2, cleanup: true, targetAppName: "TextEdit", deliveryStatus: .pasteRequested)
            try await coordinator.history.append(record, folder: URL(fileURLWithPath: preferences.historyFolder))
            try await render(HistoryView(coordinator: coordinator, preferences: preferences), name: "history",
                             size: NSSize(width: 860, height: 600), directory: directory)
            try await render(MenuView(coordinator: coordinator, preferences: preferences), name: "menu",
                             size: NSSize(width: 340, height: 460), directory: directory)
            let id = UUID()
            coordinator.presentation.begin(id)
            coordinator.duration = 12; coordinator.level = 0.6
            for phase in [SessionPresentation.Phase.starting, .listening, .transcribing, .waiting, .pasteRequested, .recovery] {
                coordinator.presentation.update(id, phase: phase, message: title(phase), text: coordinator.latest)
                try await render(RecordingView(coordinator: coordinator), name: "panel-\(phase)",
                                 size: NSSize(width: 420, height: 124), directory: directory)
            }
            try await render(RecordingView(coordinator: coordinator).environment(\.colorScheme, .dark), name: "panel-dark",
                             size: NSSize(width: 420, height: 124), directory: directory)
            // A native non-activating panel must not become the key window.
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.makeKeyAndOrderFront(nil)
            let panel = RecordingPanelController(coordinator: coordinator)
            let before = NSWorkspace.shared.frontmostApplication?.processIdentifier
            panel.show()
            try await AppDelay.sleep(milliseconds: 150)
            report["panel_cannot_become_key"] = !panel.panel.canBecomeKey && !panel.panel.canBecomeMain
            report["panel_preserved_key_window"] = NSApp.keyWindow === window
            report["panel_preserved_frontmost_app"] = before == NSWorkspace.shared.frontmostApplication?.processIdentifier
            panel.hide(); window.close()
            report["fixtures_created"] = true
            report["cached_images_are_partial"] = true
        } catch { report["error"] = error.localizedDescription }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("result.json"), options: .atomic)
        }
        defaults.removePersistentDomain(forName: suite)
        NSApp.terminate(nil)
    }
    private static func title(_ phase: SessionPresentation.Phase) -> String {
        switch phase {
        case .starting: "Starting microphone"
        case .listening: "Listening"
        case .transcribing: "Transcribing locally"
        case .waiting: "Waiting for shortcut release"
        case .pasteRequested: "Paste requested"
        case .recovery: "Destination changed — Copy text"
        default: "Cancelled"
        }
    }
    private static func render<V: View>(_ view: V, name: String, size: NSSize, directory: URL) async throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = host
        window.center(); window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await AppDelay.sleep(milliseconds: 350)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw DcttError.message("UI fixture did not render.") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw DcttError.message("UI fixture could not be captured.") }
        try png.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
    }
}
