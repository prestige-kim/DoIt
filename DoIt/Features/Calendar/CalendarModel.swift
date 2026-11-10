import Foundation

/// 달력 보기의 계산 (순수 함수, PRD F12, ARCHITECTURE §3.10)
enum CalendarModel {
    /// 그 달 1일
    static func firstOfMonth(_ date: LocalDate) -> LocalDate {
        LocalDate(year: date.year, month: date.month, day: 1)
    }

    static func addingMonths(_ month: LocalDate, _ n: Int) -> LocalDate {
        let first = firstOfMonth(month)
        guard let noon = first.noonDate, let d = LocalDate.calendar.date(byAdding: .month, value: n, to: noon) else { return first }
        return firstOfMonth(LocalDate(d))
    }

    /// 6주 × 7일 = 42칸, **일요일 시작**. 그 달 1일이 들어 있는 주의 일요일부터
    static func monthGrid(_ month: LocalDate) -> [LocalDate] {
        let first = firstOfMonth(month)
        let weekday = first.noonDate.map { LocalDate.calendar.component(.weekday, from: $0) } ?? 1  // 1 = 일요일
        let start = first.adding(days: -(weekday - 1))
        return (0..<42).map { start.adding(days: $0) }
    }

    /// 지난 날짜는 보기 전용 (체크·추가 불가)
    static func isReadOnly(_ date: LocalDate, today: LocalDate) -> Bool { date < today }

    static func title(_ month: LocalDate) -> String { "\(month.year)년 \(month.month)월" }

    // MARK: 날짜별 항목

    struct Entry: Identifiable, Equatable {
        enum Kind: Equatable {
            case todo(UUID)
            case lms(String)
        }
        let kind: Kind
        let title: String
        /// LMS 과목명 원문 (내 할 일은 nil)
        let course: String?
        let isDone: Bool

        var id: String {
            switch kind {
            case .todo(let id): return "todo-\(id.uuidString)"
            case .lms(let uid): return "lms-\(uid)"
            }
        }
        var isLms: Bool { if case .lms = kind { return true } else { return false } }
    }

    /// 그날 마감인 내 할 일 + LMS 과제(현재 + 기록). 완료 안 한 것 먼저 → 내 할 일(생성순) → LMS(과제명순)
    /// 내 할 일은 완료 숨김(F4)과 관계없이 모두 (삭제한 것은 파일에 없으므로 안 보임)
    static func entries(on date: LocalDate, todos: [Todo], lms: [LmsItem], checked: [String: Date]) -> [Entry] {
        let t = TodoOrdering.sorted(todos.filter { $0.dueDate == date })
            .map { Entry(kind: .todo($0.id), title: $0.title, course: nil, isDone: $0.isDone) }
        let l = lms.filter { $0.dueDate == date }
            .sorted { ($0.title, $0.uid) < ($1.title, $1.uid) }
            .map { Entry(kind: .lms($0.uid), title: $0.title, course: $0.courseName, isDone: checked[$0.uid] != nil) }
        let all = t + l
        return all.filter { !$0.isDone } + all.filter(\.isDone)
    }

    // MARK: 날짜 칸의 점

    enum Dot: Equatable {
        /// 내 할 일 (초록)
        case todo(done: Bool)
        /// LMS (파랑)
        case lms(done: Bool)
        /// 지난 날짜의 완료 안 한 LMS (빨강, T-011 DESIGN.md)
        case lmsOverdue
    }

    struct DaySummary: Equatable {
        /// 최대 3개
        var dots: [Dot] = []
        /// 4개 이상이면 `+`
        var hasMore = false
    }

    static let maxDots = 3

    /// 그날의 점: 완료 안 한 것 먼저, 내 할 일(초록) → LMS(파랑), 완료는 흐린 점(35%).
    /// `pastDay`(오늘 이전)면 완료 안 한 LMS는 빨간 점
    static func summary(entries: [Entry], pastDay: Bool = false) -> DaySummary {
        let dots = entries.map { e -> Dot in
            guard e.isLms else { return .todo(done: e.isDone) }
            return pastDay && !e.isDone ? .lmsOverdue : .lms(done: e.isDone)
        }
        return DaySummary(dots: Array(dots.prefix(maxDots)), hasMore: dots.count > maxDots)
    }

    /// 달력 42칸 각각의 점
    /// - Parameter today: 주면 지난 날짜의 완료 안 한 LMS를 빨간 점으로
    static func summaries(grid: [LocalDate], todos: [Todo], lms: [LmsItem], checked: [String: Date],
                          today: LocalDate? = nil) -> [LocalDate: DaySummary] {
        let range = Set(grid)
        let todosByDay = Dictionary(grouping: todos.filter { range.contains($0.dueDate) }, by: \.dueDate)
        let lmsByDay = Dictionary(grouping: lms.filter { range.contains($0.dueDate) }, by: \.dueDate)
        var out: [LocalDate: DaySummary] = [:]
        for day in Set(todosByDay.keys).union(lmsByDay.keys) {
            let past = today.map { day < $0 } ?? false
            out[day] = summary(entries: entries(on: day, todos: todosByDay[day] ?? [], lms: lmsByDay[day] ?? [], checked: checked),
                               pastDay: past)
        }
        return out
    }

    /// 선택한 날짜 제목: `11월 14일 (금)`
    static func dayTitle(_ date: LocalDate) -> String {
        let weekdays = ["일", "월", "화", "수", "목", "금", "토"]
        let w = date.noonDate.map { LocalDate.calendar.component(.weekday, from: $0) } ?? 1
        return "\(date.month)월 \(date.day)일 (\(weekdays[(w - 1) % 7]))"
    }
}
