import SwiftUI

/// 달력 화면 (PRD F12, T-011 디자인 DESIGN.md 달력 보기)
/// `2026년 11월 · ◀ 오늘 ▶` + 요일 (목록으로 버튼은 노치 옆 띠) + 6×7 날짜 칸(약 54) + 범례 + 고른 날짜의 목록
/// 각 부분 높이는 `PanelLayout.calendar…` 상수와 같게 고정한다. 패널 안에만 그린다 (별도 창 없음)
struct CalendarPanelView: View {
    let viewModel: NotchViewModel

    private static let weekdays = ["일", "월", "화", "수", "목", "금", "토"]

    var body: some View {
        let today = viewModel.store.today
        let month = viewModel.calendarMonth
        let grid = CalendarModel.monthGrid(month)
        let summaries = viewModel.calendarSummaries
        let selected = viewModel.calendarSelected
        let entries = viewModel.calendarEntries
        let readOnly = CalendarModel.isReadOnly(selected, today: today)

        VStack(spacing: 0) {
            header(month: month)
                .frame(height: PanelLayout.calendarHeaderHeight)

            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { i in
                    Text(Self.weekdays[i])
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(i == 0 ? Palette.overdue : Palette.secondaryText)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: PanelLayout.calendarWeekdayHeight)

            VStack(spacing: 0) {
                ForEach(0..<PanelLayout.calendarRows, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { col in
                            let date = grid[row * 7 + col]
                            DayCell(date: date,
                                    inMonth: date.month == month.month && date.year == month.year,
                                    isToday: date == today,
                                    isPast: date < today,
                                    isSelected: date == selected,
                                    summary: summaries[date] ?? CalendarModel.DaySummary(),
                                    onTap: { viewModel.selectCalendarDate(date) })
                        }
                    }
                    .frame(height: PanelLayout.calendarCellHeight)
                }
            }

            legend
                .frame(height: PanelLayout.calendarLegendHeight)

            Color.clear.frame(height: PanelLayout.sectionSpacing)

            HStack(spacing: 6) {
                Text(CalendarModel.dayTitle(selected))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.primaryText)
                if readOnly {
                    TagChip(text: "보기 전용", foreground: Palette.secondaryText, background: Palette.inputBackground)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: PanelLayout.calendarDayTitleHeight)

            if entries.isEmpty {
                Text("이날 마감인 항목이 없어요")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: PanelLayout.calendarEmptyDayHeight, maxHeight: PanelLayout.calendarEmptyDayHeight)
                Spacer(minLength: 0)
            } else {
                // 넘치면 그날 목록만 스크롤
                ScrollView(.vertical) {
                    VStack(spacing: PanelLayout.rowSpacing) {
                        ForEach(entries) { entry in
                            CalendarEntryRow(entry: entry, readOnly: readOnly,
                                             onToggle: { viewModel.toggleCalendarEntry(entry) })
                        }
                    }
                    .padding(.vertical, PanelLayout.listVerticalPadding / 2)
                }
                .scrollIndicators(.automatic)
                .frame(maxHeight: .infinity)
            }
        }
    }

    private func header(month: LocalDate) -> some View {
        HStack(spacing: 8) {
            Text(CalendarModel.title(month))
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(Palette.primaryText)

            Spacer(minLength: 0)

            PanelIconButton(symbol: "chevron.left", help: "이전 달") { viewModel.moveCalendarMonth(-1) }
            Button { viewModel.calendarGoToToday() } label: {
                Text("오늘")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.primaryText)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.inputBackground))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            PanelIconButton(symbol: "chevron.right", help: "다음 달") { viewModel.moveCalendarMonth(1) }
        }
        .padding(.horizontal, 4)
    }

    /// 범례 + 안내
    private var legend: some View {
        HStack(spacing: 10) {
            legendItem(Palette.todoAccent, "내 할 일")
            legendItem(Palette.lmsAccent, "LMS")
            legendItem(Palette.overdue, "지난 마감")
            Spacer(minLength: 0)
            Text("지난 날짜는 보기만 가능")
        }
        .font(.system(size: 10))
        .foregroundStyle(Palette.secondaryText)
        .padding(.horizontal, 6)
    }

    private func legendItem(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
        }
    }
}

