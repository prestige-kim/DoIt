import XCTest
@testable import DoIt

/// T-011: 직전 화면 유지(PRD F12), 카드 폭, 디자인 문구, 달력 빨간 점. 모두 임시 폴더 (실제 사용자 파일 없음)
@MainActor
final class DesignTests: XCTestCase {
    private var dir: URL!
    private var clock = LocalDate(year: 2026, month: 11, day: 7).noonDate!
    private let today = LocalDate(year: 2026, month: 11, day: 7)

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("DoItDesignTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func makeTodos() -> TodoStore {
        let s = TodoStore(fileURL: dir.appendingPathComponent("todos.json"), saveDelay: 0)
        s.now = { [unowned self] in self.clock }
        s.refreshToday()
        return s
    }

    // MARK: PanelViewState (순수)

    func testInitialIsListToday() {
        let s = PanelViewState.initial(today: today)
        XCTAssertEqual(s.mode, .list)
        XCTAssertEqual(s.selected, today)
        XCTAssertEqual(s.month, LocalDate(year: 2026, month: 11, day: 1))
    }

    func testCollapseKeepsEverything() {
        var s = PanelViewState.initial(today: today).openingCalendar(today: today)
        s.month = LocalDate(year: 2026, month: 10, day: 1)
        s.selected = LocalDate(year: 2026, month: 10, day: 9)
        XCTAssertEqual(s.collapsed(), s, "접혔다 펼쳐도 같은 화면·달·날짜")
    }

    func testTurnOffResetsToListToday() {
        var s = PanelViewState.initial(today: today).openingCalendar(today: today)
        s.selected = today.adding(days: 5)
        XCTAssertEqual(s.turnedOff(today: today), .initial(today: today))
    }

    func testDayChangeMovesSelectedTodayOnly() {
        let next = today.adding(days: 1)
        let cal = PanelViewState.initial(today: today).openingCalendar(today: today)
        let moved = cal.dayChanged(from: today, to: next)
        XCTAssertEqual(moved.mode, .calendar, "화면 종류 유지")
        XCTAssertEqual(moved.selected, next, "'어제의 오늘'을 보고 있었으면 새 오늘로")

        var future = cal
        future.selected = today.adding(days: 5)
        XCTAssertEqual(future.dayChanged(from: today, to: next), future, "다른 날짜를 보고 있었으면 그대로")

        let list = PanelViewState.initial(today: today)
        XCTAssertEqual(list.dayChanged(from: today, to: next).mode, .list)
    }

    func testDayChangeAcrossMonthMovesVisibleMonth() {
        let oct31 = LocalDate(year: 2026, month: 10, day: 31)
        let nov1 = LocalDate(year: 2026, month: 11, day: 1)
        let s = PanelViewState.initial(today: oct31).openingCalendar(today: oct31).dayChanged(from: oct31, to: nov1)
        XCTAssertEqual(s.selected, nov1)
        XCTAssertEqual(s.month, nov1, "10월을 보고 있었으면 11월로")

        var other = PanelViewState.initial(today: oct31).openingCalendar(today: oct31)
        other.month = LocalDate(year: 2026, month: 9, day: 1)
        XCTAssertEqual(other.dayChanged(from: oct31, to: nov1).month, other.month, "다른 달을 보고 있었으면 달은 그대로")
    }

    // MARK: 뷰모델

    func testViewModelKeepsCalendarAcrossDayChangeAndResetsOnTurnOff() {
        let todos = makeTodos()
        let vm = NotchViewModel(store: todos)
        XCTAssertEqual(vm.contentCardWidth, PanelLayout.listCardWidth)
        vm.togglePanelMode()
        XCTAssertEqual(vm.contentCardWidth, PanelLayout.calendarCardWidth, "달력은 520 폭")
        XCTAssertEqual(vm.expandedFrameSize.width,
                       PanelLayout.calendarCardWidth + 2 * NotchViewModel.expandedTopRadius + 2 * NotchViewModel.shadowMargin)

        // 자정이 지남
        clock = clock.addingTimeInterval(86_400)
        todos.refreshToday()
        XCTAssertEqual(vm.panelMode, .calendar)
        XCTAssertEqual(vm.calendarSelected, today.adding(days: 1), "선택 날짜가 새 오늘로")
        XCTAssertEqual(vm.draftDueDate, today.adding(days: 1), "입력창 날짜도 새 오늘")

        // 메뉴로 끄면 다음에는 목록·오늘
        vm.turnOn()
        vm.turnOff()
        XCTAssertEqual(vm.panelMode, .list)
        XCTAssertEqual(vm.viewState, .initial(today: today.adding(days: 1)))
        XCTAssertEqual(vm.contentCardWidth, PanelLayout.listCardWidth)
        todos.flushPendingSave()
    }

