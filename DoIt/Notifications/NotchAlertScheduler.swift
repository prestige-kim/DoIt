import AppKit
import Observation
import os

private let alertLogger = Logger(subsystem: "com.personal.doit", category: "alert")

// MARK: - 일회성 타이머 (ARCHITECTURE §3.6, §5 예외 D-015)

/// 걸어 둔 타이머 1개
protocol OneShotTimer: AnyObject {
    func cancel()
}

/// "그 시각에 1번" 타이머를 만든다 (테스트는 가짜로 바꿔 개수를 센다)
@MainActor
protocol OneShotTimerFactory: AnyObject {
    func schedule(at date: Date, _ handler: @escaping @MainActor () -> Void) -> OneShotTimer
}

/// 실제 타이머: **wall-clock(`DispatchWallTime`) 일회성 `DispatchSourceTimer`** — 반복 없음(`repeating: .never`).
/// 벽시계 기준이라 잠자기 동안 시각이 지나면 깨어난 뒤 울린다 (그 경우도 하루 1번 기록으로 중복 없음)
@MainActor
final class WallClockTimerFactory: OneShotTimerFactory {
    private final class Handle: OneShotTimer {
        let source: DispatchSourceTimer
        init(_ source: DispatchSourceTimer) { self.source = source }
        func cancel() { source.cancel() }
    }

    func schedule(at date: Date, _ handler: @escaping @MainActor () -> Void) -> OneShotTimer {
        let source = DispatchSource.makeTimerSource(queue: .main)  // D-015: 앱 전체에서 이 1곳만
        let t = date.timeIntervalSince1970
        let spec = timespec(tv_sec: Int(t.rounded(.down)), tv_nsec: Int((t - t.rounded(.down)) * 1_000_000_000))
        source.schedule(wallDeadline: DispatchWallTime(timespec: spec), repeating: .never, leeway: .seconds(1))
        source.setEventHandler { MainActor.assumeIsolated { handler() } }
        source.resume()
        return Handle(source)
    }
}

// MARK: - 알림 설정

/// 설정 '알림' (PRD F8). UserDefaults에 저장, 바뀌면 `onChange` (타이머 재설정)
@MainActor
@Observable
final class AlertSettings {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var onChange: () -> Void = {}

    enum Keys {
        static let todos = "alertTodos"
        static let lms = "alertLms"
        static let paused = "alertPaused"
    }

    /// 내 할 일 마감 알림 (기본 켬)
    var todos: Bool { didSet { defaults.set(todos, forKey: Keys.todos); onChange() } }
    /// LMS 과제 알림 (기본 켬)
    var lms: Bool { didSet { defaults.set(lms, forKey: Keys.lms); onChange() } }
    /// 노치 알림 일시 중지 (기본 끔). 켜져 있으면 표시하지 않고, 표시한 것으로 기록하지도 않는다
    var paused: Bool { didSet { defaults.set(paused, forKey: Keys.paused); onChange() } }

    var kinds: ReminderKinds { ReminderKinds(todos: todos, lms: lms) }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        todos = defaults.object(forKey: Keys.todos) as? Bool ?? true
        lms = defaults.object(forKey: Keys.lms) as? Bool ?? true
        paused = defaults.object(forKey: Keys.paused) as? Bool ?? false
    }
}

// MARK: - 스케줄러

/// 앱 실행 중 노치 알림 (ARCHITECTURE §3.6, D-015)
/// - 다음 알림 시각까지 **일회성 타이머 1개만**. 울리면 표시하고 다음 1개를 다시 건다
/// - 하루 1번: 마지막 표시 날짜를 UserDefaults에 기록
/// - 깨어남·실행 시 오늘 9:00이 지났고 아직 안 보였으면 바로 표시 (`catchUp`)
@MainActor
@Observable
final class NotchAlertScheduler {
    struct Inputs {
        var todos: [Todo]
        var lms: [LmsItem]
        var checked: [String: Date]
    }

    let settings: AlertSettings
    @ObservationIgnored private let inputs: () -> Inputs
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let timerFactory: OneShotTimerFactory
    @ObservationIgnored var now: () -> Date = { Date() }
    @ObservationIgnored var calendar: Calendar = LocalDate.calendar
    /// 노치 알림을 실제로 띄운다 (AppDelegate가 뷰모델로 연결)
    @ObservationIgnored var present: (NotchAlertContent) -> Void = { _ in }

    @ObservationIgnored private var timer: OneShotTimer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// 다음 알림 (설정 미리보기)
    private(set) var nextReminder: DayReminder?
    /// 지금 걸린 타이머 시각 (진단·테스트)
    @ObservationIgnored private(set) var scheduledFireDate: Date?

