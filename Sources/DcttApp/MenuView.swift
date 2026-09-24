import SwiftUI
import AppKit
import KeyboardShortcuts
import DcttCore

struct MenuView: View {
    @ObservedObject var coordinator: Coordinator
    @ObservedObject var preferences: Preferences
    @Environment(\.openWindow) private var openWindow
    @State private var showLatest = false
    private var ready: Bool { coordinator.selectedModelReady && coordinator.microphoneAllowed && coordinator.accessibilityAllowed }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: coordinator.recording ? "mic.fill" : "mic").font(.title2)
                    .foregroundStyle(coordinator.presentation.phase == .listening ? Color.red : Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(coordinator.busy ? "Dictating locally" : coordinator.preparing ? "Preparing model" : ready ? "Ready to dictate" : "Setup needed").font(.headline)
                    Text(preferences.model.name).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Text(coordinator.status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Hold to talk").foregroundStyle(.secondary)
                Spacer()
                Text(KeyboardShortcuts.getShortcut(for: .dictate)?.description ?? "Set shortcut")
                    .font(.body.monospaced()).padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
            if coordinator.busy {
                HStack {
                    if coordinator.recording { Button("Stop and transcribe") { coordinator.release() } }
                    Button("Cancel") { coordinator.cancel() }
                }
            } else if !ready { Button("Finish setup…") { coordinator.showSetup(); showWindow("settings") } }
            Divider()
            HStack {
                Button("Copy latest", systemImage: "doc.on.doc") { DeliveryService.copy(coordinator.latest) }
                    .disabled(coordinator.latest.isEmpty)
                Spacer()
                Button("Clear") { coordinator.clearLatest(); showLatest = false }.disabled(coordinator.latest.isEmpty || coordinator.busy)
            }
            if !coordinator.latest.isEmpty {
                DisclosureGroup("Show latest transcript", isExpanded: $showLatest) {
                    ScrollView { Text(coordinator.latest).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 140).padding(.top, 6)
                }.font(.callout)
            }
            if !coordinator.historyNotice.isEmpty { Label("History needs attention", systemImage: "exclamationmark.triangle").font(.caption) }
            Divider()
            HStack {
                Button("Settings…", systemImage: "gearshape") { showWindow("settings") }
                Button("History", systemImage: "clock") { showWindow("history") }
                Spacer()
                Button("Quit") { coordinator.quit() }
            }.buttonStyle(.borderless)
        }.padding(20).frame(width: 340)
            .onAppear { coordinator.refreshPermissions(); showLatest = false }
            .onDisappear { showLatest = false }
    }
    private func showWindow(_ id: String) { openWindow(id: id); NSApp.activate(ignoringOtherApps: true) }
}
