import AppKit
import SwiftUI
import DcttCore

@main struct DcttApp: App {
    @StateObject private var coordinator = Coordinator()
    @Environment(\.openWindow) private var openWindow
    var body: some Scene {
        MenuBarExtra("dctt", systemImage: coordinator.recording ? "mic.fill" : "mic") {
            MenuView(coordinator: coordinator, preferences: coordinator.preferences)
        }.menuBarExtraStyle(.window)
            .onChange(of: coordinator.setupRequested) { _, requested in
                if requested { openWindow(id: "settings"); NSApp.activate(ignoringOtherApps: true) }
            }

        Window("dctt Settings", id: "settings") {
            SettingsView(coordinator: coordinator, preferences: coordinator.preferences)
        }.defaultSize(width: 820, height: 640).windowResizability(.contentMinSize).defaultPosition(.center).defaultLaunchBehavior(.suppressed)
        .commands { CommandGroup(replacing: .newItem) {} }
        Window("dctt History", id: "history") {
            HistoryView(coordinator: coordinator, preferences: coordinator.preferences)
        }.defaultSize(width: 860, height: 600).windowResizability(.contentMinSize).defaultPosition(.center).defaultLaunchBehavior(.suppressed)
    }
    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let coordinator = Coordinator()
        _coordinator = StateObject(wrappedValue: coordinator)
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--ui-smoke"), args.indices.contains(index + 1) {
            Task { @MainActor in await UISmoke.run(directory: URL(fileURLWithPath: args[index + 1])) }
            return
        }
        if let index = args.firstIndex(of: "--wait-runtime-check"), args.indices.contains(index + 1) {
            Task { @MainActor in
                await NativeSmoke.checkWaitRuntime(report: URL(fileURLWithPath: args[index + 1]))
            }
            return
        }
        if let index = args.firstIndex(of: "--native-smoke"), args.indices.contains(index + 3) {
            Task { @MainActor in
                await NativeSmoke.run(target: args[index + 1], fixture: URL(fileURLWithPath: args[index + 2]),
                                      report: URL(fileURLWithPath: args[index + 3]))
            }
            return
        }
        Task { @MainActor in coordinator.start() }
    }
}
