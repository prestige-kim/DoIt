import SwiftUI
import AppKit

/// 펼친 카드 안의 내용 (T-011 디자인, DESIGN.md 노치 패널)
/// 위→아래: 입력창 → (날짜 선택 영역) → LMS 칸 + 구분선 + 내 할 일(함께 스크롤).
/// 머리줄(DoIt · 날짜 · 📆 · ⚙)은 노치 옆 띠에 있다 (`NotchRootView`의 `PanelTopBand`)
/// 각 부분의 높이는 `PanelLayout` 상수와 같게 고정한다 (패널 높이 계산과 맞추기 위해, T-004).
struct TodoPanelContent: View {
    let viewModel: NotchViewModel

    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        let store = viewModel.store
        let todos = store.visibleTodos
        let lmsPanel = viewModel.lmsPanel

        VStack(spacing: PanelLayout.sectionSpacing) {
            // 패널이 펼쳐진 동안 알림이 오면 맨 위에 5초 강조 (T-005). 입력창은 그대로 쓸 수 있다
            if let banner = viewModel.panelBanner {
                AlertBanner(content: banner)
                    .frame(height: PanelLayout.alertBannerHeight)
            }
            if viewModel.panelMode == .calendar {
                // 달력 화면 (T-009 → T-011 디자인): 달력 + 그날 목록. 오늘·미래 날짜만 입력창
                CalendarPanelView(viewModel: viewModel)
                    .frame(maxHeight: .infinity)
                if viewModel.calendarInputVisible {
                    inputRow(today: store.today, calendar: true)
                        .frame(height: PanelLayout.inputHeight)
                }
            } else {
                inputRow(today: store.today, calendar: false)
                    .frame(height: PanelLayout.inputHeight)

                if viewModel.isDatePickerOpen {
                    DatePickerArea(viewModel: viewModel, today: store.today)
                        .frame(height: PanelLayout.datePickerHeight)
                        .onExitCommand { viewModel.cancelEditing() }  // 달력에 포커스가 있을 때의 Esc
                }

                if todos.isEmpty && lmsPanel == nil {
                    emptyText
                        .frame(maxWidth: .infinity, minHeight: PanelLayout.emptyListHeight, maxHeight: .infinity, alignment: .top)
                } else {
                    // 남는 높이를 모두 쓰고, 최대 높이를 넘으면 목록만 스크롤 (LMS 칸도 같은 스크롤 영역 맨 위, T-007)
                    ScrollView(.vertical) {
                        VStack(spacing: 0) {
                            if let lmsPanel {
                                LmsSectionView(panel: lmsPanel, today: store.today,
                                               onToggleSection: { viewModel.toggleLmsSection() },
                                               onToggleItem: { viewModel.toggleLmsCheck(uid: $0) })
                            }
                            if todos.isEmpty {
                                emptyText
                                    .frame(maxWidth: .infinity, minHeight: PanelLayout.emptyListHeight, maxHeight: PanelLayout.emptyListHeight)
                            } else {
                                LazyVStack(spacing: PanelLayout.rowSpacing) {
                                    ForEach(todos) { todo in
                                        TodoRowView(todo: todo, today: store.today,
                                                    onToggle: { viewModel.toggleTodo(id: todo.id) },
                                                    onDelete: { viewModel.deleteTodo(id: todo.id) })
                                    }
                                }
                            }
                        }
                        .padding(.vertical, PanelLayout.listVerticalPadding / 2)
                    }
                    .scrollIndicators(.automatic)
                    .frame(maxHeight: .infinity)
                }
            }
        }
        .padding(.horizontal, PanelLayout.horizontalPadding)
        .padding(.top, PanelLayout.topPadding)
        .padding(.bottom, PanelLayout.bottomPadding)
        // 잘린 행에 마우스를 올리면 전체 이름 말풍선 (T-007 LMS 행 → T-009 내 할 일·달력 행). 스크롤 영역 밖에 그려 잘리지 않게 한다
        .fullTextBubbleOverlay()
        .onChange(of: inputFocused) { _, focused in
            viewModel.inputFocusChanged(focused)
        }
        .onChange(of: viewModel.focusResetToken) { _, _ in
            inputFocused = false
        }
        .onChange(of: viewModel.focusRequestToken) { _, _ in
            inputFocused = true
        }
    }

    private var emptyText: some View {
        Text("할 일이 없어요")
            .font(.system(size: 13))
            .foregroundStyle(Palette.secondaryText)
            .padding(.top, 14)
    }

    /// 입력창: `+` · "할 일 추가…" · 날짜 칩
    /// - Parameter calendar: 달력 화면이면 날짜 칩 대신 고른 날짜를 글자로만 보인다 (달력 자체가 날짜 선택)
    private func inputRow(today: LocalDate, calendar: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.secondaryText)

            TextField("할 일 추가…", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Palette.primaryText)
                .focused($inputFocused)
                .onSubmit {
                    viewModel.submit(title: draft)
                    draft = ""
                }
                .onExitCommand { viewModel.cancelEditing() }

            if calendar {
                DateChip(text: DueDateLabel.text(for: viewModel.draftDueDate, today: today), active: false)
            } else {
                // 날짜 칩 (PRD F5): 오늘 / 내일 / 11/14(금). 누르면 날짜 선택 영역
                Button {
                    viewModel.toggleDatePicker()
                } label: {
                    DateChip(text: DueDateLabel.text(for: viewModel.draftDueDate, today: today), active: viewModel.isDatePickerOpen)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.inputBackground))
    }
}

