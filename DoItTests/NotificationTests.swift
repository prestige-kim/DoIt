import XCTest
@testable import DoIt

/// T-005 노치 알림: 계획(순수), 스케줄러(가짜 타이머), 상태 머신 알림 전환, 종료 시 대신 예약(가짜 알림 센터)
/// 모두 임시 폴더·임시 UserDefaults, 실제 알림 센터·실제 사용자 파일 없음
@MainActor
final class NotificationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let today = LocalDate(year: 2026, month: 11, day: 8)

    override func setUp() {
        super.setUp()
        suiteName = "DoItNotificationTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: 도우미

    private func at(_ day: LocalDate, _ hour: Int, _ minute: Int = 0) -> Date {
        LocalDate.calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: hour, minute: minute))!
    }

    private func todo(_ title: String, _ day: LocalDate, done: Bool = false, created: Date? = nil) -> Todo {
        var t = Todo(title: title, dueDate: day, createdAt: created ?? at(today.adding(days: -1), 12))
        t.isDone = done
        return t
    }

    private func lms(_ n: Int, _ day: LocalDate, title: String? = nil, course: String? = "컴퓨터구조(Computer Architecture) 02분반") -> LmsItem {
        LmsItem(uid: "event-assignment-\(n)", title: title ?? "HW\(n)", courseName: course, dueDate: day, dueTime: nil)
    }

    // MARK: ReminderPlanner

    func testSummaryPutsLmsFirstWithShortCourseAndCountsRest() throws {
        let r = try XCTUnwrap(ReminderPlanner.reminder(
            for: today,
            todos: [todo("보고서", today, created: at(today.adding(days: -2), 12)), todo("빨래", today)],
            lms: [lms(3, today), lms(4, today, title: "퀴즈", course: nil)],
            checked: [:], kinds: ReminderKinds(), createdBefore: nil))
        XCTAssertEqual(r.content.title, "오늘 마감 4개")
        XCTAssertEqual(r.content.body, "HW3 [컴퓨터구조 02분반], 퀴즈, 보고서 외 1개")
        XCTAssertTrue(r.content.includesLms)
        XCTAssertEqual(r.identifier, "doit-day-20261108")
        XCTAssertEqual(r.fireDate, at(today, 9))
    }

    func testSummaryExclusions() {
        // 완료한 할 일, 체크한 LMS는 빠진다 → 남는 것 없음
        XCTAssertNil(ReminderPlanner.reminder(for: today, todos: [todo("끝", today, done: true)], lms: [lms(1, today)],
                                              checked: ["event-assignment-1": Date()], kinds: ReminderKinds(), createdBefore: nil))
        // 꺼진 종류
        let onlyTodos = ReminderPlanner.reminder(for: today, todos: [todo("할 일", today)], lms: [lms(1, today)],
                                                 checked: [:], kinds: ReminderKinds(todos: true, lms: false), createdBefore: nil)
        XCTAssertEqual(onlyTodos?.content.count, 1)
        XCTAssertEqual(onlyTodos?.content.includesLms, false, "내 할 일만이면 초록 점")
        XCTAssertNil(ReminderPlanner.reminder(for: today, todos: [todo("할 일", today)], lms: [],
                                              checked: [:], kinds: ReminderKinds(todos: false, lms: true), createdBefore: nil))
        // 9:00 이후에 만든 오늘 마감 할 일은 알리지 않음
        let late = todo("늦게 추가", today, created: at(today, 10))
        XCTAssertNil(ReminderPlanner.reminder(for: today, todos: [late], lms: [], checked: [:],
                                              kinds: ReminderKinds(), createdBefore: at(today, 9)))
    }

    func testPlanSkipsPassedNineAndCoversThirtyDays() {
        let items = [todo("오늘", today), todo("내일", today.adding(days: 1)), todo("29일 뒤", today.adding(days: 29)),
                     todo("30일 뒤", today.adding(days: 30))]
        let before = ReminderPlanner.plan(todos: items, lms: [], checked: [:], kinds: ReminderKinds(), now: at(today, 8, 59))
        XCTAssertEqual(before.map(\.day), [today, today.adding(days: 1), today.adding(days: 29)], "9시 전이면 오늘 포함, 30일치까지")
        let after = ReminderPlanner.plan(todos: items, lms: [], checked: [:], kinds: ReminderKinds(), now: at(today, 9, 0))
        XCTAssertEqual(after.first?.day, today.adding(days: 1), "9:00이 지나면(같으면) 오늘은 빠짐")
    }

    func testPlanAcrossMonthEnd() {
        let oct31 = LocalDate(year: 2026, month: 10, day: 31)
        let nov1 = LocalDate(year: 2026, month: 11, day: 1)
        let plan = ReminderPlanner.plan(todos: [todo("a", oct31), todo("b", nov1)], lms: [], checked: [:],
                                        kinds: ReminderKinds(), now: at(oct31, 7))
        XCTAssertEqual(plan.map(\.identifier), ["doit-day-20261031", "doit-day-20261101"])
        XCTAssertEqual(plan.last?.fireDate, at(nov1, 9))
    }

    func testPreviewText() {
        let r = ReminderPlanner.reminder(for: LocalDate(year: 2026, month: 11, day: 10), todos: [todo("a", LocalDate(year: 2026, month: 11, day: 10)), todo("b", LocalDate(year: 2026, month: 11, day: 10))],
                                         lms: [], checked: [:], kinds: ReminderKinds(), createdBefore: nil)
        XCTAssertEqual(ReminderPlanner.previewText(r), "다음 알림: 11/10(화) 09:00 · 2개")
        XCTAssertTrue(ReminderPlanner.previewText(nil).hasPrefix("다음 알림: 없음"))
    }

    // MARK: NotchAlertScheduler (가짜 타이머)

    private final class FakeTimerFactory: OneShotTimerFactory {
        final class FakeTimer: OneShotTimer {
            let date: Date
            let handler: @MainActor () -> Void
            var cancelled = false
            var fired = false
            init(date: Date, handler: @escaping @MainActor () -> Void) { self.date = date; self.handler = handler }
            func cancel() { cancelled = true }
        }
        var all: [FakeTimer] = []
        var active: [FakeTimer] { all.filter { !$0.cancelled && !$0.fired } }

        func schedule(at date: Date, _ handler: @escaping @MainActor () -> Void) -> OneShotTimer {
            let t = FakeTimer(date: date, handler: handler)
            all.append(t)
            return t
        }

        @MainActor func fireActive() {
            guard let t = active.first else { return }
            t.fired = true
            t.handler()
        }
    }

    private final class Box {
        var todos: [Todo] = []
        var lms: [LmsItem] = []
        var checked: [String: Date] = [:]
        var now: Date
        var shown: [NotchAlertContent] = []
        init(now: Date) { self.now = now }
    }

    private func makeScheduler(_ box: Box, timers: FakeTimerFactory) -> NotchAlertScheduler {
        let settings = AlertSettings(defaults: defaults)
        let s = NotchAlertScheduler(settings: settings, defaults: defaults, timerFactory: timers) {
            .init(todos: box.todos, lms: box.lms, checked: box.checked)
        }
        s.now = { box.now }
        s.present = { box.shown.append($0) }
        settings.onChange = { [weak s] in s?.reschedule() }
        return s
    }

    func testAlwaysAtMostOneTimerAndNextTimeIsExact() {
        let box = Box(now: at(today, 8))
        box.todos = [todo("오늘", today), todo("모레", today.adding(days: 2))]
        let timers = FakeTimerFactory()
        let s = makeScheduler(box, timers: timers)
        s.reschedule()
        XCTAssertEqual(timers.active.count, 1)
        XCTAssertEqual(timers.active.first?.date, at(today, 9))
        // 여러 번 재설정해도 항상 1개
        for _ in 0..<5 { s.reschedule() }
        XCTAssertEqual(timers.active.count, 1, "동시에 2개 이상 걸지 않음")
        s.settings.todos = false  // 설정 변경 → 재설정 → 대상 없음
        XCTAssertEqual(timers.active.count, 0)
        XCTAssertNil(s.nextReminder)
        s.settings.todos = true
        XCTAssertEqual(timers.active.count, 1)
    }

    func testFireShowsOnceRecordsAndRearmsNext() {
        let box = Box(now: at(today, 8))
        box.todos = [todo("오늘", today), todo("모레", today.adding(days: 2))]
        let timers = FakeTimerFactory()
        let s = makeScheduler(box, timers: timers)
        s.reschedule()
        box.now = at(today, 9)
        timers.fireActive()
        XCTAssertEqual(box.shown.map(\.title), ["오늘 마감 1개"])
        XCTAssertEqual(s.lastShownDay, today)
        XCTAssertEqual(timers.active.count, 1)
        XCTAssertEqual(timers.active.first?.date, at(today.adding(days: 2), 9), "울리면 다음 1개를 다시 건다")
        // 같은 날 깨어남 처리 → 이미 보였으니 다시 안 보임 (하루 1번)
        s.catchUp()
        XCTAssertEqual(box.shown.count, 1)
    }

    func testCatchUpOnWakeAfterNineOnlyOnce() {
        let box = Box(now: at(today, 8))
        box.todos = [todo("오늘", today)]
        let s = makeScheduler(box, timers: FakeTimerFactory())
        s.catchUp()
        XCTAssertTrue(box.shown.isEmpty, "9시 전에는 보충하지 않음")
        box.now = at(today, 11)  // 맥을 덮어뒀다 9시 이후 엶
        s.catchUp()
        s.catchUp()
        XCTAssertEqual(box.shown.count, 1, "열 때 1번")
        // 다음 날은 다시
        box.todos.append(todo("내일", today.adding(days: 1)))
        box.now = at(today.adding(days: 1), 10)
        s.catchUp()
        XCTAssertEqual(box.shown.count, 2)
    }

    func testPausedDoesNotShowOrRecord() {
        let box = Box(now: at(today, 10))
        box.todos = [todo("오늘", today)]
        let s = makeScheduler(box, timers: FakeTimerFactory())
        s.settings.paused = true
        s.catchUp()
        XCTAssertTrue(box.shown.isEmpty)
        XCTAssertNil(s.lastShownDay, "일시 중지 중에는 표시한 것으로 기록하지 않음")
        XCTAssertEqual(s.sendTest(), .paused)
        s.settings.paused = false
        s.catchUp()
        XCTAssertEqual(box.shown.count, 1)
    }

    func testLateTimerForPastDayIsSkipped() {
        let box = Box(now: at(today, 8))
        box.todos = [todo("오늘", today)]
        let timers = FakeTimerFactory()
        let s = makeScheduler(box, timers: timers)
        s.reschedule()
        box.now = at(today.adding(days: 1), 7)  // 하루 넘게 잠자다 늦게 울림
        timers.fireActive()
        XCTAssertTrue(box.shown.isEmpty, "지난 날 알림은 건너뜀")
    }

    // MARK: 상태 머신 — 알림 전환

    private struct Harness {
        var m = NotchStateMachine()
        var log: [NotchStateMachine.Effect] = []
        var mouseOnNotchAfterShrink = false
        var lastAlertToken: Int?
        var lastCollapseToken: Int?
        /// 이탈 유예(T-008)가 자동으로 끝나게 할지
        var autoExitGrace = true
        var lastExitGraceToken: Int?
        var lastPeekToken: Int?

        @discardableResult
        mutating func send(_ e: NotchStateMachine.Event) -> [NotchStateMachine.Effect] {
            let effects = m.handle(e)
            log += effects
            for effect in effects {
                switch effect {
                case .showAlert(let t): lastAlertToken = t
                case .startCollapse(let t): lastCollapseToken = t
                case .schedulePeek(let t): lastPeekToken = t
                case .queryMouseInside(let t): send(.mouseCheckResult(token: t, inside: mouseOnNotchAfterShrink))
                case .scheduleExitGrace(let t):
                    // 기본: 유예(0.1초) 동안 다시 들어오지 않음 → 바로 경과를 보낸다. 유예 중 동작을 볼 때는 false
                    lastExitGraceToken = t
                    if autoExitGrace { send(.exitGraceElapsed(token: t)) }
                default: break
                }
            }
            return effects
        }

        /// 5초 경과(또는 ×) → 줄임 애니메이션 끝
        mutating func dismissAndFinish() {
            let t = lastAlertToken ?? -1
            send(.alertDismiss(token: t))
            send(.alertHideFinished(token: t))
        }

        mutating func toIdle() {
            send(.turnOn)
            send(.peekElapsed(token: lastPeekToken ?? -1))
            send(.collapseAnimationFinished(token: lastCollapseToken ?? -1))
        }
    }

    func testAlertFromIdleShowsThenReturnsToIdle() {
        var h = Harness()
        h.toIdle()
        XCTAssertEqual(h.m.mode, .idle)
        let effects = h.send(.alertArrived)
        XCTAssertEqual(h.m.mode, .alert)
        XCTAssertEqual(effects, [.showAlert(token: h.lastAlertToken!)])
        h.dismissAndFinish()
        XCTAssertEqual(h.m.mode, .idle)
        XCTAssertTrue(h.log.contains(.hideAlert(token: h.lastAlertToken!)))
        XCTAssertEqual(h.log.last, .resignKey, "줄인 뒤 마우스 확인 → 밖이면 평소처럼")
        XCTAssertTrue(h.m.isOn)
    }

    func testCloseButtonClosesEvenWhileHoveringAndStaleTimeoutIgnored() {
        var h = Harness()
        h.toIdle()
        h.send(.alertArrived)
        let first = h.lastAlertToken!
        h.send(.mouseEntered)  // × 를 누르러 마우스를 올림 → 펼치지 않음
        XCTAssertEqual(h.m.mode, .alert)
        XCTAssertEqual(h.send(.alertClose), [.hideAlert(token: first)], "× 는 마우스가 위에 있어도 바로 닫음")
        h.send(.alertHideFinished(token: first))
        XCTAssertEqual(h.m.mode, .idle)
        // 나중에 도착한 5초 지연은 무시
        XCTAssertEqual(h.send(.alertDismiss(token: first)), [])
        XCTAssertEqual(h.m.mode, .idle)
    }

    func testHoverDoesNotExpandAndDefersTimeoutUntilExit() {
        var h = Harness()
        h.toIdle()
        h.send(.alertArrived)
        let token = h.lastAlertToken!
        XCTAssertEqual(h.send(.mouseEntered), [], "올리기만 해서는 펼치지 않음 (2026-11-08 사용자 결정)")
        XCTAssertEqual(h.m.mode, .alert)
        XCTAssertEqual(h.send(.alertDismiss(token: token)), [], "읽는 중에는 5초 닫힘을 미룸")
        XCTAssertEqual(h.m.mode, .alert)
        XCTAssertEqual(h.send(.mouseExited(spurious: false)), [.hideAlert(token: token)], "나가면 닫힘")
        h.send(.alertHideFinished(token: token))
        XCTAssertEqual(h.m.mode, .idle)
    }

    func testTapDuringAlertExpandsToListToday() {
        var t = Harness()
        t.toIdle()
        t.send(.alertArrived)
        t.send(.mouseEntered)
        XCTAssertEqual(t.send(.alertTapped), [.removeAlertNow, .resetPanelView, .expand])
        XCTAssertEqual(t.m.mode, .expanded)
        // 남은 5초 지연은 무시
        XCTAssertEqual(t.send(.alertDismiss(token: t.lastAlertToken!)), [])
    }

    func testAlertWhileOffShowsAndReturnsToOff() {
        var h = Harness()
        XCTAssertEqual(h.m.mode, .off)
        let effects = h.send(.alertArrived)
        XCTAssertEqual(effects.first, .showPanel)
        XCTAssertEqual(h.m.mode, .alert)
        XCTAssertFalse(h.m.isOn, "OFF에서 뜬 알림 중에도 메뉴는 '켜기'")
        h.dismissAndFinish()
        XCTAssertEqual(h.m.mode, .off)
        XCTAssertEqual(h.log.last, .hideImmediately)
        // OFF 규칙: hover 무시
        XCTAssertEqual(h.send(.mouseEntered), [])
    }

    func testAlertWhileOffTapExpandsThenCollapseReturnsToOff() {
        var h = Harness()
        h.send(.alertArrived)
        h.send(.mouseEntered)
        XCTAssertEqual(h.m.mode, .alert)
        h.send(.alertTapped)
        XCTAssertEqual(h.m.mode, .expanded)
        XCTAssertFalse(h.m.isOn)
        h.send(.mouseExited(spurious: false))
        XCTAssertEqual(h.m.mode, .idle)
        h.send(.collapseAnimationFinished(token: h.lastCollapseToken!))
        XCTAssertEqual(h.m.mode, .off, "접히면 다시 OFF")
        XCTAssertEqual(Array(h.log.suffix(2)), [.shrinkFrame, .hideImmediately])
        XCTAssertEqual(h.send(.mouseEntered), [])
    }

    func testReopenDuringAlertIsIgnored() {
        var h = Harness()
        h.send(.turnOn); h.send(.peekElapsed(token: h.lastPeekToken!)); h.send(.collapseAnimationFinished(token: h.lastCollapseToken!))
        h.send(.alertArrived)
        XCTAssertEqual(h.m.mode, .alert)
        XCTAssertEqual(h.send(.reopened), [], "알림이 보이는 중 다시 열기는 무시")
        XCTAssertEqual(h.m.mode, .alert)
    }

    func testTurnOnDuringOffAlertBecomesNormalOn() {
        var h = Harness()
        h.send(.alertArrived)
        let effects = h.send(.turnOn)
        XCTAssertEqual(effects.first, .removeAlertNow)
        XCTAssertTrue(effects.contains(.expand))
        XCTAssertTrue(h.m.isOn)
        XCTAssertEqual(h.m.mode, .expanded)
    }

    func testTurnOffDuringAlert() {
        var h = Harness()
        h.toIdle()
        h.send(.alertArrived)
        XCTAssertEqual(h.send(.turnOff), [.removeAlertNow, .hideImmediately])
        XCTAssertEqual(h.m.mode, .off)
    }

    func testAlertWhileExpandedOrEditingHighlightsInPanel() {
        var h = Harness()
        h.toIdle()
        h.send(.mouseEntered)
        XCTAssertEqual(h.m.mode, .expanded)
        XCTAssertEqual(h.send(.alertArrived), [.highlightInPanel])
        h.send(.inputFocusGained)
        XCTAssertEqual(h.m.mode, .editing)
        XCTAssertEqual(h.send(.alertArrived), [.highlightInPanel], "입력 중에도 노치 알림 대신 패널 강조")
        XCTAssertEqual(h.m.mode, .editing, "입력 방해 없음")
    }

    func testNewAlertWhileShowingRestartsTimer() {
        var h = Harness()
        h.toIdle()
        h.send(.alertArrived)
        let first = h.lastAlertToken!
        h.send(.alertArrived)
        XCTAssertNotEqual(h.lastAlertToken, first)
        XCTAssertEqual(h.send(.alertDismiss(token: first)), [], "앞 알림의 5초는 무시")
        XCTAssertEqual(h.m.mode, .alert)
    }

    // MARK: 종료 시 대신 예약 (가짜 알림 센터)

    private final class FakeCenter: LocalNotificationCenter {
        var pending: [String] = []
        var added: [(String, String, String, DateComponents)] = []
        var status: AlertPermission = .notDetermined
        var requested = 0

        func pendingIdentifiers(_ completion: @escaping ([String]) -> Void) { completion(pending) }
        func removePending(identifiers: [String]) { pending.removeAll { identifiers.contains($0) } }
        func add(identifier: String, title: String, body: String, at components: DateComponents,
                 completion: @escaping (Error?) -> Void) {
            added.append((identifier, title, body, components))
            pending.append(identifier)
            completion(nil)
        }
        func permission(_ completion: @escaping (AlertPermission) -> Void) { completion(status) }
        func requestPermission(_ completion: @escaping (Bool) -> Void) { requested += 1; completion(true) }
    }

    func testTerminateSchedulesPlanAndLaunchRemovesOnlyOurs() {
        let center = FakeCenter()
        center.pending = ["other-app-thing"]
        let notifier = FallbackNotifier(center: center)
        let plan = ReminderPlanner.plan(todos: [todo("내일", today.adding(days: 1)), todo("모레", today.adding(days: 2))],
                                        lms: [], checked: [:], kinds: ReminderKinds(), now: at(today, 20))
        XCTAssertEqual(notifier.appWillTerminate(plan: plan), 2)
        XCTAssertEqual(center.added.map(\.0), ["doit-day-20261109", "doit-day-20261110"])
        XCTAssertEqual(center.added.first?.1, "오늘 마감 1개")
        XCTAssertEqual(center.added.first?.3.hour, 9)
        XCTAssertEqual(center.added.first?.3.day, 9)

        center.status = .denied
        notifier.appLaunched()
        XCTAssertEqual(center.pending, ["other-app-thing"], "doit-day- 만 지움")
        XCTAssertEqual(center.requested, 0, "거부·허용이면 다시 묻지 않음")
        center.status = .notDetermined
        notifier.appLaunched()
        XCTAssertEqual(center.requested, 1, "미결정일 때만 1번 요청")
    }
}
