import XCTest
@testable import DoIt

/// T-004: 완료 숨김, 삭제 저장, 패널 높이 계산, 날짜 버튼 문구, 날짜 선택 영역 상태 전환
@MainActor
final class QuickAddTests: XCTestCase {
    private let today = LocalDate(year: 2026, month: 11, day: 7)  // 토요일

    // MARK: 완료 숨김 (PRD F4)

    private func noon(_ d: LocalDate) -> Date { d.noonDate! }

    func testDoneYesterdayIsHiddenDoneTodayIsShownUndoneAlwaysShown() {
        let base = noon(today.adding(days: -10))
        let doneYesterday = Todo(title: "어제 완료", dueDate: today, isDone: true, createdAt: base,
                                 doneAt: noon(today.adding(days: -1)))
        let doneLateYesterday = Todo(title: "어제 밤 완료", dueDate: today, isDone: true, createdAt: base,
                                     doneAt: LocalDate.calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 23, minute: 59))!)
        let doneTodayEarly = Todo(title: "오늘 0시 완료", dueDate: today, isDone: true, createdAt: base,
                                  doneAt: LocalDate.calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 0, minute: 0, second: 1))!)
        let undoneOld = Todo(title: "지난 미완료", dueDate: today.adding(days: -30), createdAt: base)
        let undoneFuture = Todo(title: "다음 달 미완료", dueDate: today.adding(days: 30), createdAt: base)
        let doneNoDate = Todo(title: "doneAt 없는 완료", dueDate: today, isDone: true, createdAt: base, doneAt: nil)

        let titles = TodoOrdering.visible([doneYesterday, doneLateYesterday, doneTodayEarly, undoneOld, undoneFuture, doneNoDate],
                                          today: today).map(\.title)
        XCTAssertFalse(titles.contains("어제 완료"))
        XCTAssertFalse(titles.contains("어제 밤 완료"))
        XCTAssertTrue(titles.contains("오늘 0시 완료"))
        XCTAssertTrue(titles.contains("지난 미완료"))
        XCTAssertTrue(titles.contains("다음 달 미완료"))
        XCTAssertTrue(titles.contains("doneAt 없는 완료"))
        // 정렬은 그대로 (미완료 먼저)
        XCTAssertEqual(titles.prefix(2), ["지난 미완료", "다음 달 미완료"])
    }

    func testHiddenItemsStayInFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DoItTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("todos.json")
        let store = TodoStore(fileURL: url)
        var clock = noon(today.adding(days: -1))
        store.now = { clock }
        store.refreshToday()
        let t = try XCTUnwrap(store.add(title: "어제 한 일", dueDate: today.adding(days: -1)))
        store.toggleDone(id: t.id)          // 어제 완료
        XCTAssertEqual(store.visibleTodos.count, 1, "완료한 날에는 보임")
        var dayChanged = 0
        store.onTodayChanged = { dayChanged += 1 }
        clock = noon(today)
        store.refreshToday()                // 날짜가 바뀜
        XCTAssertEqual(dayChanged, 1)
        XCTAssertEqual(store.visibleTodos.count, 0, "다음 날 숨김")
        XCTAssertEqual(store.todos.count, 1, "저장소(파일)에는 남아 있음")
        store.flushPendingSave()
    }

    // MARK: 삭제 (PRD F7)

    func testDeleteThenReload() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DoItTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("todos.json")
        let store = TodoStore(fileURL: url)
        let a = try XCTUnwrap(store.add(title: "지울 것", dueDate: today))
        store.add(title: "남길 것", dueDate: today)
        store.flushPendingSave()
        store.delete(id: a.id)
        XCTAssertTrue(store.hasPendingSave, "삭제도 저장 대기")
        store.delete(id: UUID())            // 없는 id는 무시
        store.flushPendingSave()

        let reloaded = TodoStore(fileURL: url)
        reloaded.load()
        XCTAssertEqual(reloaded.todos.map(\.title), ["남길 것"])
    }

    // MARK: 패널 높이 (PRD F4)

    private let notch: CGFloat = 32      // 맥북 실제 노치 높이
    private let screen: CGFloat = 956    // 맥북 Air 13" 화면 높이 (pt)

    func testHeightForEmptyListIsMinimum() {
        let h = PanelLayout.bodyHeight(rowCount: 0, datePickerOpen: false, notchHeight: notch, screenHeight: screen)
        // T-011: 노치 띠 32(머리줄 포함) + 8 + 입력 34 + 8 + 빈 목록 44 + 아래 10
        XCTAssertEqual(h, 136)
    }

    func testHeightGrowsWithRows() {
        let one = PanelLayout.bodyHeight(rowCount: 1, datePickerOpen: false, notchHeight: notch, screenHeight: screen)
        let three = PanelLayout.bodyHeight(rowCount: 3, datePickerOpen: false, notchHeight: notch, screenHeight: screen)
        // 1행: 목록 36 + 4 = 40 → 빈 목록(44)보다 작아 최소 높이
        XCTAssertEqual(one, 136)
        // 3행: 36*3 + 2*2 + 4 = 116 → 고정 92 + 116
        XCTAssertEqual(three, 208)
        XCTAssertEqual(PanelLayout.bodyHeight(rowCount: 4, datePickerOpen: false, notchHeight: notch, screenHeight: screen) - three,
                       PanelLayout.rowHeight + PanelLayout.rowSpacing, "한 행마다 38pt씩")
    }

    func testHeightIsCappedForManyRows() {
        // 맥북: 956 * 0.45 = 430 < 480
        XCTAssertEqual(PanelLayout.maxHeight(screenHeight: 956), 430)
        // 큰 화면: 상한 480
        XCTAssertEqual(PanelLayout.maxHeight(screenHeight: 1440), 480)
        let many = PanelLayout.bodyHeight(rowCount: 50, datePickerOpen: false, notchHeight: notch, screenHeight: screen)
        XCTAssertEqual(many, 430, "최대를 넘으면 최대 높이 (목록만 스크롤)")
        let fhd = PanelLayout.bodyHeight(rowCount: 50, datePickerOpen: false, notchHeight: 31, screenHeight: 1080)
        XCTAssertEqual(fhd, 480)
    }

    func testHeightWithDatePickerOpen() {
        let closed = PanelLayout.bodyHeight(rowCount: 3, datePickerOpen: false, notchHeight: notch, screenHeight: screen)
        let open = PanelLayout.bodyHeight(rowCount: 3, datePickerOpen: true, notchHeight: notch, screenHeight: screen)
        XCTAssertEqual(open - closed, PanelLayout.sectionSpacing + PanelLayout.datePickerHeight)
        // 날짜 영역이 열려 있어도 최대 높이는 넘지 않는다
        let manyOpen = PanelLayout.bodyHeight(rowCount: 50, datePickerOpen: true, notchHeight: notch, screenHeight: screen)
        XCTAssertEqual(manyOpen, 430)
        // 최대 높이 안에서 날짜 영역 + 입력 + 빈 목록이 들어간다
        let emptyOpen = PanelLayout.bodyHeight(rowCount: 0, datePickerOpen: true, notchHeight: notch, screenHeight: screen)
        XCTAssertLessThanOrEqual(emptyOpen, 430)
    }

    // MARK: 날짜 버튼 문구 (PRD F5)

    func testDueDateLabel() {
        XCTAssertEqual(DueDateLabel.text(for: today, today: today), "오늘")
        XCTAssertEqual(DueDateLabel.text(for: today.adding(days: 1), today: today), "내일")
        XCTAssertEqual(DueDateLabel.text(for: LocalDate(year: 2026, month: 11, day: 14), today: today), "11/14(토)")
        XCTAssertEqual(DueDateLabel.text(for: LocalDate(year: 2026, month: 11, day: 13), today: today), "11/13(금)")
        XCTAssertEqual(DueDateLabel.text(for: today.adding(days: -1), today: today), "11/6(금)", "지난 날짜도 날짜로 표시")
    }
}