/// 펼친 패널 맨 위 알림 강조 줄: 점 · `오늘 마감 n개` · 요약
private struct AlertBanner: View {
    let content: NotchAlertContent

    var body: some View {
        let accent = content.includesLms ? Palette.lmsAccent : Palette.todoAccent
        HStack(spacing: 8) {
            Image(systemName: "bell.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
            Text(content.title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Palette.primaryText)
            Text(content.body)
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(content.includesLms ? Palette.lmsAccentSoft : Palette.todoAccentSoft))
        .allowsHitTesting(false)
    }
}

/// 입력창 오른쪽 날짜 칩
private struct DateChip: View {
    let text: String
    /// 날짜 선택 영역이 열려 있음
    let active: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "calendar")
                .font(.system(size: 10, weight: .medium))
            Text(text)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
        }
        .foregroundStyle(active ? Palette.onAccent : Palette.todoAccent)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(active ? Palette.todoAccent : Palette.todoAccentSoft))
        .contentShape(Rectangle())
    }
}

/// 작은 아이콘 버튼 (노치 옆 띠 📆 · ⚙ · 달력 화면 ◀ ▶)
struct PanelIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.secondaryText)
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? Palette.inputBackground : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

/// 체크 원: 빈 원(테두리) / 완료는 강조색 원 + 체크
struct CheckCircle: View {
    let done: Bool
    /// 완료 원 색
    let accent: Color
    /// 빈 원 테두리 색
    let ring: Color

    var body: some View {
        ZStack {
            if done {
                Circle().fill(accent)
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(Palette.onAccent)
            } else {
                Circle().strokeBorder(ring, lineWidth: 1.5)
            }
        }
        .frame(width: 18, height: 18)
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
    }
}

/// 날짜 선택 영역 (패널 안, 별도 창·팝오버 없음 — PRD F5): 빠른 선택 버튼 + 그래픽 달력
private struct DatePickerArea: View {
    let viewModel: NotchViewModel
    let today: LocalDate

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                quickButton("오늘", today)
                quickButton("내일", today.adding(days: 1))
                quickButton("+1주", today.adding(days: 7))
            }
            .padding(.top, 4)

            // 포커스를 가져가지 않는 달력 (SwiftUI DatePicker는 클릭하면 입력창 포커스를 빼앗아 편집이 끝나 버림, T-004)
            CalendarPicker(date: viewModel.draftDueDate) { viewModel.pickDate($0) }
                .frame(width: 139, height: 148)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
    }

    private func quickButton(_ title: String, _ date: LocalDate) -> some View {
        let selected = viewModel.draftDueDate == date
        return Button {
            viewModel.pickDate(date)
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? Palette.onAccent : Palette.primaryText)
                .frame(width: 64, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Palette.todoAccent : Palette.inputBackground))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// macOS 그래픽 달력(`NSDatePicker`)을 감싼 것. **키보드 포커스를 받지 않아** 입력창이 계속 편집 중으로 남는다.
