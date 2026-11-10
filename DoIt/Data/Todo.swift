import Foundation

/// 시간 없는 날짜 (로컬 기준). JSON에는 `"yyyy-MM-dd"` 문자열로 저장한다. (PRD §6)
/// `Date`로 들고 있으면 시간대가 바뀔 때 날짜가 하루 밀릴 수 있어서 연·월·일만 저장한다.
struct LocalDate: Hashable, Comparable, Codable, CustomStringConvertible {
    let year: Int
    let month: Int
    let day: Int

    /// 날짜 계산에는 항상 그레고리력 + 현재 시간대를 쓴다 (사용자 달력 설정과 무관하게 yyyy-MM-dd가 같도록)
    static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal
    }

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// 주어진 시각이 속한 로컬 날짜
    init(_ date: Date) {
        let c = Self.calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    /// `"yyyy-MM-dd"` 문자열에서 만든다. 형식이 틀리거나 없는 날짜(2월 30일 등)면 nil
    init?(string: String) {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        let candidate = LocalDate(year: y, month: m, day: d)
        guard let date = candidate.noonDate, LocalDate(date) == candidate else { return nil }
        self = candidate
    }

    static func today(now: Date = Date()) -> LocalDate { LocalDate(now) }

    var string: String { String(format: "%04d-%02d-%02d", year, month, day) }
    var description: String { string }

    /// 그날 정오 (일광절약시간 전환일에도 날짜가 흔들리지 않도록 정오 기준)
    var noonDate: Date? {
        Self.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
    }

    /// `other`로부터 며칠 뒤인지 (self - other). 과거면 음수
    func days(from other: LocalDate) -> Int {
        guard let a = other.noonDate, let b = noonDate else { return 0 }
        return Self.calendar.dateComponents([.day], from: a, to: b).day ?? 0
    }

    func adding(days: Int) -> LocalDate {
        guard let base = noonDate, let d = Self.calendar.date(byAdding: .day, value: days, to: base) else { return self }
        return LocalDate(d)
    }

    static func < (lhs: LocalDate, rhs: LocalDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    // MARK: Codable — 문자열 하나로

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let value = LocalDate(string: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "날짜 형식이 yyyy-MM-dd가 아님: \(text)")
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }
}

/// 할 일 하나 (PRD §6)
struct Todo: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    /// 마감일 (시간 없음). 지정하지 않으면 생성한 날짜로 고정
    var dueDate: LocalDate
    var isDone: Bool
    let createdAt: Date
    var updatedAt: Date
    var doneAt: Date?

    init(id: UUID = UUID(), title: String, dueDate: LocalDate, isDone: Bool = false,
         createdAt: Date, updatedAt: Date? = nil, doneAt: Date? = nil) {
        self.id = id
        self.title = title
        self.dueDate = dueDate
        self.isDone = isDone
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.doneAt = doneAt
    }
}

// MARK: - 정렬·D-day (PRD F4)

enum TodoOrdering {
    /// 미완료 먼저 → 마감일 오름차순 → 같은 날은 생성순. 완료 항목은 아래 (완료끼리도 같은 규칙)
    static func sorted(_ todos: [Todo]) -> [Todo] {
        todos.sorted { a, b in
            if a.isDone != b.isDone { return !a.isDone }
            if a.dueDate != b.dueDate { return a.dueDate < b.dueDate }
            if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
            return a.id.uuidString < b.id.uuidString  // 완전히 같으면 순서가 흔들리지 않도록
        }
    }

    /// 패널에 보일 항목 (PRD F4): 완료 항목은 **체크한 다음 날부터 숨긴다** (`doneAt`의 날짜가 오늘보다 이전).
    /// 미완료는 날짜와 관계없이 보인다. 파일에서는 지우지 않는다. `doneAt`이 없는 완료 항목(손으로 고친 파일)은 보인다.
    static func visible(_ todos: [Todo], today: LocalDate) -> [Todo] {
        sorted(todos.filter { todo in
            guard todo.isDone, let doneAt = todo.doneAt else { return true }
            return !(LocalDate(doneAt) < today)
        })
    }

    /// `D-3`(3일 남음), `D-Day`(오늘), `D+2`(2일 지남)
    static func dDayLabel(due: LocalDate, today: LocalDate) -> String {
        let d = due.days(from: today)
        if d == 0 { return "D-Day" }
        return d > 0 ? "D-\(d)" : "D+\(-d)"
    }
}
