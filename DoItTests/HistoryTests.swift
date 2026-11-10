import XCTest
@testable import DoIt

/// T-009: LMS 기록 보관, 옛 체크 파일 이전, 달력 계산, 기록 정리 대상·실행, 달력 화면 높이·모드
/// 모두 임시 폴더·임시 UserDefaults (실제 사용자 파일 없음)
@MainActor
final class HistoryTests: XCTestCase {
    private var dir: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var clock = LocalDate(year: 2026, month: 11, day: 7).noonDate!
    private let today = LocalDate(year: 2026, month: 11, day: 7)  // 토요일

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("DoItHistoryTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        suiteName = "DoItHistoryTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeLms() -> LmsStore {
        let s = LmsStore(directory: dir, defaults: defaults)
        s.now = { [unowned self] in self.clock }
        return s
    }

    private func makeTodos() -> TodoStore {
        let s = TodoStore(fileURL: dir.appendingPathComponent("todos.json"), saveDelay: 0)
        s.now = { [unowned self] in self.clock }
        return s
    }

    private func item(_ n: Int, _ days: Int, title: String? = nil) -> LmsItem {
        LmsItem(uid: "event-assignment-\(n)", title: title ?? "과제\(n)", courseName: "가짜과목(Fake) 01분반",
                dueDate: today.adding(days: days), dueTime: nil)
    }

    // MARK: LMS 기록 보관 (F13, D-012)

    func testPastGoesToHistoryFutureMissingIsNotArchived() {
        let lms = makeLms()
        lms.replaceItems(with: [item(1, -3), item(2, 0), item(3, 5)], today: today)
        XCTAssertEqual(lms.history.map(\.uid), ["event-assignment-1"])
        XCTAssertEqual(lms.items.map(\.uid), ["event-assignment-2", "event-assignment-3"])

        // 마감 전인 3번이 피드에서 사라짐 (교수자 삭제) → 기록에 넣지 않음
        lms.replaceItems(with: [item(1, -3), item(2, 0)], today: today)
        XCTAssertEqual(lms.history.map(\.uid), ["event-assignment-1"])
        XCTAssertEqual(lms.items.map(\.uid), ["event-assignment-2"])
    }

    func testCachedItemWhoseDeadlinePassedIsArchivedEvenIfFeedDropsIt() {
        let lms = makeLms()
        lms.replaceItems(with: [item(2, 0)], today: today)
        // 다음 날 동기화: 피드가 어제 마감 과제를 더 이상 주지 않아도, 마감 시점까지 갖고 있었으므로 기록에 남김
        let tomorrow = today.adding(days: 1)
        lms.replaceItems(with: [], today: tomorrow)
        XCTAssertEqual(lms.history.map(\.uid), ["event-assignment-2"])
        XCTAssertTrue(lms.items.isEmpty)
    }

    func testUpsertUpdatesSameUIDAndKeepsArchivedAt() throws {
        let lms = makeLms()
        lms.replaceItems(with: [item(1, -3, title: "옛 제목")], today: today)
        let firstArchived = try XCTUnwrap(lms.history.first).archivedAt
        clock += 86400
        lms.replaceItems(with: [item(1, -3, title: "새 제목")], today: today)
        XCTAssertEqual(lms.history.count, 1)
        XCTAssertEqual(lms.history.first?.title, "새 제목")
        XCTAssertEqual(lms.history.first?.archivedAt, firstArchived, "보관 시작 시각은 처음 값")
    }

    func testArchivePastItemsOnDayChangeWithoutNetwork() {
        let lms = makeLms()
        lms.replaceItems(with: [item(1, 0), item(2, 1)], today: today)
        var changed = 0
        lms.onChange = { changed += 1 }
        lms.archivePastItems(today: today.adding(days: 1))
        XCTAssertEqual(lms.history.map(\.uid), ["event-assignment-1"])
        XCTAssertEqual(lms.items.map(\.uid), ["event-assignment-2"])
        XCTAssertEqual(changed, 1)
        // 패널: 어제 마감 미완료는 기록에서 와서 빨간색으로 보임
        XCTAssertEqual(lms.visibleItems(today: today.adding(days: 1)).map(\.uid), ["event-assignment-1", "event-assignment-2"])
    }

    func testHistoryPersistsAndHasOnlyAllowedFields() throws {
        let lms = makeLms()
        lms.replaceItems(with: [item(1, -3)], today: today)
        let reloaded = makeLms()
        reloaded.load(today: today)
        XCTAssertEqual(reloaded.history, lms.history)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: lms.historyURL)) as? [String: Any]
        let first = try XCTUnwrap((json?["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(first.keys), ["uid", "title", "courseName", "dueDate", "archivedAt"])
    }

    func testDisconnectKeepsHistory() {
        let lms = makeLms()
        lms.replaceItems(with: [item(1, -3), item(2, 1)], today: today)
        lms.disconnect()
        XCTAssertTrue(lms.items.isEmpty)
        XCTAssertEqual(lms.history.count, 1, "기록은 사용자 데이터라 유지")
    }

    // MARK: 체크 상태 (history 기준 규칙)

    func testCheckKeptWhileInCacheOrHistoryRemovedWhenInNeither() {
        let lms = makeLms()
        lms.replaceItems(with: [item(1, -3), item(2, 1), item(3, 2)], today: today)
        for n in 1...3 { lms.toggleCheck(uid: "event-assignment-\(n)") }
        // 1: 기록에 있음 → 유지, 2: 피드에 있음 → 유지, 3: 마감 전 삭제됨 → 정리
        lms.replaceItems(with: [item(2, 1)], today: today)
        XCTAssertTrue(lms.isChecked("event-assignment-1"))
        XCTAssertTrue(lms.isChecked("event-assignment-2"))
        XCTAssertFalse(lms.isChecked("event-assignment-3"))
    }

    func testOldStateFileV1IsBackedUpAndConverted() throws {
        // T-007 형식 (goneSince 포함)
        let v1 = """
        {"doneUids":{"event-assignment-1":"2026-11-01T12:00:00.000+09:00"},
         "goneSince":{"event-assignment-1":"2026-11-02T12:00:00.000+09:00"},"schemaVersion":1}
        """
        let lms = makeLms()
        try Data(v1.utf8).write(to: lms.stateURL)
        lms.load(today: today)
        XCTAssertTrue(lms.isChecked("event-assignment-1"), "옛 체크 상태를 그대로 읽음")

        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let backup = try XCTUnwrap(files.first { $0.hasPrefix("lms-state.v1-backup-") }, "\(files)")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent(backup), encoding: .utf8), v1, "원본 그대로 백업")
        let converted = try String(contentsOf: lms.stateURL, encoding: .utf8)
        XCTAssertTrue(converted.contains("\"schemaVersion\" : 2"))
        XCTAssertFalse(converted.contains("goneSince"))

        // 다시 읽어도 백업을 또 만들지 않음
        makeLms().load(today: today)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("lms-state.v1-backup-") }.count, 1)
    }

    // MARK: CalendarModel (F12)

    func testMonthGridStartsSundaySixWeeks() {
        let nov = CalendarModel.monthGrid(LocalDate(year: 2026, month: 11, day: 20))
        XCTAssertEqual(nov.count, 42)
        XCTAssertEqual(nov.first, LocalDate(year: 2026, month: 11, day: 1), "2026-11-01은 일요일")
        XCTAssertEqual(nov.last, LocalDate(year: 2026, month: 12, day: 12))
        let oct = CalendarModel.monthGrid(LocalDate(year: 2026, month: 10, day: 1))
        XCTAssertEqual(oct.first, LocalDate(year: 2026, month: 9, day: 27), "10/1(목) 앞의 일요일")
        for (i, d) in oct.enumerated() where i % 7 == 0 {
            XCTAssertEqual(LocalDate.calendar.component(.weekday, from: d.noonDate!), 1, "각 줄은 일요일 시작")
        }
    }

    func testLeapYearAndMonthNavigation() {
        let feb = CalendarModel.monthGrid(LocalDate(year: 2028, month: 2, day: 1))
        XCTAssertTrue(feb.contains(LocalDate(year: 2028, month: 2, day: 29)), "윤년")
        XCTAssertEqual(feb.first, LocalDate(year: 2028, month: 1, day: 30))
        let febNonLeap = CalendarModel.monthGrid(LocalDate(year: 2027, month: 2, day: 1))
        XCTAssertFalse(febNonLeap.contains(where: { $0.month == 2 && $0.day == 29 }))
        XCTAssertEqual(CalendarModel.addingMonths(LocalDate(year: 2026, month: 12, day: 31), 1), LocalDate(year: 2027, month: 1, day: 1))
        XCTAssertEqual(CalendarModel.addingMonths(LocalDate(year: 2026, month: 1, day: 31), -1), LocalDate(year: 2025, month: 12, day: 1))
        XCTAssertEqual(CalendarModel.addingMonths(LocalDate(year: 2026, month: 1, day: 31), 1), LocalDate(year: 2026, month: 2, day: 1))
        XCTAssertEqual(CalendarModel.title(LocalDate(year: 2026, month: 11, day: 1)), "2026년 11월")
        XCTAssertEqual(CalendarModel.dayTitle(LocalDate(year: 2026, month: 11, day: 14)), "11월 14일 (토)")
    }

    func testReadOnlyForPastDatesOnly() {
        XCTAssertTrue(CalendarModel.isReadOnly(today.adding(days: -1), today: today))
        XCTAssertFalse(CalendarModel.isReadOnly(today, today: today))
        XCTAssertFalse(CalendarModel.isReadOnly(today.adding(days: 1), today: today))
    }

    func testEntriesAndDotsPerDay() {
        let base = today.noonDate!
        let todoUndone = Todo(title: "할 일", dueDate: today, createdAt: base)
        let todoDone = Todo(title: "끝난 일", dueDate: today, isDone: true, createdAt: base.addingTimeInterval(1), doneAt: base)
        let other = Todo(title: "다른 날", dueDate: today.adding(days: 1), createdAt: base)
        let lmsA = item(1, 0, title: "B 과제"), lmsB = item(2, 0, title: "A 과제")
        let entries = CalendarModel.entries(on: today, todos: [todoDone, todoUndone, other], lms: [lmsA, lmsB],
                                            checked: [lmsA.uid: base])
        XCTAssertEqual(entries.map(\.title), ["할 일", "A 과제", "끝난 일", "B 과제"], "미완료 먼저, 내 할 일 → LMS(과제명순)")
        XCTAssertEqual(entries.map(\.isDone), [false, false, true, true])
        XCTAssertEqual(entries[1].course, "가짜과목(Fake) 01분반")

        let summary = CalendarModel.summary(entries: entries)
        XCTAssertEqual(summary.dots, [.todo(done: false), .lms(done: false), .todo(done: true)], "최대 3개")
        XCTAssertTrue(summary.hasMore, "4개 이상이면 +")
        XCTAssertEqual(CalendarModel.summary(entries: [entries[2]]).dots, [.todo(done: true)], "완료만 있는 날은 흐린 점")

        let grid = CalendarModel.monthGrid(today)
        let all = CalendarModel.summaries(grid: grid, todos: [todoDone, todoUndone, other], lms: [lmsA, lmsB], checked: [:])
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[today.adding(days: 1)]?.dots, [.todo(done: false)])
        XCTAssertNil(all[today.adding(days: 2)])
    }

    func testEntriesIncludeHistoryViaAllItems() {
        let lms = makeLms()
        lms.replaceItems(with: [item(1, -30), item(2, 3)], today: today)
        let past = CalendarModel.entries(on: today.adding(days: -30), todos: [], lms: lms.allItems, checked: lms.checked)
        XCTAssertEqual(past.map(\.title), ["과제1"], "지난 과제는 기록에서")
    }

    // MARK: HistoryPolicy (F13)

    private func doneTodo(_ title: String, doneDaysAgo: Int) -> Todo {
        let doneAt = today.adding(days: -doneDaysAgo).noonDate!
        return Todo(title: title, dueDate: today.adding(days: -doneDaysAgo), isDone: true, createdAt: doneAt, doneAt: doneAt)
    }

    func testPlanByRetentionNeverIncludesUndone() {
        let oldDone = doneTodo("오래전 완료", doneDaysAgo: 400)
        let recentDone = doneTodo("최근 완료", doneDaysAgo: 100)
        let oldUndone = Todo(title: "오래된 미완료", dueDate: today.adding(days: -900), createdAt: today.adding(days: -900).noonDate!)
        let doneNoDate = Todo(title: "doneAt 없음", dueDate: today.adding(days: -900), isDone: true, createdAt: today.adding(days: -900).noonDate!)
        let h1 = LmsHistoryItem(uid: "event-assignment-1", title: "오래된 과제", courseName: nil, dueDate: today.adding(days: -200), archivedAt: clock)
        let h2 = LmsHistoryItem(uid: "event-assignment-2", title: "최근 과제", courseName: nil, dueDate: today.adding(days: -30), archivedAt: clock)
        let todos = [oldDone, recentDone, oldUndone, doneNoDate]
        let checked = [h1.uid: clock, h2.uid: clock, "event-assignment-9": clock]

        let six = HistoryPolicy.plan(today: today, retention: .sixMonths, todos: todos, history: [h1, h2], checked: checked)
        XCTAssertEqual(six.todos.map(\.title), ["오래전 완료"])
        XCTAssertEqual(six.lmsHistory.map(\.uid), [h1.uid])
        XCTAssertEqual(Set(six.lmsChecks.keys), [h1.uid], "대상 과제의 체크 상태만")
        XCTAssertEqual(six.count, 2)

        let year = HistoryPolicy.plan(today: today, retention: .oneYear, todos: todos, history: [h1, h2], checked: checked)
        XCTAssertEqual(year.todos.map(\.title), ["오래전 완료"])
        XCTAssertTrue(year.lmsHistory.isEmpty)

        let two = HistoryPolicy.plan(today: today, retention: .twoYears, todos: todos, history: [h1, h2], checked: checked)
        XCTAssertTrue(two.isEmpty)

        XCTAssertTrue(HistoryPolicy.plan(today: today, retention: .never, todos: todos, history: [h1, h2], checked: checked).isEmpty)

        for r in HistoryRetention.allCases {
            let p = HistoryPolicy.plan(today: today, retention: r, todos: todos, history: [h1, h2], checked: checked)
            XCTAssertFalse(p.todos.contains { !$0.isDone }, "완료 안 한 할 일은 절대 대상 아님 (\(r))")
            XCTAssertFalse(p.todos.contains { $0.doneAt == nil })
        }
        XCTAssertEqual(HistoryRetention.default, .oneYear)
    }

    func testCutoffDates() {
        XCTAssertEqual(HistoryPolicy.cutoff(today: today, retention: .sixMonths), LocalDate(year: 2026, month: 5, day: 7))
        XCTAssertEqual(HistoryPolicy.cutoff(today: today, retention: .oneYear), LocalDate(year: 2025, month: 11, day: 7))
        XCTAssertEqual(HistoryPolicy.cutoff(today: LocalDate(year: 2028, month: 2, day: 29), retention: .oneYear),
                       LocalDate(year: 2027, month: 2, day: 28), "윤일")
        XCTAssertNil(HistoryPolicy.cutoff(today: today, retention: .never))
    }

    func testResetPlanKeepsUndone() {
        let undone = Todo(title: "미완료", dueDate: today, createdAt: clock)
        let done = doneTodo("완료", doneDaysAgo: 0)
        let p = HistoryPolicy.resetPlan(todos: [undone, done], history: [], checked: ["x": clock])
        XCTAssertEqual(p.todos.map(\.title), ["완료"])
        XCTAssertEqual(p.lmsChecks.count, 1)
    }

    func testArchiveFileNames() {
        XCTAssertEqual(HistoryPolicy.archiveFileName(today: today, existing: []), "기록-20261107.json")
        XCTAssertEqual(HistoryPolicy.archiveFileName(today: today, existing: ["기록-20261107.json"]), "기록-20261107-2.json")
        XCTAssertEqual(HistoryPolicy.archiveFileName(today: today, existing: ["기록-20261107.json", "기록-20261107-2.json"]), "기록-20261107-3.json")
    }

    // MARK: 정리 실행

    private func makeHistoryService(archive: URL? = nil) -> (HistoryService, TodoStore, LmsStore) {
        let todos = makeTodos()
        let lms = makeLms()
        let h = HistoryService(todoStore: todos, lmsStore: lms, archiveDirectory: archive ?? dir.appendingPathComponent("archive"), defaults: defaults)
        h.now = { [unowned self] in self.clock }
        h.today = { [today] in today }
        return (h, todos, lms)
    }

    /// 400일 전 완료 1개 + 미완료 1개 + 200일 전 LMS 기록 1개(체크됨) + 현재 LMS 1개
    private func seed(_ todos: TodoStore, _ lms: LmsStore) throws {
        var t = clock
        todos.now = { t }
        t = today.adding(days: -400).noonDate!
        let old = try XCTUnwrap(todos.add(title: "오래전 완료", dueDate: today.adding(days: -400)))
        todos.toggleDone(id: old.id)
        todos.add(title: "미완료", dueDate: today.adding(days: -400))
        t = clock
        todos.flushPendingSave()
        lms.replaceItems(with: [item(1, -200), item(2, 3)], today: today)
        lms.toggleCheck(uid: "event-assignment-1")
    }

    func testBackupFailureDeletesNothing() throws {
        // archive 자리에 일반 파일을 두어 폴더를 만들 수 없게 함
        let blocker = dir.appendingPathComponent("archive")
        try Data("x".utf8).write(to: blocker)
        let (h, todos, lms) = makeHistoryService(archive: blocker)
        h.retention = .sixMonths
        try seed(todos, lms)
        h.recompute()
        XCTAssertEqual(h.pending.count, 2)

        XCTAssertThrowsError(try h.run(h.pending, backup: true))
        XCTAssertEqual(todos.todos.count, 2, "백업 실패 → 하나도 지우지 않음")
        XCTAssertEqual(lms.history.count, 1)
        XCTAssertTrue(lms.isChecked("event-assignment-1"))
    }

    func testBackupThenDelete() throws {
        let (h, todos, lms) = makeHistoryService()
        h.retention = .sixMonths
        try seed(todos, lms)
        h.recompute()
        let plan = h.pending
        var changed = 0
        h.onDataChanged = { changed += 1 }

        let result = try h.run(plan, backup: true)
        XCTAssertEqual(result.removedCount, 2)
        let url = try XCTUnwrap(result.backupURL)
        XCTAssertEqual(url.lastPathComponent, "기록-20261107.json")
        let backup = try TodoStore.makeDecoder().decode(HistoryArchiveFile.self, from: Data(contentsOf: url))
        XCTAssertEqual(backup.kind, "cleanup")
        XCTAssertEqual(backup.todos.map(\.title), ["오래전 완료"])
        XCTAssertEqual(backup.lmsHistory.map(\.uid), ["event-assignment-1"])
        XCTAssertEqual(Set(backup.lmsChecks.keys), ["event-assignment-1"])

        XCTAssertEqual(todos.todos.map(\.title), ["미완료"], "완료 안 한 할 일은 남음")
        XCTAssertTrue(lms.history.isEmpty)
        XCTAssertFalse(lms.isChecked("event-assignment-1"))
        XCTAssertEqual(lms.items.map(\.uid), ["event-assignment-2"], "현재 LMS 과제는 그대로")
        XCTAssertEqual(h.pending.count, 0)
        XCTAssertEqual(changed, 1)

        // 파일에도 반영 (다시 읽기)
        let reTodos = TodoStore(fileURL: todos.fileURL)
        reTodos.load()
        XCTAssertEqual(reTodos.todos.map(\.title), ["미완료"])
        let reLms = makeLms()
        reLms.load(today: today)
        XCTAssertTrue(reLms.history.isEmpty)

        // 같은 날 두 번째 백업은 번호가 붙음
        let second = try h.run(HistoryCleanupPlan(), backup: true)
        XCTAssertEqual(second.backupURL?.lastPathComponent, "기록-20261107-2.json")
    }

    func testCleanupWithoutBackupWritesNoArchive() throws {
        let (h, todos, lms) = makeHistoryService()
        h.retention = .sixMonths
        try seed(todos, lms)
        h.recompute()
        let result = try h.run(h.pending, backup: false)
        XCTAssertNil(result.backupURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("archive").path))
        XCTAssertEqual(todos.todos.count, 1)
    }

    func testResetAllBacksUpAndKeepsUndoneAndCurrentLms() throws {
        let (h, todos, lms) = makeHistoryService()
        try seed(todos, lms)
        lms.toggleCheck(uid: "event-assignment-2")
        let result = try h.resetAll()
        XCTAssertNotNil(result.backupURL, "초기화 전에 자동 백업")
        XCTAssertEqual(todos.todos.map(\.title), ["미완료"])
        XCTAssertTrue(lms.history.isEmpty)
        XCTAssertTrue(lms.checked.isEmpty, "체크 상태 전부")
        XCTAssertEqual(lms.items.count, 1, "현재 LMS 과제·피드 연결은 유지")
    }

    /// T-013: 기록 백업·초기화는 피드 주소 파일을 다루지 않는다 (가짜 주소로 확인)
    func testBackupAndResetNeverIncludeFeedURL() throws {
        let fakeFeed = "https://lms.example.invalid/feeds/calendars/user_FAKE.ics"
        let feedStore = FeedURLFileStore(directory: dir)
        try feedStore.save(try XCTUnwrap(URL(string: fakeFeed)))
        let (h, todos, lms) = makeHistoryService()
        try seed(todos, lms)
        let result = try h.resetAll()
        let backup = try String(contentsOf: XCTUnwrap(result.backupURL), encoding: .utf8)
        XCTAssertFalse(backup.contains(fakeFeed))
        XCTAssertFalse(backup.contains("user_FAKE"))
        XCTAssertFalse(backup.contains(FeedURLFileStore.fileName))
        XCTAssertEqual(try feedStore.load()?.absoluteString, fakeFeed, "초기화 후에도 피드 연결 유지")
        let archived = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("archive").path)
        XCTAssertFalse(archived.contains(FeedURLFileStore.fileName))
    }

    func testRetentionPersistsAndRecomputes() throws {
        let (h, todos, lms) = makeHistoryService()
        XCTAssertEqual(h.retention, .oneYear)
        try seed(todos, lms)
        h.recompute()
        XCTAssertEqual(h.pending.count, 1, "1년: 400일 전 완료만")
        h.retention = .never
        XCTAssertEqual(h.pending.count, 0)
        let (h2, _, _) = makeHistoryService()
        XCTAssertEqual(h2.retention, .never, "설정 기억")
    }

    func testRemoveCompletedNeverRemovesUndone() throws {
        let todos = makeTodos()
        let a = try XCTUnwrap(todos.add(title: "미완료", dueDate: today))
        let b = try XCTUnwrap(todos.add(title: "완료", dueDate: today))
        todos.toggleDone(id: b.id)
        let removed = todos.removeCompleted(ids: [a.id, b.id])
        XCTAssertEqual(removed.map(\.title), ["완료"])
        XCTAssertEqual(todos.todos.map(\.title), ["미완료"])
    }

    // MARK: 저장 공간

    func testStorageReport() throws {
        try Data(repeating: 0x20, count: 100).write(to: dir.appendingPathComponent("todos.json"))
        let archive = dir.appendingPathComponent("archive")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try Data(repeating: 0x20, count: 50).write(to: archive.appendingPathComponent("기록-20261107.json"))
        let r = StorageReport.make(directory: dir, archiveDirectory: archive,
                                   counts: .init(todos: 3, lmsItems: 0, lmsHistory: 0, lmsChecks: 0, cleanup: 1), memory: 1234)
        XCTAssertEqual(r.files.first { $0.name == "todos.json" }?.bytes, 100)
        XCTAssertEqual(r.files.first { $0.name == "todos.json" }?.count, 3)
        XCTAssertNil(r.files.first { $0.name == "lms.json" }?.bytes, "없는 파일")
        XCTAssertEqual(r.archive.bytes, 50)
        XCTAssertEqual(r.archive.count, 1)
        XCTAssertEqual(r.totalBytes, 150)
        XCTAssertEqual(r.cleanupCount, 1)
        XCTAssertEqual(r.memoryBytes, 1234)
        XCTAssertGreaterThan(StorageReport.memoryFootprint() ?? 0, 0, "phys_footprint를 읽을 수 있음")
    }

    // MARK: 달력 화면 높이 (PanelLayout)

    func testCalendarHeight() {
        let fixedWithInput = PanelLayout.calendarFixedHeight(notchHeight: 32, inputVisible: true)
        // T-011: 노치 띠 32 + 8 + 머리 30 + 요일 20 + 칸 54×6 + 범례 22 + 8 + 날짜 제목 22 + 8 + 입력 34 + 10
        XCTAssertEqual(fixedWithInput, 518)
        XCTAssertEqual(PanelLayout.calendarFixedHeight(notchHeight: 32, inputVisible: false),
                       fixedWithInput - PanelLayout.sectionSpacing - PanelLayout.inputHeight, "지난 날짜는 입력창 없음")
        XCTAssertEqual(PanelLayout.calendarBodyHeight(dayRowCount: 0, inputVisible: true, notchHeight: 32, screenHeight: 956), 548)
        XCTAssertEqual(PanelLayout.calendarBodyHeight(dayRowCount: 2, inputVisible: true, notchHeight: 32, screenHeight: 956),
                       518 + 2 * 36 + 2 + 4)
        // 달력은 칸 54를 지키려고 최대 높이를 따로 둔다 (2026-11-08 사용자 결정): 화면 70%, 상한 640
        XCTAssertEqual(PanelLayout.calendarMaxHeight(screenHeight: 956), 640)
        XCTAssertEqual(PanelLayout.calendarMaxHeight(screenHeight: 800), 560)
        XCTAssertEqual(PanelLayout.calendarBodyHeight(dayRowCount: 30, inputVisible: true, notchHeight: 32, screenHeight: 956), 640,
                       "최대 높이에서 멈추고 목록만 스크롤")
        XCTAssertLessThanOrEqual(PanelLayout.calendarBodyHeight(dayRowCount: 0, inputVisible: true, notchHeight: 32, screenHeight: 956),
                                 PanelLayout.calendarMaxHeight(screenHeight: 956), "빈 달력도 맥북 최대 높이 안")
        XCTAssertEqual(PanelLayout.maxHeight(screenHeight: 956), 430, "목록 화면 최대 높이는 그대로")
    }

    // MARK: 패널 모드 (뷰모델)

    func testPanelModeAndReadOnlyCalendar() throws {
        let todos = makeTodos()
        todos.refreshToday()
        let vm = NotchViewModel(store: todos)
        let t = todos.today
        vm.togglePanelMode()
        XCTAssertEqual(vm.panelMode, .calendar)
        XCTAssertEqual(vm.calendarSelected, t, "기본 선택은 오늘")
        XCTAssertTrue(vm.calendarInputVisible)

        vm.selectCalendarDate(t.adding(days: 7))
        XCTAssertEqual(vm.draftDueDate, t.adding(days: 7), "미래 날짜 → 입력창 날짜")

        // 지난 날짜: 보기 전용 (체크 무시, 입력창 없음)
        let past = try XCTUnwrap(todos.add(title: "지난 일", dueDate: t.adding(days: -3)))
        vm.selectCalendarDate(t.adding(days: -3))
        XCTAssertFalse(vm.calendarInputVisible)
        XCTAssertEqual(vm.draftDueDate, t.adding(days: 7), "지난 날짜는 입력 날짜를 바꾸지 않음")
        let entry = try XCTUnwrap(vm.calendarEntries.first)
        vm.toggleCalendarEntry(entry)
        XCTAssertFalse(todos.todos.first { $0.id == past.id }!.isDone, "지난 날짜에서 체크 안 됨")

        // 오늘 날짜: 체크 가능
        let now = try XCTUnwrap(todos.add(title: "오늘 일", dueDate: t))
        vm.calendarGoToToday()
        vm.toggleCalendarEntry(try XCTUnwrap(vm.calendarEntries.first { $0.title == "오늘 일" }))
        XCTAssertTrue(todos.todos.first { $0.id == now.id }!.isDone)

        // 다른 달 날짜를 누르면 그 달로
        vm.selectCalendarDate(CalendarModel.addingMonths(t, 1))
        XCTAssertEqual(vm.calendarMonth, CalendarModel.addingMonths(t, 1))

        // 끄면(즉시 숨김) 목록 화면으로
        vm.turnOn()
        vm.turnOff()
        XCTAssertEqual(vm.panelMode, .list)
        XCTAssertEqual(vm.draftDueDate, t)
        todos.flushPendingSave()
    }
}