/// 날짜(일)를 누르면 `onPick`. 달 넘기기(`<` `>`)는 값이 같은 '일'로 다음 달로 바뀌는 것이라 고른 것으로 치지 않는다.
/// 지난 날짜도 고를 수 있다.
private struct CalendarPicker: NSViewRepresentable {
    let date: LocalDate
    let onPick: (LocalDate) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSDatePicker {
        let picker = NonFocusDatePicker()
        picker.datePickerStyle = .clockAndCalendar
        picker.datePickerElements = .yearMonthDay
        picker.isBezeled = false
        picker.isBordered = false
        picker.drawsBackground = false
        picker.calendar = LocalDate.calendar
        picker.timeZone = .current
        picker.refusesFirstResponder = true
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.changed(_:))
        context.coordinator.shown = date
        picker.dateValue = date.noonDate ?? Date()
        return picker
    }

    func updateNSView(_ picker: NSDatePicker, context: Context) {
        context.coordinator.onPick = onPick
        // 바깥에서 날짜가 바뀌었을 때만 달력에 반영 (달 넘기기 중인 화면을 되돌리지 않도록)
        if context.coordinator.shown != date {
            context.coordinator.shown = date
            picker.dateValue = date.noonDate ?? Date()
        }
    }

    final class Coordinator: NSObject {
        var onPick: (LocalDate) -> Void = { _ in }
        /// 달력이 마지막으로 보여 준 날짜
        var shown: LocalDate?

        @objc func changed(_ sender: NSDatePicker) {
            let new = LocalDate(sender.dateValue)
            let old = shown
            shown = new
            if let old, Self.isMonthNavigation(from: old, to: new) { return }
            onPick(new)
        }

        /// 달만 바뀌고 '일'은 그대로(또는 말일로 맞춰짐)면 달 넘기기로 본다
        static func isMonthNavigation(from old: LocalDate, to new: LocalDate) -> Bool {
            guard old.year != new.year || old.month != new.month else { return false }
            if new.day == old.day { return true }
            let lastDay = new.noonDate.flatMap { LocalDate.calendar.range(of: .day, in: .month, for: $0)?.count } ?? 31
            return new.day == lastDay && old.day > lastDay
        }
    }
}

/// 첫 클릭을 바로 받고, 키보드 포커스는 받지 않는 날짜 선택기
private final class NonFocusDatePicker: NSDatePicker {
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 내 할 일 한 행 (DESIGN.md): 빈 원(회색) / 완료는 초록 원 + 체크 + 취소선·흐린 글자. 오늘 마감은 날짜 글자 초록.
/// 마우스를 올리면 `×` → 1번 누르면 `삭제?` → 1번 더 누르면 삭제. 행을 벗어나면 취소 (PRD F7)
struct TodoRowView: View {
    let todo: Todo
    let today: LocalDate
    let onToggle: () -> Void
    let onDelete: () -> Void

    /// 행 위에 마우스가 있는지 (SwiftUI `.onHover` — 이벤트 방식, 폴링 없음)
    @State private var hovering = false
    /// `삭제?` 확인 단계
    @State private var confirmingDelete = false
    /// 제목이 잘렸는지 (잘렸을 때만 말풍선, T-009)
    @State private var truncated = false

    var body: some View {
        let days = todo.dueDate.days(from: today)
        let overdue = !todo.isDone && days < 0

        HStack(spacing: 8) {
            Button(action: onToggle) {
                CheckCircle(done: todo.isDone, accent: Palette.todoAccent, ring: Palette.checkRing)
            }
            .buttonStyle(.plain)

            Text(todo.title)
                .font(.system(size: 13))
                .strikethrough(todo.isDone)
                .foregroundStyle(todo.isDone ? Palette.secondaryText : (overdue ? Palette.overdue : Palette.primaryText))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .measuresTruncation($truncated) { Text(todo.title).font(.system(size: 13)) }

            Text(TodoOrdering.dDayLabel(due: todo.dueDate, today: today))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(overdue ? Palette.overdue : (days == 0 && !todo.isDone ? Palette.todoAccent : Palette.secondaryText))

            deleteButton
                .frame(width: PanelRow.trailingWidth, alignment: .trailing)
        }
        .opacity(todo.isDone ? 0.6 : 1)
        .padding(.horizontal, 6)
        .frame(height: PanelLayout.rowHeight)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(hovering ? Palette.inputBackground : Color.clear))
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if !inside { confirmingDelete = false }  // 행을 벗어나면 취소 (타이머 없음)
        }
        .reportsHover(hovering && truncated, title: todo.title, subtitle: nil)
    }

    @ViewBuilder
    private var deleteButton: some View {
        if confirmingDelete {
            Button(action: onDelete) {
                Text("삭제?")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Palette.overdue)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else if hovering {
            Button {
                confirmingDelete = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Palette.secondaryText)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Color.clear
        }
    }
}

/// 목록 행 공통 치수
enum PanelRow {
    /// 행 오른쪽 `×`·`삭제?` 자리 (LMS 행은 같은 폭을 비워 오른쪽 글자 열을 맞춘다)
    static let trailingWidth: CGFloat = 34
}

// MARK: - LMS 칸 (T-007, PRD F11 → T-011 디자인)

