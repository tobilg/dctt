import AppKit
import SwiftUI
import KeyboardShortcuts
import DcttCore

enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "General", models = "Models", privacy = "Privacy & History", advanced = "Advanced"
    var id: Self { self }
    var symbol: String {
        switch self { case .general: "slider.horizontal.3"; case .models: "waveform"; case .privacy: "hand.raised"; case .advanced: "gearshape.2" }
    }
}

struct SettingsView: View {
    @ObservedObject var coordinator: Coordinator
    @ObservedObject var preferences: Preferences
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: $coordinator.settingsPage) { page in
                Label(page.rawValue, systemImage: page.symbol).tag(page)
            }.navigationSplitViewColumnWidth(min: 175, ideal: 190, max: 230)
        } detail: {
            Form {
                switch coordinator.settingsPage {
                case .general: general
                case .models: models
                case .privacy: privacy
                case .advanced: advanced
                }
            }.formStyle(.grouped).navigationTitle(coordinator.settingsPage.rawValue)
        }.frame(minWidth: 700, minHeight: 520)
            .onAppear { coordinator.refreshPermissions(); coordinator.refreshModelAvailability() }
    }
    @ViewBuilder private var general: some View {
        Section {
            Label(coordinator.busy ? "Dictation in progress" : coordinator.selectedModelReady && coordinator.microphoneAllowed && coordinator.accessibilityAllowed ? "Ready to dictate" : "Finish setting up dctt", systemImage: "mic")
                .font(.headline)
            Text(coordinator.status).foregroundStyle(.secondary)
            if !coordinator.setupRequested { Button("Open setup checklist") { coordinator.showSetup() } }
        }
        if coordinator.setupRequested {
            Section("Setup") { SetupChecklist(coordinator: coordinator, preferences: preferences) }
        }
        Section("Hold to talk") {
            KeyboardShortcuts.Recorder("Shortcut", name: .dictate, onChange: { _ in coordinator.objectWillChange.send() })
                .shortcutValidation { shortcut in
                    shortcut.modifiers.intersection([.command, .control, .option]).isEmpty
                        ? .disallow(reason: "Include Control, Option, or Command with a key.") : .allow
                }.disabled(coordinator.busy)
            Text("Hold, speak, then release all keys. Recording stops after two minutes.")
                .font(.callout).foregroundStyle(.secondary)
        }
        Section("Text") {
            Toggle("Basic cleanup", isOn: $preferences.cleanup)
            Text("Trim edges and normalize line endings. Wording and punctuation stay unchanged.").font(.caption).foregroundStyle(.secondary)
            Toggle("Single-line output in every app", isOn: $preferences.singleLine)
            Text("Terminal and iTerm2 always receive a single line with control characters removed. dctt never presses Enter.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private var models: some View {
        Section {
            Text("Recognition stays on your Mac").font(.headline)
            Text("English · one model kept ready · downloads only when you request them")
                .font(.callout).foregroundStyle(.secondary)
        }
        ForEach(ModelDescriptor.catalog.sorted { $0.id == "parakeet-v2" && $1.id != "parakeet-v2" }) { model in
            Section { ModelCard(coordinator: coordinator, model: model) }
        }
        Section {
            Text("Download prepares and activates the model. Allow additional space for temporary downloads and Core ML caches.")
                .font(.caption).foregroundStyle(.secondary)
            FolderLocation(url: AppPaths.models)
        }
    }
    @ViewBuilder private var privacy: some View {
        Section("Permissions") { PermissionRows(coordinator: coordinator) }
        Section("Transcript history") {
            Toggle("Save completed transcripts", isOn: $preferences.historyEnabled).disabled(coordinator.busy)
            Text("Off by default. Saves text and minimal time, model and app metadata. Audio is never saved.")
                .font(.caption).foregroundStyle(.secondary)
            FolderLocation(url: URL(fileURLWithPath: preferences.historyFolder))
            HStack {
                Button("Choose folder…") { coordinator.chooseHistoryFolder() }.disabled(coordinator.busy)
                Button("Open history") { openWindow(id: "history") }
            }
            Text("Changing folders leaves existing files where they are. Your chosen folder may sync through its provider.")
                .font(.caption).foregroundStyle(.secondary)
            if !coordinator.historyNotice.isEmpty { Label(coordinator.historyNotice, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
        }
        Section("Local by default") {
            Text("Prepared recognition works offline. The latest transcript stays in memory until cleared or the app quits. Clipboard managers may retain text you copy or paste.")
                .foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private var advanced: some View {
        Section("Clipboard") {
            Toggle("Restore clipboard after one second", isOn: $preferences.restoreClipboard)
            Text("Off by default. Slow apps may read the clipboard after restoration. Newer clipboard changes are preserved; snapshots over 8 MB are not restored.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Performance") {
            Text(coordinator.lastTimings.isEmpty ? "Timing appears after a model loads or a dictation completes." : coordinator.lastTimings)
                .font(.callout).monospacedDigit().textSelection(.enabled)
        }
        Section("Troubleshooting") {
            Button("Refresh permissions") { coordinator.refreshPermissions() }
            Button("Open setup checklist") { coordinator.showSetup() }
            Text("After a locally signed rebuild, macOS may require granting access again. If Accessibility stays unavailable, remove the old dctt entry in System Settings and add the installed app again.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct PermissionRows: View {
    @ObservedObject var coordinator: Coordinator
    var body: some View {
        PermissionRow(title: "Microphone", detail: "Record while you hold the shortcut", symbol: "mic", allowed: coordinator.microphoneAllowed, action: coordinator.requestMicrophone)
        PermissionRow(title: "Accessibility", detail: "Request a paste into your focused app", symbol: "keyboard", allowed: coordinator.accessibilityAllowed, action: coordinator.requestAccessibility)
    }
}
private struct PermissionRow: View {
    let title: String, detail: String, symbol: String
    let allowed: Bool
    let action: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 22).foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: action) {
                Label(allowed ? "Allowed" : "Allow \(title)", systemImage: allowed ? "checkmark" : "arrow.up.forward")
            }.disabled(allowed).accessibilityLabel("\(title): \(allowed ? "Allowed" : "Allow access")")
        }.padding(.vertical, 3)
    }
}

struct SetupChecklist: View {
    @ObservedObject var coordinator: Coordinator
    @ObservedObject var preferences: Preferences
    private var ready: Bool { coordinator.microphoneAllowed && coordinator.accessibilityAllowed && coordinator.selectedModelReady }
    var body: some View {
        PermissionRows(coordinator: coordinator)
        HStack {
            Label("Local model", systemImage: "waveform")
            Spacer()
            Button(coordinator.selectedModelReady ? "Ready" : "Choose and prepare…") { coordinator.settingsPage = .models }
                .disabled(coordinator.selectedModelReady)
        }
        VStack(alignment: .leading, spacing: 8) {
            Label("Try dictation", systemImage: "text.cursor")
            Text("Open an empty TextEdit document. Hold \(KeyboardShortcuts.getShortcut(for: .dictate)?.description ?? "your shortcut"), say a short phrase, then release all keys. Check that the text appears once.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Select a working input in System Settings → Sound. An iPhone microphone can be used when it appears there.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Text appeared once") { coordinator.dismissSetup(completed: true) }.disabled(!ready)
                Spacer()
                Button("Set up later") { coordinator.dismissSetup() }
            }
        }.padding(.vertical, 4)
    }
}

struct ModelCard: View {
    @ObservedObject var coordinator: Coordinator
    let model: ModelDescriptor
    private var selected: Bool { coordinator.preferences.modelID == model.id }
    private var working: Bool { selected && coordinator.preparing }
    private var active: Bool { coordinator.readyModel == model.id && !coordinator.preparing }
    private var onDisk: Bool { coordinator.localModels.contains(model.id) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Image(systemName: "waveform").font(.title2).foregroundStyle(.tint).padding(8)
                    .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.name).font(.headline)
                    Text("English · \(ByteCountFormatter.string(fromByteCount: model.size, countStyle: .file)) download")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.id == "parakeet-v2" { Text("Recommended default").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if active { Label("Active", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.secondary) }
            }
            if working {
                if let progress = coordinator.preparationProgress {
                    HStack {
                        Text(coordinator.cancellingPreparation ? "Cancelling…" : progress.stage.rawValue).font(.callout)
                        Spacer()
                        Button("Cancel") { coordinator.cancelPreparation() }.disabled(coordinator.cancellingPreparation)
                    }
                    if let fraction = progress.fraction {
                        ProgressView(value: fraction)
                        Text("\(ByteCountFormatter.string(fromByteCount: progress.receivedBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file))")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    } else { ProgressView().controlSize(.small).accessibilityLabel(progress.stage.rawValue) }
                }
            } else {
                if selected && !coordinator.preparationError.isEmpty {
                    Label(coordinator.preparationError, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    if active { Button("Active") {}.disabled(true) }
                    else {
                        Button(onDisk ? "Use model" : "Download") { coordinator.loadModel(download: !onDisk, model: model) }
                            .buttonStyle(.borderedProminent)
                    }
                    if onDisk || (selected && !coordinator.preparationError.isEmpty) {
                        Button(onDisk ? "Repair" : "Retry download") { coordinator.loadModel(download: true, model: model) }
                    }
                    Spacer()
                    Text(active ? "On-device recognition" : onDisk ? "On disk · verified when used" : "Not downloaded")
                        .font(.caption).foregroundStyle(.secondary)
                }.disabled(coordinator.busy || coordinator.preparing)
            }
        }.padding(.vertical, 6)
    }
}

struct FolderLocation: View {
    let url: URL
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(url.lastPathComponent, systemImage: "folder")
                Spacer()
                Button("Reveal") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path) }
            }
            DisclosureGroup("Folder location") { Text(url.path).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        }
    }
}
