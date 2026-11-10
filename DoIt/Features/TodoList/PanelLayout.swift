import Foundation
import CoreGraphics

/// 펼친 패널 높이 계산 (PRD F4 "내용에 맞춰 자동 조절") — 순수 함수라 테스트로 고정한다. (T-004, T-011 디자인 적용)
/// 화면의 각 부분은 아래 고정 높이로 그린다 (`TodoPanelContent`·`CalendarPanelView`가 같은 상수를 쓴다).
///
/// "몸통 높이(body height)" = **화면 맨 위부터 패널 아래 끝까지**. 패널은 노치에서 펼쳐져 노치 옆 메뉴바 띠까지 쓴다.
/// 그림자 여백은 포함하지 않는다 (`NotchViewModel.shadowMargin`).
///
/// 위→아래 (DESIGN.md 노치 패널): 노치 옆 띠의 머리줄(DoIt · 날짜 | 노치 | 📆 · ⚙) → 입력창 → (날짜 선택 영역)
/// → LMS 칸 + 내 할 일(함께 스크롤). 머리줄은 노치 높이의 띠 안에 있어 따로 높이를 차지하지 않는다
enum PanelLayout {
    // MARK: 카드 폭 (DESIGN.md)

    /// 목록 화면 카드 폭
    static let listCardWidth: CGFloat = 440
    /// 달력 화면 카드 폭
    static let calendarCardWidth: CGFloat = 520

    // MARK: 안쪽 여백

    /// 노치 띠 아래 첫 내용까지 여백
    static let topPadding: CGFloat = 8
    /// 카드 아래 안쪽 여백
    static let bottomPadding: CGFloat = 10
    /// 카드 좌우 안쪽 여백
    static let horizontalPadding: CGFloat = 12
    /// 세로 묶음(머리줄·입력·날짜 영역·목록) 사이 간격
    static let sectionSpacing: CGFloat = 8

    // MARK: 부분 높이

    /// 입력창 줄 높이
    static let inputHeight: CGFloat = 34
    /// 날짜 선택 영역 높이 (macOS 그래픽 달력 139×148pt + 위아래 여백 4씩)
    static let datePickerHeight: CGFloat = 156
    /// 내 할 일 한 행 높이 (DESIGN.md: 36~46)
    static let rowHeight: CGFloat = 36
    /// 행 사이 간격
    static let rowSpacing: CGFloat = 2
    /// 목록 위아래 안쪽 여백 (합)
    static let listVerticalPadding: CGFloat = 4
    /// 빈 목록 문구("할 일이 없어요") 영역 높이
    static let emptyListHeight: CGFloat = 44
    /// 패널이 펼쳐져 있을 때 알림이 오면 맨 위에 5초 보이는 강조 줄 (T-005)
    static let alertBannerHeight: CGFloat = 40

    /// 강조 줄이 있으면 그 높이 + 간격
    static func bannerExtra(_ banner: Bool) -> CGFloat { banner ? alertBannerHeight + sectionSpacing : 0 }

    // MARK: 최대 높이

    /// 최대 높이 상한
    static let maxHeightCap: CGFloat = 480
    /// 최대 높이 = 화면 높이의 이 비율 (상한과 비교해 작은 값)
    static let maxScreenFraction: CGFloat = 0.45

    /// 노치 띠·입력창 위아래를 합친 고정 부분 (목록 제외)
    static func fixedHeight(notchHeight: CGFloat, datePickerOpen: Bool, banner: Bool = false) -> CGFloat {
        notchHeight + topPadding + bannerExtra(banner)
            + inputHeight
            + (datePickerOpen ? sectionSpacing + datePickerHeight : 0)
            + sectionSpacing
            + bottomPadding
    }

    /// 목록이 다 보일 때의 높이 (행이 0개면 빈 목록 문구 높이)
    static func listHeight(rowCount: Int) -> CGFloat {
        guard rowCount > 0 else { return emptyListHeight }
        return rowsHeight(rowCount) + listVerticalPadding
    }

    static func maxHeight(screenHeight: CGFloat) -> CGFloat {
        min(maxHeightCap, (screenHeight * maxScreenFraction).rounded(.down))
    }

    /// 펼친 패널 몸통 높이. 최소 = 빈 목록 문구가 보이는 높이, 최대 = `maxHeight`. 넘치면 목록만 스크롤한다.
    /// (최대가 최소보다 작은 아주 작은 화면이면 최소를 쓴다)
    /// - Parameter lms: LMS 칸 (T-007). nil이면 내 할 일만
    static func bodyHeight(rowCount: Int, datePickerOpen: Bool, notchHeight: CGFloat, screenHeight: CGFloat,
                           lms: LmsBlock? = nil, banner: Bool = false) -> CGFloat {
        let fixed = fixedHeight(notchHeight: notchHeight, datePickerOpen: datePickerOpen, banner: banner)
        let minimum = fixed + emptyListHeight
        let wanted = fixed + scrollContentHeight(rowCount: rowCount, lms: lms)
        return max(minimum, min(wanted, maxHeight(screenHeight: screenHeight)))
    }

    /// 행 n개를 간격과 함께 쌓은 높이 (여백 제외)
    static func rowsHeight(_ n: Int, rowHeight: CGFloat = rowHeight) -> CGFloat {
        guard n > 0 else { return 0 }
        return CGFloat(n) * rowHeight + CGFloat(n - 1) * rowSpacing
    }

    // MARK: LMS 칸 (T-007, PRD F11)
    // LMS 칸은 내 할 일과 **같은 스크롤 영역의 맨 위**에 놓는다. 넘치면 둘을 함께 스크롤한다.