/// T-004 날짜 선택 영역 상태 전환
final class DatePickerStateTests: XCTestCase {
    private func editingMachine() -> NotchStateMachine {
        var m = NotchStateMachine()
        _ = m.handle(.turnOn)
        _ = m.handle(.mouseEntered)
        _ = m.handle(.peekElapsed(token: m.peekToken))
        _ = m.handle(.inputFocusGained)
        return m
    }

    func testOpenPickerFocusesInputAndExitKeepsExpanded() {
        var m = NotchStateMachine()
        _ = m.handle(.turnOn)
        _ = m.handle(.mouseEntered)
        _ = m.handle(.peekElapsed(token: m.peekToken))
        let effects = m.handle(.datePickerToggled)
        XCTAssertEqual(effects, [.setDatePicker(open: true), .focusInput])
        XCTAssertTrue(m.datePickerOpen)
        _ = m.handle(.inputFocusGained)   // focusInput 결과
        XCTAssertEqual(m.mode, .editing)
        _ = m.handle(.mouseExited(spurious: false))
        XCTAssertEqual(m.mode, .editing, "날짜 영역이 열려 있으면 이탈해도 유지")
        XCTAssertTrue(m.datePickerOpen)
    }

    func testPickerOpenWithoutEditingStillHoldsOnExit() {
        // 입력창 포커스가 (아직) 안 된 상태에서도 날짜 영역이 열려 있으면 접지 않는다
        var m = NotchStateMachine()
        _ = m.handle(.turnOn)
        _ = m.handle(.mouseEntered)
        _ = m.handle(.peekElapsed(token: m.peekToken))
        _ = m.handle(.datePickerToggled)
        _ = m.handle(.mouseExited(spurious: false))
        XCTAssertEqual(m.mode, .expanded)
        // 닫으면, 마우스가 밖이니 일반 이탈 규칙대로 접힌다
        let effects = m.handle(.datePickerToggled)
        XCTAssertEqual(m.mode, .idle)
        XCTAssertEqual(effects.first, .setDatePicker(open: false))
        XCTAssertTrue(effects.contains { if case .startCollapse = $0 { return true } else { return false } })
    }

