import AppKit
import SwiftUI
import DcttCore

private final class RecordingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor final class RecordingPanelController {
    let panel: NSPanel
    init(coordinator: Coordinator) {
        panel = RecordingPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 124),
            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // The native glass surface supplies its own shadow.
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: RecordingView(coordinator: coordinator))
    }
    func show() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: max(frame.minX, frame.midX - panel.frame.width / 2), y: frame.minY + 36))
        }
        panel.orderFrontRegardless()
    }
    func hide() { panel.orderOut(nil) }
}

struct RecordingView: View {
    @ObservedObject var coordinator: Coordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    private var phase: SessionPresentation.Phase { coordinator.presentation.phase }
    private var terminal: Bool { [.recovery, .failure, .pasteRequested, .cancelled].contains(phase) }
    private var symbol: String {
        switch phase {
        case .starting, .listening: "mic.fill"
        case .transcribing: "waveform"
        case .waiting, .pasteRequested: "paperplane"
        case .recovery, .failure: "exclamationmark.bubble"
        case .cancelled, .cancelling: "xmark"
        case .hidden: "mic"
        }
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.title3).frame(width: 24)
                    .foregroundStyle(phase == .listening ? Color.red : Color.primary).accessibilityHidden(true)
                Text(coordinator.presentation.message).font(.callout.weight(.medium)).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !terminal {
                    Button("Cancel", systemImage: "xmark") { coordinator.cancel() }.labelStyle(.iconOnly)
                        .buttonStyle(.borderless).help("Cancel dictation")
                } else {
                    Button("Dismiss", systemImage: "xmark") { coordinator.dismissPanel() }.labelStyle(.iconOnly)
                        .buttonStyle(.borderless).help("Dismiss")
                }
            }
            if phase == .listening {
                HStack(spacing: 12) {
                    AudioLevelMeter(level: Double(coordinator.level))
                    Text(Duration.seconds(coordinator.duration).formatted(.time(pattern: .minuteSecond)))
                        .monospacedDigit().font(.caption).foregroundStyle(.secondary)
                }
            } else if phase == .recovery, !coordinator.presentation.recoveryText.isEmpty {
                Button("Copy text", systemImage: "doc.on.doc") { coordinator.copyRecovery() }
                    .buttonStyle(.bordered)
            } else if !terminal {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text(phase == .starting ? "Waiting for microphone audio" : phase == .cancelling ? "Finishing safely" : "On your Mac")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if phase == .pasteRequested {
                Text("Copy latest remains available in the menu").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 18).padding(.vertical, 14)
    }
    var body: some View {
        Group {
            if reduceTransparency || contrast == .increased {
                content.background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 26))
                    .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(.primary.opacity(0.25)))
            } else { content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26)) }
        }.animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: phase)
            .padding(10).frame(width: 420, height: 124)
            .accessibilityElement(children: .contain)
    }
}

private struct AudioLevelMeter: View {
    let level: Double
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 3) {
                ForEach(0..<24, id: \.self) { index in
                    Capsule().fill(Double(index) / 24 < min(1, max(0, level)) ? Color.red : Color.primary.opacity(0.12))
                        .frame(width: max(1, (geometry.size.width - 69) / 24), height: 8)
                }
            }
        }.frame(height: 8).accessibilityLabel("Microphone level")
            .accessibilityValue("\(Int(min(1, max(0, level)) * 100)) percent")
    }
}