/// LMS 칸: 머리(접기 화살표 · LMS 과제 · 개수 배지 · `2주 · 21:20 동기화`) + 오류 문구 + 과제 행 + 구분선. 삭제·제목 수정 없음
/// 각 부분 높이는 `PanelLayout.lmsBlockHeight`와 같게 고정한다
struct LmsSectionView: View {
    let panel: NotchViewModel.LmsPanel
    let today: LocalDate
    let onToggleSection: () -> Void
    let onToggleItem: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggleSection) {
                HStack(spacing: 6) {
                    Image(systemName: panel.collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Palette.secondaryText)
                        .frame(width: 10)
                    Text("LMS 과제")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.primaryText)
                    Text("\(panel.items.count)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Palette.lmsAccent)
                        .padding(.horizontal, 6)
                        .frame(height: 16)
                        .background(Capsule().fill(Palette.lmsAccentSoft))
                    Spacer(minLength: 0)
                    Text(panel.caption)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(1)
                }
                .padding(.horizontal, 6)
                .frame(height: PanelLayout.lmsHeaderHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let message = panel.message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.overdue)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .frame(height: PanelLayout.lmsMessageHeight)
            }

            if !panel.collapsed && !panel.items.isEmpty {
                VStack(spacing: PanelLayout.rowSpacing) {
                    ForEach(panel.items) { item in
                        LmsRowView(item: item, isChecked: panel.checked.contains(item.uid), today: today,
                                   onToggle: { onToggleItem(item.uid) })
                    }
                }
                .padding(.top, PanelLayout.lmsRowsTopGap)
            }

            // 내 할 일과의 구분선
            Rectangle()
                .fill(Palette.separator)
                .frame(height: 1)
                .padding(.horizontal, 6)
                .frame(height: PanelLayout.lmsBottomGap)
        }
    }
}

/// 과목명 칩 / "내 할 일" 칩
struct TagChip: View {
    let text: String
    let foreground: Color
    let background: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(background))
    }
}

/// LMS 과제 한 행 (DESIGN.md): 파란 빈 원 · 과제명 · 아랫줄 과목명 칩 · 오른쪽 D-day(굵게) + 날짜(작게).
/// 지난 과제는 원·글자 빨강 + 옅은 빨강 바탕, "어제 마감"
struct LmsRowView: View {
    let item: LmsItem
    let isChecked: Bool
    let today: LocalDate
    let onToggle: () -> Void

    @State private var hovering = false
    /// 과제명·과목명이 잘렸는지
    @State private var truncated = false

    var body: some View {
        let overdue = LmsDisplay.isOverdue(item, isChecked: isChecked, today: today)
        let days = item.dueDate.days(from: today)
        let accent = overdue ? Palette.overdue : Palette.lmsAccent

        HStack(spacing: 8) {
            Button(action: onToggle) {
                CheckCircle(done: isChecked, accent: Palette.lmsAccent, ring: accent)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 13))
                    .strikethrough(isChecked)
                    .foregroundStyle(isChecked ? Palette.secondaryText : (overdue ? Palette.overdue : Palette.primaryText))
                    .lineLimit(1)
                if let course = item.courseName {
                    TagChip(text: LmsDisplay.shortCourseName(course), foreground: Palette.lmsAccent, background: Palette.lmsAccentSoft)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .measuresTruncation($truncated) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.system(size: 13))
                    if let course = item.courseName {
                        Text(LmsDisplay.shortCourseName(course)).font(.system(size: 10, weight: .medium)).padding(.horizontal, 6)
                    }
                }
            }

            VStack(alignment: .trailing, spacing: 2) {
                Text(LmsDisplay.dueTitle(item, isChecked: isChecked, today: today))
                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                    .foregroundStyle(overdue ? Palette.overdue : (days == 0 && !isChecked ? Palette.lmsAccent : Palette.primaryText))
                Text(LmsDisplay.dueDetail(item))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Palette.secondaryText)
            }
            .fixedSize()

            // 내 할 일 행의 `×` 자리만큼 비워 오른쪽 열을 맞춘다 (LMS 행은 삭제 없음)
            Color.clear.frame(width: PanelRow.trailingWidth)
        }
        .opacity(isChecked ? 0.6 : 1)
        .padding(.horizontal, 6)
        .frame(height: PanelLayout.lmsRowHeight)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(overdue ? Palette.overdueSoft : (hovering ? Palette.inputBackground : Color.clear)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }  // 이벤트 방식 (폴링 없음)
        .reportsHover(hovering && truncated, title: item.title, subtitle: item.courseName)
    }
}