/// 날짜 칸: 숫자 + 점(최대 3개, 넘치면 `+`). 오늘 = 초록 원 숫자, 고른 날 = 초록 테두리 + 옅은 초록 바탕,
/// 지난 날짜 숫자는 회색, 다른 달은 더 흐리게
private struct DayCell: View {
    let date: LocalDate
    let inMonth: Bool
    let isToday: Bool
    let isPast: Bool
    let isSelected: Bool
    let summary: CalendarModel.DaySummary
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 5) {
                Text("\(date.day)")
                    .font(.system(size: 13, weight: isToday ? .bold : .regular).monospacedDigit())
                    .foregroundStyle(numberColor)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(isToday ? Palette.todoAccent : Color.clear))
                HStack(spacing: 3) {
                    ForEach(Array(summary.dots.enumerated()), id: \.offset) { _, dot in
                        Circle().fill(color(dot)).frame(width: 5, height: 5)
                    }
                    if summary.hasMore {
                        Text("+")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Palette.secondaryText)
                    }
                }
                .frame(height: 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Palette.todoAccentSoft : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? Palette.todoAccent : Color.clear, lineWidth: 1.5))
            .opacity(inMonth ? 1 : 0.4)
            .padding(2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var numberColor: Color {
        if isToday { return Palette.onAccent }
        return isPast ? Palette.secondaryText : Palette.primaryText
    }

    /// 완료는 흐리게(35%, DESIGN.md)
    private func color(_ dot: CalendarModel.Dot) -> Color {
        switch dot {
        case .todo(let done): return Palette.todoAccent.opacity(done ? 0.35 : 1)
        case .lms(let done): return Palette.lmsAccent.opacity(done ? 0.35 : 1)
        case .lmsOverdue: return Palette.overdue
        }
    }
}

/// 달력 아래 목록의 한 행: 체크 원(지난 날짜면 흐리게·누를 수 없음), 제목, 칩(LMS = 과목명, 내 할 일 = "내 할 일"). 삭제 없음
private struct CalendarEntryRow: View {
    let entry: CalendarModel.Entry
    let readOnly: Bool
    let onToggle: () -> Void

    @State private var hovering = false
    @State private var truncated = false

    var body: some View {
        let overdue = entry.isLms && readOnly && !entry.isDone
        let accent = entry.isLms ? Palette.lmsAccent : Palette.todoAccent
        let ring = overdue ? Palette.overdue : (entry.isLms ? Palette.lmsAccent : Palette.checkRing)
        let chip = entry.course.map(LmsDisplay.shortCourseName) ?? "내 할 일"

        HStack(spacing: 8) {
            Button(action: onToggle) {
                CheckCircle(done: entry.isDone, accent: accent, ring: ring)
                    .opacity(readOnly ? 0.45 : 1)
            }
            .buttonStyle(.plain)
            .disabled(readOnly)

            HStack(spacing: 6) {
                Text(entry.title)
                    .font(.system(size: 13))
                    .strikethrough(entry.isDone)
                    .foregroundStyle(entry.isDone ? Palette.secondaryText : (overdue ? Palette.overdue : Palette.primaryText))
                    .lineLimit(1)
                    .layoutPriority(1)
                TagChip(text: chip,
                        foreground: entry.isLms ? Palette.lmsAccent : Palette.todoAccent,
                        background: entry.isLms ? Palette.lmsAccentSoft : Palette.todoAccentSoft)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .measuresTruncation($truncated) {
                HStack(spacing: 6) {
                    Text(entry.title).font(.system(size: 13))
                    Text(chip).font(.system(size: 10, weight: .medium)).padding(.horizontal, 6)
                }
            }
        }
        .opacity(entry.isDone ? 0.6 : 1)
        .padding(.horizontal, 6)
        .frame(height: PanelLayout.rowHeight)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(overdue ? Palette.overdueSoft : (hovering ? Palette.inputBackground : Color.clear)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .reportsHover(hovering && truncated, title: entry.title, subtitle: entry.course)
    }
}
