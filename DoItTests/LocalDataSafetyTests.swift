import XCTest
@testable import DoIt

@MainActor
final class LocalDataSafetyTests: XCTestCase {
    func testTodoFailureKeepsDirtyAndRetryPersists() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try Data().write(to: base)
        let store = TodoStore(fileURL: base.appendingPathComponent("todos.json"))
        store.add(title: "fake", dueDate: .today())
        XCTAssertFalse(store.flushPendingSave())
        XCTAssertTrue(store.hasPendingSave)
        XCTAssertNotNil(store.saveError)
        try FileManager.default.removeItem(at: base)
        XCTAssertTrue(store.flushPendingSave())
        let again = TodoStore(fileURL: store.fileURL)
        again.load()
        XCTAssertEqual(again.todos.count, 1)
        XCTAssertFalse(store.hasPendingSave)
    }

    func testHistoryFailureKeepsOriginalCache() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let suite = "DoIt.T021." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LmsStore(directory: base, defaults: defaults)
        let today = LocalDate.today()
        let old = LmsItem(uid: "event-assignment-fake", title: "fake", courseName: nil, dueDate: today.adding(days: -1), dueTime: nil)
        try TodoStore.makeEncoder().encode(LmsStore.CacheFile(schemaVersion: 1, items: [old])).write(to: store.cacheURL)
        store.load(today: today.adding(days: -2))
        try FileManager.default.createDirectory(at: store.historyURL, withIntermediateDirectories: false)
        XCTAssertFalse(store.archivePastItems(today: today))
        let cache = try TodoStore.makeDecoder().decode(LmsStore.CacheFile.self, from: Data(contentsOf: store.cacheURL))
        XCTAssertEqual(cache.items.map(\.uid), [old.uid])
        XCTAssertTrue(store.hasPendingSave)
        try FileManager.default.removeItem(at: store.historyURL)
        XCTAssertTrue(store.retryPendingSaves())
        let again = LmsStore(directory: base, defaults: defaults)
        again.load(today: today)
        XCTAssertEqual(again.history.map(\.uid), [old.uid])
    }
}
