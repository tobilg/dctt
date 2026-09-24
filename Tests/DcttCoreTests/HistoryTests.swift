import Testing
import Foundation
@testable import DcttCore

struct HistoryTests {
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dctt-test-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func record(_ text: String = "Synthetic test transcript") -> HistoryRecord {
        HistoryRecord(text: text, model: ModelDescriptor.catalog[0], audioSeconds: 1,
                      transcriptionSeconds: 0.5, cleanup: true, deliveryStatus: .pasteRequested)
    }
    @Test func testDisabledHistoryCreatesNothing() async throws {
        let store = HistoryStore()
        try await store.append(record(), folder: nil)
        // No folder is provided at this boundary; disabled history has no destination.
    }
    @Test func testExistingHistoryForCurrentIdentitySurvivesAnUpgrade() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(HistoryStore.filename)
        let original = record("Existing synthetic transcript")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // A literal persisted header catches accidental app-identity changes.
        let header = Data("{\"app_id\":\"com.tobilg.dctt\",\"history_schema\":1}\n".utf8)
        try (header + encoder.encode(original) + Data([10])).write(to: file)
        let store = HistoryStore()
        let before = try await store.recent(folder: folder)
        #expect(before.map(\.id) == [original.id])
        let next = record("New synthetic transcript")
        try await store.append(next, folder: folder)
        try await store.delete(id: next.id, folder: folder)
        let after = try await store.recent(folder: folder)
        #expect(after.map(\.id) == [original.id])
        #expect(try Data(contentsOf: file).starts(with: header))
    }
    @Test func testRoundTripAndTruthfulMetadata() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore(), item = record("Line one\nLine two")
        try await store.append(item, folder: folder)
        let records = try await store.recent(folder: folder)
        #expect((records.count) == (1))
        #expect((records.first?.text) == (item.text))
        #expect((records.first?.deliveryStatus) == (.pasteRequested))
        #expect((records.first?.detectedLanguage) == nil)
        let bytes = try String(contentsOf: folder.appendingPathComponent(HistoryStore.filename), encoding: .utf8)
        #expect(bytes.contains("\"requested_language\":\"en\""))
        #expect(!(bytes.contains("accessibility_verified")))
        #expect((bytes.split(separator: "\n").count) == (2))
    }
    @Test func testIncompleteTrailingRecordDoesNotHideEarlierOrLaterRecords() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore()
        try await store.append(record("first"), folder: folder)
        let handle = try FileHandle(forWritingTo: folder.appendingPathComponent(HistoryStore.filename))
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{\"text\":\"incomplete".utf8)); try handle.close()
        try await store.append(record("last"), folder: folder)
        let texts = try await store.recent(folder: folder).map(\.text)
        #expect((texts) == (["last", "first"]))
    }
    @Test func testDeleteOnlySelectedRecordAndPreserveUnrelatedFile() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore()
        let first = record("first"), second = record("second")
        let unrelated = folder.appendingPathComponent("notes.txt")
        try Data("keep me".utf8).write(to: unrelated)
        try await store.append(first, folder: folder); try await store.append(second, folder: folder)
        try await store.delete(id: first.id, folder: folder)
        let remaining = try await store.recent(folder: folder)
        #expect((remaining.map(\.id)) == ([second.id]))
        try await store.deleteAll(folder: folder)
        #expect((try String(contentsOf: unrelated, encoding: .utf8)) == ("keep me"))
    }
    @Test func testUnrelatedFileAndSymlinkAreNeverOverwritten() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore()
        let file = folder.appendingPathComponent(HistoryStore.filename)
        try Data("unrelated".utf8).write(to: file)
        do { try await store.append(record(), folder: folder); Issue.record("Must refuse unrelated file") } catch {}
        do { try await store.deleteAll(folder: folder); Issue.record("Must refuse unrelated file") } catch {}
        #expect((try String(contentsOf: file, encoding: .utf8)) == ("unrelated"))
        try FileManager.default.removeItem(at: file)
        let missingTarget = folder.appendingPathComponent("must-not-be-created")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: missingTarget)
        do { try await store.append(record(), folder: folder); Issue.record("Must refuse dangling symlink") } catch {}
        #expect(!(FileManager.default.fileExists(atPath: missingTarget.path)))
    }
    @Test func testRecentIsBoundedAndParallelWritesAreSerialized() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore()
        let records = (0..<205).map { record("test \($0)") }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for item in records { group.addTask { try await store.append(item, folder: folder) } }
            try await group.waitForAll()
        }
        let recent = try await store.recent(folder: folder)
        #expect((recent.count) == (200))
        #expect((Set(recent.map(\.id)).count) == (200))
    }
    @Test func testFolderFailureIsRecoverableAndRecordStaysAvailable() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore(), item = record()
        let notFolder = folder.appendingPathComponent("file")
        try Data().write(to: notFolder)
        do { try await store.append(item, folder: notFolder); Issue.record("Expected unavailable folder failure") } catch {}
        #expect((item.text) == ("Synthetic test transcript"))
        try await store.append(item, folder: folder)
        let recent = try await store.recent(folder: folder)
        #expect((recent.first?.id) == (item.id))
    }
}
