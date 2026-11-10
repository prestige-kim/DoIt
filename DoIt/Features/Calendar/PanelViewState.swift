import Foundation

/// 패널이 무엇을 보여 주는지: 화면 종류(목록/달력) · 보던 달 · 선택한 날짜 (PRD F12 "직전 화면 유지", T-011)
/// 순수 값이라 테스트로 고정한다. 언제 바뀌는지:
/// - 접혔다 펼쳐짐 → **그대로** (사용자 요청 2026-11-08)
/// - 날짜가 바뀜(자정) → 화면 종류 유지, 선택한 날짜가 '어제의 오늘'이었으면 새 오늘로
/// - 메뉴로 끄고 켜기·앱 재실행 → 목록·오늘 (`initial`)
struct PanelViewState: Equatable {
    enum Mode: Equatable { case list, calendar }

    var mode: Mode
    /// 달력에 보이는 달 (1일)
    var month: LocalDate
    /// 달력에서 고른 날짜
    var selected: LocalDate

    /// 시작 상태: 목록 화면, 오늘
    static func initial(today: LocalDate) -> PanelViewState {
        PanelViewState(mode: .list, month: CalendarModel.firstOfMonth(today), selected: today)
    }

    /// 📆 버튼: 달력을 열 때는 이번 달·오늘부터
    func openingCalendar(today: LocalDate) -> PanelViewState {
        PanelViewState(mode: .calendar, month: CalendarModel.firstOfMonth(today), selected: today)
    }

    /// 목록으로 버튼
    func closingCalendar() -> PanelViewState {
        var s = self
        s.mode = .list
        return s
    }

    /// 패널이 접힘을 마침: 아무것도 바꾸지 않는다 (다시 펼치면 같은 화면·같은 달·같은 날짜)
    func collapsed() -> PanelViewState { self }

    /// 메뉴로 끔(즉시 숨김): 다음에 켜면 목록·오늘
    func turnedOff(today: LocalDate) -> PanelViewState { .initial(today: today) }

    /// 자정에 날짜가 바뀜. 화면 종류는 그대로. 선택한 날짜가 이전 '오늘'이면 새 오늘로 옮기고,
    /// 그 날짜의 달을 보고 있었다면 보이는 달도 새 오늘의 달로 (10/31 → 11/1)
    func dayChanged(from oldToday: LocalDate, to newToday: LocalDate) -> PanelViewState {
        guard oldToday != newToday, selected == oldToday else { return self }
        var s = self
        s.selected = newToday
        if month == CalendarModel.firstOfMonth(oldToday) {
            s.month = CalendarModel.firstOfMonth(newToday)
        }
        return s
    }
}
