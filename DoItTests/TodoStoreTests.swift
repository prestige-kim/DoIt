import XCTest
@testable import DoIt

/// T-002 저장소 테스트. 모든 파일은 임시 폴더에서만 다룬다 (실제 사용자 파일은 건드리지 않음).
@MainActor
final class TodoStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DoItTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var fileURL: URL { tempDir.appendingPathComponent("todos.json") }

    // MARK: 저장 → 불러오기

    func testSaveThenLoadGivesSameTodos() throws {
        let store = TodoStore(fileURL: fileURL)
        store.load()
        XCTAssertTrue(store.todos.isEmpty, "파일이 없으면 빈 목록")

        let today = LocalDate(year: 2026, month: 11, day: 7)
        let a = try XCTUnwrap(store.add(title: "우유 사기", dueDate: today))
        store.add(title: "보고서 제출", dueDate: today.adding(days: 3))
        store.toggleDone(id: a.id)
        XCTAssertTrue(store.hasPendingSave, "변경 후에는 디바운스 저장이 대기 중")
        store.flushPendingSave()
        XCTAssertFalse(store.hasPendingSave)

        let reloaded = TodoStore(fileURL: fileURL)
        reloaded.load()
        XCTAssertEqual(reloaded.todos.count, 2)
        for (x, y) in zip(store.todos, reloaded.todos) {
            XCTAssertEqual(x.id, y.id)
            XCTAssertEqual(x.title, y.title)
            XCTAssertEqual(x.dueDate, y.dueDate)
            XCTAssertEqual(x.isDone, y.isDone)
            // 파일에는 밀리초까지 저장하므로 1ms 이내 차이는 허용
            XCTAssertEqual(x.createdAt.timeIntervalSince1970, y.createdAt.timeIntervalSince1970, accuracy: 0.002)
            XCTAssertEqual(x.updatedAt.timeIntervalSince1970, y.updatedAt.timeIntervalSince1970, accuracy: 0.002)
            XCTAssertEqual(x.doneAt == nil, y.doneAt == nil)
        }
        XCTAssertNotNil(reloaded.todos[0].doneAt, "완료 시각이 저장됨")

        // 파일 형식: schemaVersion, yyyy-MM-dd 마감일
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("\"schemaVersion\" : 1"))
        XCTAssertTrue(text.contains("\"dueDate\" : \"2026-11-07\""))
        XCTAssertTrue(text.contains("\"dueDate\" : \"2026-11-10\""))
    }

    func testBlankTitleIsIgnoredAndNotSaved() {
        let store = TodoStore(fileURL: fileURL)
        XCTAssertNil(store.add(title: "", dueDate: .today()))
        XCTAssertNil(store.add(title: "   \n ", dueDate: .today()))
        XCTAssertTrue(store.todos.isEmpty)
        XCTAssertFalse(store.hasPendingSave, "아무것도 안 바뀌면 저장하지 않음")
    }

    func testToggleSetsAndClearsDoneAt() throws {
        let store = TodoStore(fileURL: fileURL)
        let t = try XCTUnwrap(store.add(title: "a", dueDate: .today()))
        store.toggleDone(id: t.id)
        XCTAssertTrue(store.todos[0].isDone)
        XCTAssertNotNil(store.todos[0].doneAt)
        store.toggleDone(id: t.id)
        XCTAssertFalse(store.todos[0].isDone)
        XCTAssertNil(store.todos[0].doneAt)
        store.flushPendingSave()
    }

    // MARK: 깨진 파일

    func testCorruptFileIsBackedUpAndStartsEmpty() throws {
        let garbage = Data("{ 이건 JSON이 아님".utf8)
        try garbage.write(to: fileURL)

        let store = TodoStore(fileURL: fileURL)
        store.load()

        XCTAssertTrue(store.todos.isEmpty, "빈 목록으로 시작")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "원본은 백업으로 이름이 바뀜")
        let backups = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
            .filter { $0.hasPrefix("todos.corrupt-") && $0.hasSuffix(".json") }
        XCTAssertEqual(backups.count, 1)
        let backupData = try Data(contentsOf: tempDir.appendingPathComponent(backups[0]))
        XCTAssertEqual(backupData, garbage, "사용자 데이터를 지우지 않고 그대로 보관")
    }

    func testUnknownSchemaVersionIsTreatedAsCorrupt() throws {
        try Data(#"{ "schemaVersion": 99, "todos": [] }"#.utf8).write(to: fileURL)
        let store = TodoStore(fileURL: fileURL)
        store.load()
        XCTAssertTrue(store.todos.isEmpty)
        let backups = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
            .filter { $0.hasPrefix("todos.corrupt-") }
        XCTAssertEqual(backups.count, 1)
    }

    // MARK: 정렬

    func testSortOrder() {
        let d1 = LocalDate(year: 2026, month: 11, day: 7)
        let d2 = d1.adding(days: 1)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        func make(_ title: String, _ due: LocalDate, done: Bool = false, created: Double) -> Todo {
            Todo(title: title, dueDate: due, isDone: done, createdAt: base.addingTimeInterval(created))
        }
        let todos = [
            make("완료-이른날", d1, done: true, created: 0),
            make("내일-먼저생성", d2, created: 1),
            make("오늘-나중생성", d1, created: 5),
            make("오늘-먼저생성", d1, created: 2),
            make("내일-나중생성", d2, created: 3),
        ]
        let titles = TodoOrdering.sorted(todos).map(\.title)
        XCTAssertEqual(titles, ["오늘-먼저생성", "오늘-나중생성", "내일-먼저생성", "내일-나중생성", "완료-이른날"])
    }

    // MARK: D-day

    func testDDayLabels() {
        let today = LocalDate(year: 2026, month: 11, day: 7)
        XCTAssertEqual(TodoOrdering.dDayLabel(due: today.adding(days: 3), today: today), "D-3")
        XCTAssertEqual(TodoOrdering.dDayLabel(due: today, today: today), "D-Day")
        XCTAssertEqual(TodoOrdering.dDayLabel(due: today.adding(days: -2), today: today), "D+2")
        // 달·해가 바뀌는 경계
        XCTAssertEqual(TodoOrdering.dDayLabel(due: LocalDate(year: 2027, month: 1, day: 1),
                                              today: LocalDate(year: 2026, month: 12, day: 31)), "D-1")
    }

    func testLocalDateParsing() {
        XCTAssertEqual(LocalDate(string: "2026-03-09"), LocalDate(year: 2026, month: 3, day: 9))
        XCTAssertNil(LocalDate(string: "2026-02-30"), "없는 날짜")
        XCTAssertNil(LocalDate(string: "2026-3-9"), "자릿수 틀림")
        XCTAssertNil(LocalDate(string: "hello"))
    }
}