    static let lastShownKey = "notchAlertLastShownDay"
    /// 테스트 알림까지의 지연 (일회성)
    static let testDelay: TimeInterval = 3

    init(settings: AlertSettings, defaults: UserDefaults = .standard, timerFactory: OneShotTimerFactory,
         inputs: @escaping () -> Inputs) {
        self.settings = settings
        self.defaults = defaults
        self.timerFactory = timerFactory
        self.inputs = inputs
    }

    /// 마지막으로 노치 알림을 보인 날
    var lastShownDay: LocalDate? {
        guard let s = defaults.string(forKey: Self.lastShownKey) else { return nil }
        return LocalDate(string: s)
    }

    // MARK: 계획·타이머

    /// 지금 계획 (종료 시 대신 예약에도 씀)
    func currentPlan() -> [DayReminder] {
        let i = inputs()
        return ReminderPlanner.plan(todos: i.todos, lms: i.lms, checked: i.checked, kinds: settings.kinds, now: now(), calendar: calendar)
    }

    /// 타이머를 다시 건다: 기존 것을 취소하고 다음 시각 1개만 (동시에 2개 이상 없음)
    func reschedule() {
        timer?.cancel()
        timer = nil
        scheduledFireDate = nil
        let next = currentPlan().first
        nextReminder = next
        guard let next else {
            alertLogger.debug("no upcoming alert")
            return
        }
        let day = next.day
        timer = timerFactory.schedule(at: next.fireDate) { [weak self] in self?.fire(day: day) }
        scheduledFireDate = next.fireDate
        alertLogger.debug("next alert \(next.day.string, privacy: .public) 09:00 count=\(next.content.count, privacy: .public)")
    }

    private func fire(day: LocalDate) {
        timer = nil
        scheduledFireDate = nil
        alertLogger.notice("alert timer fired for \(day.string, privacy: .public)")
        // 늦게 울려 날짜가 지났으면 그날 알림은 건너뜀 (깨어남 처리가 오늘 것을 맡는다)
        if LocalDate(now()) == day { showToday() }
        reschedule()
    }

    /// 실행·깨어남: 오늘 9:00이 지났고 오늘 아직 안 보였으면 지금 보인다
    func catchUp() {
        let today = LocalDate(now())
        guard let nine = ReminderPlanner.fireDate(for: today, calendar: calendar), now() >= nine else { return }
        guard lastShownDay != today else { return }
        showToday()
    }

    /// 오늘 요약을 보인다 (하루 1번, 일시 중지면 표시·기록 안 함)
    private func showToday() {
        let today = LocalDate(now())
        guard lastShownDay != today else {
            alertLogger.notice("alert skipped: already shown today")
            return
        }
        guard !settings.paused else {
            alertLogger.notice("alert skipped: paused (not recorded)")
            return
        }
        let i = inputs()
        let nine = ReminderPlanner.fireDate(for: today, calendar: calendar)
        guard let r = ReminderPlanner.reminder(for: today, todos: i.todos, lms: i.lms, checked: i.checked,
                                               kinds: settings.kinds, createdBefore: nine, calendar: calendar) else {
            alertLogger.notice("alert skipped: nothing due today")
            return
        }
        defaults.set(today.string, forKey: Self.lastShownKey)
        alertLogger.notice("alert shown: count=\(r.content.count, privacy: .public)")
        present(r.content)
    }

    // MARK: 테스트 알림 (설정)

    enum TestResult: Equatable { case scheduled, paused }

    /// 3초 뒤 노치 알림 1회 (하루 1번 기록에 넣지 않음). 다음 알림 내용, 없으면 오늘 것, 그것도 없으면 예시 문구
    func sendTest() -> TestResult {
        guard !settings.paused else { return .paused }
        let i = inputs()
        let today = LocalDate(now())
        let content = nextReminder?.content
            ?? ReminderPlanner.reminder(for: today, todos: i.todos, lms: i.lms, checked: i.checked,
                                        kinds: settings.kinds, createdBefore: nil, calendar: calendar)?.content
            ?? ReminderPlanner.sampleContent
        // 일회성 지연 (ARCHITECTURE §5 예외)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.testDelay) { [weak self] in
            guard let self, !self.settings.paused else { return }
            alertLogger.notice("test alert shown")
            self.present(content)
        }
        return .scheduled
    }

    // MARK: 시스템 이벤트 (재설정 시점)

    /// 날짜 변경·깨어남 알림을 받는다 (이벤트 방식, 폴링 없음)
    func startObserving() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reschedule() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                alertLogger.notice("did wake: catch up + reschedule")
                self?.catchUp()
                self?.reschedule()
            }
        })
    }
}