    /// T-029: 목록 화면에서 자정이 지나면 입력창 날짜(오늘 버튼·날짜 선택 달력)가 어제에 남지 않는다
    func testListDraftDueDateFollowsNewTodayAfterMidnight() {
        let todos = makeTodos()
        let vm = NotchViewModel(store: todos)
        XCTAssertEqual(vm.panelMode, .list)
        XCTAssertEqual(vm.draftDueDate, today)

        clock = clock.addingTimeInterval(86_400)  // 자정이 지남
        todos.refreshToday()
        let next = today.adding(days: 1)
        XCTAssertEqual(vm.draftDueDate, next, "입력창 날짜가 새 오늘로")
        XCTAssertEqual(DueDateLabel.text(for: vm.draftDueDate, today: todos.today), "오늘", "버튼 문구는 '오늘'")

        // 잠자기 등으로 여러 날을 건너뛰어도 새 오늘로
        clock = clock.addingTimeInterval(3 * 86_400)
        todos.refreshToday()
        XCTAssertEqual(vm.draftDueDate, today.adding(days: 4))
        todos.flushPendingSave()
    }

    func testListDraftDueDateKeepsUserPickedDateAfterMidnight() {
        let todos = makeTodos()
        let vm = NotchViewModel(store: todos)
        let picked = today.adding(days: 7)
        vm.pickDate(picked)                       // +1주를 직접 고름
        clock = clock.addingTimeInterval(86_400)
        todos.refreshToday()
        XCTAssertEqual(vm.draftDueDate, picked, "직접 고른 날짜는 그대로")

        let past = todos.today.adding(days: -3)
        vm.pickDate(past)                         // 지난 날짜도 고를 수 있다
        clock = clock.addingTimeInterval(86_400)
        todos.refreshToday()
        XCTAssertEqual(vm.draftDueDate, past, "직접 고른 지난 날짜도 그대로")
        todos.flushPendingSave()
    }

    func testAddAfterMidnightUsesNewToday() throws {
        let todos = makeTodos()
        let vm = NotchViewModel(store: todos)
        vm.turnOn()                               // 패널이 켜져 펼쳐진 상태 (꺼져 있으면 입력 이벤트를 무시한다)
        XCTAssertEqual(vm.draftDueDate, today)
        clock = clock.addingTimeInterval(86_400)  // 펼친 채 자정 알림 없이 날짜가 바뀜 → 추가 직전에 날짜를 확인
        vm.submit(title: "자정 뒤 추가")
        let added = try XCTUnwrap(todos.todos.first { $0.title == "자정 뒤 추가" })
        XCTAssertEqual(added.dueDate, today.adding(days: 1), "어제 날짜로 저장되지 않음")
        XCTAssertEqual(vm.draftDueDate, today.adding(days: 1))
        todos.flushPendingSave()
    }

    // MARK: 문구·점

    func testLmsHeaderCaption() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 22, minute: 0))!
        let sync = cal.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 21, minute: 5))!
        let yesterday = cal.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 9, minute: 30))!
        XCTAssertEqual(LmsDisplay.headerCaption(weeks: 2, lastSuccess: sync, now: now, calendar: cal), "2주 · 21:05 동기화")
        XCTAssertEqual(LmsDisplay.headerCaption(weeks: 2, lastSuccess: yesterday, now: now, calendar: cal), "2주 · 11/6 09:30 동기화")
        XCTAssertEqual(LmsDisplay.headerCaption(weeks: 3, lastSuccess: nil, now: now, calendar: cal), "3주")
    }

    func testLmsDueTexts() {
        let item = LmsItem(uid: "event-assignment-1", title: "과제", courseName: nil, dueDate: today.adding(days: -1), dueTime: nil)
        XCTAssertEqual(LmsDisplay.dueTitle(item, isChecked: false, today: today), "어제 마감")
        XCTAssertEqual(LmsDisplay.dueTitle(item, isChecked: true, today: today), "D+1", "체크했으면 지난 마감 아님")
        let soon = LmsItem(uid: "event-assignment-2", title: "과제", courseName: nil, dueDate: today.adding(days: 3), dueTime: nil)
        XCTAssertEqual(LmsDisplay.dueTitle(soon, isChecked: false, today: today), "D-3")
        XCTAssertEqual(LmsDisplay.dueDetail(soon), "11/10(화)")
    }

    func testPastUndoneLmsDotIsRed() {
        let past = today.adding(days: -2)
        let a = LmsItem(uid: "event-assignment-1", title: "a", courseName: nil, dueDate: past, dueTime: nil)
        let b = LmsItem(uid: "event-assignment-2", title: "b", courseName: nil, dueDate: past, dueTime: nil)
        let grid = CalendarModel.monthGrid(today)
        let withToday = CalendarModel.summaries(grid: grid, todos: [], lms: [a, b], checked: [b.uid: clock], today: today)
        XCTAssertEqual(withToday[past]?.dots, [.lmsOverdue, .lms(done: true)], "지난 미완료 = 빨강, 완료 = 흐린 파랑")
        let future = LmsItem(uid: "event-assignment-3", title: "c", courseName: nil, dueDate: today.adding(days: 2), dueTime: nil)
        XCTAssertEqual(CalendarModel.summaries(grid: grid, todos: [], lms: [future], checked: [:], today: today)[future.dueDate]?.dots,
                       [.lms(done: false)])
    }
}