    /// 칸 머리 줄(접기 화살표 · LMS 과제 · 개수 배지 · 2주 · HH:mm 동기화) 높이
    static let lmsHeaderHeight: CGFloat = 28
    /// 오류 문구 줄 높이
    static let lmsMessageHeight: CGFloat = 18
    /// 머리 줄과 첫 행 사이
    static let lmsRowsTopGap: CGFloat = 2
    /// LMS 과제 한 행 (과제명 + 아랫줄 과목명 칩)
    static let lmsRowHeight: CGFloat = 46
    /// LMS 칸과 내 할 일 사이 (가운데에 구분선)
    static let lmsBottomGap: CGFloat = 13

    struct LmsBlock: Equatable {
        var rowCount: Int
        var collapsed: Bool
        var hasMessage: Bool
    }

    static func lmsBlockHeight(_ block: LmsBlock) -> CGFloat {
        var h = lmsHeaderHeight + lmsBottomGap
        if block.hasMessage { h += lmsMessageHeight }
        if !block.collapsed && block.rowCount > 0 { h += lmsRowsTopGap + rowsHeight(block.rowCount, rowHeight: lmsRowHeight) }
        return h
    }

    /// 스크롤 영역 내용 높이. LMS 칸이 없으면 `listHeight`와 같다.
    /// 있으면 위아래 여백 + LMS 칸 + (내 할 일 행들, 없으면 빈 목록 문구)
    static func scrollContentHeight(rowCount: Int, lms: LmsBlock?) -> CGFloat {
        guard let lms else { return listHeight(rowCount: rowCount) }
        return listVerticalPadding + lmsBlockHeight(lms) + (rowCount > 0 ? rowsHeight(rowCount) : emptyListHeight)
    }
}

// MARK: - 달력 화면 (T-009 → T-011 디자인, PRD F12)

extension PanelLayout {
    /// `2026년 11월 · ◀ 오늘 ▶` 줄 (목록으로 버튼은 노치 옆 띠)
    static let calendarHeaderHeight: CGFloat = 30
    /// 요일 줄 (일 월 화 …)
    static let calendarWeekdayHeight: CGFloat = 20
    /// 날짜 칸 높이 (숫자 + 점, DESIGN.md 약 54)
    static let calendarCellHeight: CGFloat = 54
    static let calendarRows = 6
    /// 범례 + "지난 날짜는 보기만 가능"
    static let calendarLegendHeight: CGFloat = 22
    /// 선택한 날짜 제목 줄 (`11월 14일 (금)`)
    static let calendarDayTitleHeight: CGFloat = 22
    /// 그날 항목이 없을 때 문구 높이
    static let calendarEmptyDayHeight: CGFloat = 30

    /// 달력 화면 최대 높이: 칸 54를 지키려고 목록 화면보다 크게 허용한다 (2026-11-08 사용자 결정, 보고서 참고)
    static let calendarMaxHeightCap: CGFloat = 640
    static let calendarMaxScreenFraction: CGFloat = 0.7

    static func calendarMaxHeight(screenHeight: CGFloat) -> CGFloat {
        min(calendarMaxHeightCap, (screenHeight * calendarMaxScreenFraction).rounded(.down))
    }

    /// 목록을 뺀 달력 화면 높이. 입력창은 오늘·미래 날짜일 때만 (달력 화면에는 날짜 선택 영역이 없다)
    static func calendarFixedHeight(notchHeight: CGFloat, inputVisible: Bool, banner: Bool = false) -> CGFloat {
        notchHeight + topPadding + bannerExtra(banner)
            + calendarHeaderHeight + calendarWeekdayHeight + CGFloat(calendarRows) * calendarCellHeight
            + calendarLegendHeight
            + sectionSpacing + calendarDayTitleHeight
            + (inputVisible ? sectionSpacing + inputHeight : 0)
            + bottomPadding
    }

    /// 그날 목록 높이 (없으면 빈 문구)
    static func calendarDayListHeight(rowCount: Int) -> CGFloat {
        rowCount > 0 ? rowsHeight(rowCount) + listVerticalPadding : calendarEmptyDayHeight
    }

    /// 달력 화면 몸통 높이. 넘치면 그날 목록만 스크롤
    static func calendarBodyHeight(dayRowCount: Int, inputVisible: Bool, notchHeight: CGFloat, screenHeight: CGFloat,
                                   banner: Bool = false) -> CGFloat {
        let fixed = calendarFixedHeight(notchHeight: notchHeight, inputVisible: inputVisible, banner: banner)
        let minimum = fixed + calendarEmptyDayHeight
        let wanted = fixed + calendarDayListHeight(rowCount: dayRowCount)
        return max(minimum, min(wanted, calendarMaxHeight(screenHeight: screenHeight)))
    }
}

/// 날짜 버튼 문구 (PRD F5): `오늘` / `내일` / 그 외는 `11/14(금)`
enum DueDateLabel {
    static func text(for date: LocalDate, today: LocalDate) -> String {
        switch date.days(from: today) {
        case 0: return "오늘"
        case 1: return "내일"
        default: return short(date)
        }
    }

    /// `11/14(금)`
    static func short(_ date: LocalDate) -> String {
        let weekdays = ["일", "월", "화", "수", "목", "금", "토"]
        let weekday = date.noonDate.map { LocalDate.calendar.component(.weekday, from: $0) } ?? 1
        return "\(date.month)/\(date.day)(\(weekdays[(weekday - 1) % 7]))"
    }
}
