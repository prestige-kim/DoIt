import Foundation

/// 패널 "LMS" 칸에 무엇을 어떻게 보일지 정하는 순수 함수 (PRD F11, T-007)
enum LmsDisplay {
    /// `lms.json`에 남기는 범위: 오늘 ~ 오늘 + 최대 기간(8주). 마감이 지난 과제는 `lms-history.json`으로 (T-009, PRD F11)
    /// 표시 범위(N주)는 화면에서 다시 거른다 → 기간을 바꿔도 다시 접속하지 않아도 된다.
    static let maxWeeks = 8
    static let minWeeks = 1
    static let defaultWeeks = 2

    static func cacheRange(today: LocalDate) -> ClosedRange<LocalDate> {
        today...today.adding(days: maxWeeks * 7)
    }

    /// 패널에 보일 항목
    /// - 표시 범위: 마감이 오늘 + N주 이하
    /// - 미완료: 마감 다음 날까지 보임(지났으면 빨간색), 그 뒤 숨김
    /// - 체크한 항목: 체크한 날에는 보이고 다음 날부터 숨김
    /// - 정렬: 미완료 먼저 → 마감 날짜 → 시각(시각 없는 항목은 그날 맨 뒤) → 과제명
    static func visible(_ items: [LmsItem], checked: [String: Date], today: LocalDate, weeks: Int) -> [LmsItem] {
        let last = today.adding(days: clampWeeks(weeks) * 7)
        let firstUnchecked = today.adding(days: -1)
        let shown = items.filter { item in
            guard item.dueDate <= last else { return false }
            if let at = checked[item.uid] {
                return !(LocalDate(at) < today)
            }
            return item.dueDate >= firstUnchecked
        }
        return shown.sorted { a, b in
            let ad = checked[a.uid] != nil, bd = checked[b.uid] != nil
            if ad != bd { return !ad }
            if a.dueDate != b.dueDate { return a.dueDate < b.dueDate }
            let at = a.dueTime ?? LocalTime(hour: 24, minute: 0), bt = b.dueTime ?? LocalTime(hour: 24, minute: 0)
            if at != bt { return at < bt }
            if a.title != b.title { return a.title < b.title }
            return a.uid < b.uid
        }
    }

    static func clampWeeks(_ weeks: Int) -> Int { min(maxWeeks, max(minWeeks, weeks)) }

    /// 마감이 지난 미완료인지 (날짜 기준, 빨간색)
    static func isOverdue(_ item: LmsItem, isChecked: Bool, today: LocalDate) -> Bool {
        !isChecked && item.dueDate < today
    }

    /// `D-3`, `D-Day 23:59`, `D+1` (시각이 있으면 뒤에 붙임)
    static func dueLabel(_ item: LmsItem, today: LocalDate) -> String {
        let d = TodoOrdering.dDayLabel(due: item.dueDate, today: today)
        guard let t = item.dueTime else { return d }
        return "\(d) \(t.string)"
    }

    // MARK: T-011 디자인 문구 (DESIGN.md LMS 칸)

    /// LMS 칸 머리 오른쪽: `2주 · 21:20 동기화`. 마지막 성공이 오늘이 아니면 `2주 · 11/7 21:20 동기화`, 없으면 `2주`
    static func headerCaption(weeks: Int, lastSuccess: Date?, now: Date, calendar: Calendar = LocalDate.calendar) -> String {
        let w = "\(clampWeeks(weeks))주"
        guard let at = lastSuccess else { return w }
        let c = calendar.dateComponents([.month, .day, .hour, .minute], from: at)
        let time = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        let sameDay = calendar.isDate(at, inSameDayAs: now)
        return sameDay ? "\(w) · \(time) 동기화" : "\(w) · \(c.month ?? 0)/\(c.day ?? 0) \(time) 동기화"
    }

    /// LMS 행 오른쪽 굵은 글자: 지난 미완료면 `어제 마감`(그 전이면 `n일 전 마감`), 그 외 `D-3`·`D-Day`
    static func dueTitle(_ item: LmsItem, isChecked: Bool, today: LocalDate) -> String {
        let days = item.dueDate.days(from: today)
        if isOverdue(item, isChecked: isChecked, today: today) {
            return days == -1 ? "어제 마감" : "\(-days)일 전 마감"
        }
        return TodoOrdering.dDayLabel(due: item.dueDate, today: today)
    }

    /// LMS 행 오른쪽 작은 글자: `11/12(목)` (시각이 있으면 뒤에 붙임)
    static func dueDetail(_ item: LmsItem) -> String {
        let d = DueDateLabel.short(item.dueDate)
        guard let t = item.dueTime else { return d }
        return "\(d) \(t.string)"
    }

    /// 화면용 짧은 과목명: 괄호 속이 영문(한글 없음, 영문자 있음)이면 괄호째 뺀다. 저장은 원문 그대로 (PRD F11)
    /// 예: `컴퓨터구조(Computer Architecture) 02분반` → `컴퓨터구조 02분반`
    static func shortCourseName(_ name: String) -> String {
        var out = ""
        var i = name.startIndex
        while i < name.endIndex {
            let c = name[i]
            if c == "(" || c == "（" {
                let close: Character = c == "(" ? ")" : "）"
                if let end = name[name.index(after: i)...].firstIndex(of: close) {
                    let inside = name[name.index(after: i)..<end]
                    let hasHangul = inside.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) || (0x3131...0x318E).contains($0.value) }
                    let hasLatin = inside.unicodeScalars.contains { ($0.value >= 0x41 && $0.value <= 0x5A) || ($0.value >= 0x61 && $0.value <= 0x7A) }
                    if hasLatin && !hasHangul {
                        i = name.index(after: end)
                        continue
                    }
                }
            }
            out.append(c)
            i = name.index(after: i)
        }
        let collapsed = out.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return collapsed.isEmpty ? name : collapsed
    }
}
