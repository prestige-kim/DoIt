import Foundation

/// 노치 알림 한 번에 보일 내용 (PRD F8, DESIGN.md 노치 알림)
struct NotchAlertContent: Equatable {
    /// `오늘 마감 n개`
    let title: String
    /// `HW3 [컴퓨터구조], 보고서 외 2개`
    let body: String
    /// LMS 과제가 들어 있으면 파란 점, 내 할 일만이면 초록 점
    let includesLms: Bool
    let count: Int
}

/// 날짜별 9:00 요약 알림 1개
struct DayReminder: Equatable {
    let day: LocalDate
    /// 그날 09:00 (로컬)
    let fireDate: Date
    let content: NotchAlertContent
    /// 종료 시 대신 예약하는 macOS 알림의 id (`doit-day-YYYYMMDD`)
    var identifier: String { ReminderPlanner.identifier(for: day) }
}

/// 알림 종류 켜기/끄기 (설정 '알림')
struct ReminderKinds: Equatable {
    var todos: Bool = true
    var lms: Bool = true
}

/// 알림 계획 — 순수 함수 (ARCHITECTURE §3.6). 노치 알림과 종료 시 대신 예약이 **같은 계획**을 쓴다
enum ReminderPlanner {
    /// 알림 시각 (PRD F8: 9:00 고정)
    static let hour = 9
    /// 앞으로 며칠치
    static let horizonDays = 30
    /// 본문에 이름을 보일 최대 개수
    static let maxNamesInBody = 3
    static let identifierPrefix = "doit-day-"

    static func identifier(for day: LocalDate) -> String {
        identifierPrefix + String(format: "%04d%02d%02d", day.year, day.month, day.day)
    }

    /// 그날 09:00 (로컬 달력)
    static func fireDate(for day: LocalDate, calendar: Calendar = LocalDate.calendar) -> Date? {
        calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: hour, minute: 0))
    }

    /// 앞으로 30일치 요약. **이미 지난 9:00은 뺀다** (오늘 9:00이 지났으면 오늘도 빠짐)
    /// - lms: `lms.json` 현재 목록만 (history는 넣지 않는다)
    static func plan(todos: [Todo], lms: [LmsItem], checked: [String: Date], kinds: ReminderKinds,
                     now: Date, calendar: Calendar = LocalDate.calendar) -> [DayReminder] {
        let today = LocalDate(now)
        return (0..<horizonDays).compactMap { offset -> DayReminder? in
            let day = today.adding(days: offset)
            guard let fire = fireDate(for: day, calendar: calendar), fire > now else { return nil }
            return reminder(for: day, todos: todos, lms: lms, checked: checked, kinds: kinds, createdBefore: nil, calendar: calendar)
        }
    }

    /// 다음 알림 1개 (설정 미리보기·타이머)
    static func next(todos: [Todo], lms: [LmsItem], checked: [String: Date], kinds: ReminderKinds,
                     now: Date, calendar: Calendar = LocalDate.calendar) -> DayReminder? {
        plan(todos: todos, lms: lms, checked: checked, kinds: kinds, now: now, calendar: calendar).first
    }

    /// 그날의 요약 (시각과 관계없이). 항목이 없으면 nil
    /// - Parameter createdBefore: 주면 그 시각 이후에 만든 내 할 일은 뺀다 (9:00이 지난 뒤 오늘 마감으로 추가한 할 일은 알리지 않음, PRD F8)
    static func reminder(for day: LocalDate, todos: [Todo], lms: [LmsItem], checked: [String: Date],
                         kinds: ReminderKinds, createdBefore: Date?, calendar: Calendar = LocalDate.calendar) -> DayReminder? {
        let myTodos = kinds.todos
            ? TodoOrdering.sorted(todos.filter { t in
                !t.isDone && t.dueDate == day && (createdBefore.map { t.createdAt < $0 } ?? true)
            })
            : []
        let myLms = kinds.lms
            ? lms.filter { $0.dueDate == day && checked[$0.uid] == nil }.sorted(by: lmsOrder)
            : []
        let count = myTodos.count + myLms.count
        guard count > 0, let fire = fireDate(for: day, calendar: calendar) else { return nil }

        // LMS 먼저(마감순), 그다음 내 할 일
        let names = myLms.map(lmsName) + myTodos.map(\.title)
        var body = names.prefix(maxNamesInBody).joined(separator: ", ")
        if names.count > maxNamesInBody { body += " 외 \(names.count - maxNamesInBody)개" }
        let content = NotchAlertContent(title: "오늘 마감 \(count)개", body: body, includesLms: !myLms.isEmpty, count: count)
        return DayReminder(day: day, fireDate: fire, content: content)
    }

    /// `HW3 [컴퓨터구조]` (과목명이 없으면 과제명만)
    static func lmsName(_ item: LmsItem) -> String {
        guard let course = item.courseName else { return item.title }
        return "\(item.title) [\(LmsDisplay.shortCourseName(course))]"
    }

    /// 같은 날 안에서: 시각 있는 것 먼저(이른 순) → 과제명
    private static func lmsOrder(_ a: LmsItem, _ b: LmsItem) -> Bool {
        let at = a.dueTime ?? LocalTime(hour: 24, minute: 0), bt = b.dueTime ?? LocalTime(hour: 24, minute: 0)
        if at != bt { return at < bt }
        if a.title != b.title { return a.title < b.title }
        return a.uid < b.uid
    }

    /// 설정 미리보기: `다음 알림: 11/10(화) 09:00 · 2개`
    static func previewText(_ next: DayReminder?) -> String {
        guard let next else { return "다음 알림: 없음 (30일 안에 마감인 항목이 없어요)" }
        return "다음 알림: \(DueDateLabel.short(next.day)) 09:00 · \(next.content.count)개"
    }

    /// 테스트 알림에 쓸 예시 (보일 할 일이 없을 때)
    static let sampleContent = NotchAlertContent(title: "오늘 마감 2개", body: "예시 과제 [예시 과목], 예시 할 일", includesLms: true, count: 2)
}
