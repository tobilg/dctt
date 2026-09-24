import AppKit
import SwiftUI
import DcttCore

struct HistoryView: View {
    @ObservedObject var coordinator: Coordinator
    @ObservedObject var preferences: Preferences
    @State private var query = ""
    @State private var selection: UUID?
    @State private var confirmDeleteAll = false
    @State private var deleteAllFolder: String?
    private var records: [HistoryRecord] { HistorySearch.filter(coordinator.recentHistory, query: query) }
    private var selected: HistoryRecord? { records.first { $0.id == selection } }
    private var groups: [(date: Date, records: [HistoryRecord])] {
        Dictionary(grouping: records) { Calendar.current.startOfDay(for: $0.timestampUTC) }
            .map { (date: $0.key, records: $0.value) }.sorted { $0.date > $1.date }
    }
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                if !preferences.historyEnabled {
                    Label("Saving history is off", systemImage: "pause.circle").font(.caption).foregroundStyle(.secondary).padding(10)
                }
                if coordinator.recentHistory.isEmpty {
                    ContentUnavailableView(preferences.historyEnabled ? "No saved transcripts" : "History is off",
                        systemImage: "text.bubble", description: Text(preferences.historyEnabled ? "Completed dictations will appear here." : "Enable saving in Settings → Privacy & History."))
                } else if records.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List(selection: $selection) {
                        ForEach(groups, id: \.date) { group in
                            Section(dayLabel(group.date)) {
                                ForEach(group.records) { record in
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(record.text).lineLimit(2)
                                        Text("\(record.targetAppName ?? "Unknown app") · \(record.timestampUTC.formatted(date: .omitted, time: .shortened))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }.padding(.vertical, 4).tag(record.id)
                                }
                            }
                        }
                    }
                }
                Text("Search up to 200 recent records").font(.caption).foregroundStyle(.secondary).padding(10)
            }.frame(minWidth: 260)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 400)
                .searchable(text: $query, prompt: "Search recent transcripts")
        } detail: {
            VStack(alignment: .leading, spacing: 16) {
                if !coordinator.historyNotice.isEmpty {
                    Label(coordinator.historyNotice, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary)
                }
                if let record = selected {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(record.timestampUTC.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                        Text(record.targetAppName ?? "Unknown app").foregroundStyle(.secondary)
                        Label(record.deliveryStatus.label, systemImage: record.deliveryStatus == .pasteRequested ? "paperplane" : "doc.on.doc")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Divider()
                    ScrollView { Text(record.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    HStack {
                        Button("Copy", systemImage: "doc.on.doc") { DeliveryService.copy(record.text) }
                        Button("Export…", systemImage: "square.and.arrow.up") { coordinator.exportHistory(record) }
                        Spacer()
                        Button("Delete", role: .destructive) { coordinator.deleteHistory(record.id) }.disabled(coordinator.busy)
                    }
                } else {
                    ContentUnavailableView("Select a transcript", systemImage: "text.alignleft",
                        description: Text("View, copy or export a saved dictation."))
                }
            }.padding(24).navigationTitle("History")
        }.frame(minWidth: 720, minHeight: 480)
            .toolbar {
                ToolbarItemGroup {
                    Button("Refresh", systemImage: "arrow.clockwise") { coordinator.refreshHistory() }
                    Button("Reveal folder", systemImage: "folder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: preferences.historyFolder) }
                    Button("Delete all…", systemImage: "trash", role: .destructive) { deleteAllFolder = preferences.historyFolder; confirmDeleteAll = true }
                        .disabled(coordinator.recentHistory.isEmpty || coordinator.busy)
                }
            }
            .onAppear { coordinator.refreshHistory() }
            .onChange(of: preferences.historyFolder) { _, _ in selection = nil; query = ""; confirmDeleteAll = false; deleteAllFolder = nil; coordinator.refreshHistory() }
            .onChange(of: records.map(\.id)) { _, ids in if selection == nil || !ids.contains(selection!) { selection = ids.first } }
            .confirmationDialog("Delete dctt’s saved history in this folder? Other files and history in previous folders remain.", isPresented: $confirmDeleteAll) {
                Button("Delete saved history", role: .destructive) {
                    guard deleteAllFolder == preferences.historyFolder else { return }
                    coordinator.deleteHistory(); selection = nil
                }
            }
    }
    private func dayLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
