import Foundation

/// 시각 (시·분만, 로컬 기준). JSON에는 `"HH:mm"` 문자열로 저장한다. (PRD §6 `dueTime`)
struct LocalTime: Hashable, Comparable, Codable, CustomStringConvertible {
    let hour: Int
    let minute: Int

    init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    init?(string: String) {
        let parts = string.split(separator: ":")
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]), (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        self.init(hour: h, minute: m)
    }

    var string: String { String(format: "%02d:%02d", hour, minute) }
    var description: String { string }

    static func < (lhs: LocalTime, rhs: LocalTime) -> Bool {
        (lhs.hour, lhs.minute) < (rhs.hour, rhs.minute)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let value = LocalTime(string: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "시각 형식이 HH:mm이 아님: \(text)")
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }
}

/// LMS 과제 하나 (PRD §6 `LmsItem`). 읽기 전용 캐시 `lms.json`에 저장한다.
/// **과제명·과목명·마감 날짜·시각만** 담는다. 설명·링크·첨부는 파싱 단계에서 버려 여기까지 오지 않는다 (T-007 보안 규칙 3).
struct LmsItem: Identifiable, Codable, Equatable {
    /// `.ics`의 UID (`event-assignment-<번호>`)
    let uid: String
    let title: String
    /// 과목명 원문 (화면에는 `LmsDisplay.shortCourseName`으로 줄여 보여 준다)
    let courseName: String?
    let dueDate: LocalDate
    /// 피드에 시각이 있으면 로컬 시각
    let dueTime: LocalTime?

    var id: String { uid }
}