    func testOpenIgnoredWhenMouseOutside() {
        var m = NotchStateMachine()
        _ = m.handle(.turnOn)
        XCTAssertEqual(m.handle(.datePickerToggled), [])
        XCTAssertFalse(m.datePickerOpen)
    }

    func testEscapeTwoSteps() {
        var m = editingMachine()
        _ = m.handle(.datePickerToggled)
        _ = m.handle(.mouseExited(spurious: false))
        let first = m.handle(.escape)
        XCTAssertEqual(first, [.setDatePicker(open: false), .focusInput], "Esc 1번째: 날짜 영역만 닫고 입력창으로")
        XCTAssertEqual(m.mode, .editing)
        XCTAssertFalse(m.datePickerOpen)
        _ = m.handle(.escape)
        XCTAssertEqual(m.mode, .idle, "Esc 2번째: 기존 Esc 동작(접힘)")
    }

    func testFocusMovingToCalendarKeepsEditing() {
        var m = editingMachine()
        _ = m.handle(.datePickerToggled)
        XCTAssertEqual(m.handle(.inputFocusLost), [], "달력을 누르면 입력창 포커스가 빠지지만 편집은 계속")
        XCTAssertEqual(m.mode, .editing)
        let effects = m.handle(.datePicked)
        XCTAssertEqual(effects, [.setDatePicker(open: false), .focusInput], "날짜를 고르면 닫고 입력창으로")
        XCTAssertEqual(m.handle(.inputFocusGained), [], "이미 편집 중이면 그대로")
        XCTAssertEqual(m.mode, .editing)
    }

    func testClickOutsideWithPickerOpenCollapsesAndCloses() {
        var m = editingMachine()
        _ = m.handle(.datePickerToggled)
        _ = m.handle(.mouseExited(spurious: false))
        let effects = m.handle(.panelResignedKey)
        XCTAssertEqual(m.mode, .idle, "닫힘 후 마우스 밖 → 접힘")
        XCTAssertFalse(m.datePickerOpen)
        XCTAssertTrue(effects.contains(.setDatePicker(open: false)))
    }

    func testEnterClosesPicker() {
        var m = editingMachine()
        _ = m.handle(.datePickerToggled)
        let effects = m.handle(.submit(hasText: true))
        XCTAssertEqual(effects.first, .addTodo)
        XCTAssertTrue(effects.contains(.setDatePicker(open: false)))
        XCTAssertFalse(m.datePickerOpen)
        XCTAssertEqual(m.mode, .expanded, "마우스가 안이라 펼친 채")
    }

    func testTurnOffClosesPicker() {
        var m = editingMachine()
        _ = m.handle(.datePickerToggled)
        _ = m.handle(.turnOff)
        XCTAssertFalse(m.datePickerOpen)
        XCTAssertEqual(m.handle(.datePickerToggled), [], "off에서는 무시")
    }
}
