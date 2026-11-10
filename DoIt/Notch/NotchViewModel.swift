import SwiftUI
import AppKit
import Observation
import os

private let stateLogger = Logger(subsystem: "com.personal.doit", category: "state")

/// 노치 상태 머신의 **어댑터**. 판단은 `NotchStateMachine`(순수 구조체)이 하고, 여기서는
/// 이벤트를 넘기고 돌려받은 해야 할 일(Effect)을 실행한다: 애니메이션, 창 조작(콜백), 저장소 호출, 일회성 지연. (T-003)
@MainActor
@Observable
final class NotchViewModel {
    // MARK: 상태
    @ObservationIgnored private var machine = NotchStateMachine()
    /// 현재 상태 (화면·디버그용 읽기 전용)
    private(set) var state: NotchState = .off {
        didSet { if oldValue != state { stateLogger.debug("state \(oldValue.rawValue, privacy: .public) → \(self.state.rawValue, privacy: .public)") } }
    }
    /// 사용자가 켠 상태 (OFF에서 노치 알림으로 잠깐 보이는 동안은 false, T-005)
    var isOn: Bool { machine.isOn }

    // MARK: 화면에 그릴 값 (SwiftUI가 읽음)
    /// 노치 모양이 펼친 크기인지 (애니메이션 대상)
    private(set) var isShapeExpanded = false
    /// 목록 내용이 보이는지 (애니메이션 대상)
    private(set) var isContentVisible = false
    /// 노치 몸통 크기 (윗모서리 귀 제외)
    private(set) var notchSize = CGSize(width: NotchGeometry.virtualNotchWidth, height: 32)
    /// 입력창 포커스를 강제로 풀어야 할 때 값이 바뀐다 (뷰가 감시)
    private(set) var focusResetToken = 0
    /// 입력창에 포커스를 줘야 할 때 값이 바뀐다 (뷰가 감시) (T-004)
    private(set) var focusRequestToken = 0

    // MARK: 날짜 선택·높이 (T-004)
    /// 날짜 선택 영역이 열려 있는지
    private(set) var isDatePickerOpen = false
    /// 새 할 일의 마감일 (날짜 버튼). 기본 오늘, 추가 후 오늘로 돌아감
    private(set) var draftDueDate: LocalDate
    /// 카드 모양의 펼친 몸통 높이 (화면 맨 위 ~ 카드 아래 끝) — 애니메이션 대상
    private(set) var shapeBodyHeight: CGFloat = 0
    /// 패널 내용을 배치하는 높이 — 애니메이션 대상
    private(set) var contentBodyHeight: CGFloat = 0
    /// 창 프레임에 쓰는 펼친 몸통 높이 (애니메이션 없음, 창 컨트롤러가 읽음)
    @ObservationIgnored private(set) var frameBodyHeight: CGFloat = 0
    /// 카드 폭 (목록 440 / 달력 520) — 애니메이션 대상 (T-011)
    private(set) var shapeCardWidth: CGFloat = PanelLayout.listCardWidth
    /// 내용을 배치하는 카드 폭 (화면 종류가 바뀌면 바로 바뀜, 모양 폭은 애니메이션으로 따라옴)
    var contentCardWidth: CGFloat { targetCardWidth }
    /// 창 프레임에 쓰는 카드 폭 (애니메이션 없음)
    @ObservationIgnored private(set) var frameCardWidth: CGFloat = PanelLayout.listCardWidth
    /// 오래된 높이 축소 완료 콜백 무시용
    @ObservationIgnored private var heightGeneration = 0
    /// 주 디스플레이 높이 (최대 패널 높이 계산용)
    @ObservationIgnored private var screenHeight: CGFloat = 900

    /// 할 일 저장소 (T-002). 패널은 이것만 읽고 쓴다
    let store: TodoStore
    /// LMS 과제 저장소 (T-007). 없으면 LMS 칸 없음
    let lms: LmsStore?

    init(store: TodoStore, lms: LmsStore? = nil) {
        self.store = store
        self.lms = lms
        self.draftDueDate = store.today
        self.viewState = .initial(today: store.today)
        self.lastKnownToday = store.today
        store.onTodayChanged = { [weak self] in self?.todayChanged() }  // 날짜가 바뀌면 숨김 항목이 달라짐
        lms?.onChange = { [weak self] in self?.updateHeight() }        // 동기화·체크·설정 변화 (T-007)
        let h = targetBodyHeight
        shapeBodyHeight = h
        contentBodyHeight = h
        frameBodyHeight = h
    }

    // MARK: 크기 상수
    /// 높이·폭이 바뀔 때 애니메이션 (펼침·접힘 애니메이션과 별개, T-004)
    static let heightAnimation = Animation.easeInOut(duration: 0.2)
    /// 접힌 검은 노치 모양 (윗모서리 귀 · 아래 모서리)
    static let collapsedTopRadius: CGFloat = 4
    static let collapsedBottomRadius: CGFloat = 8
    /// 펼친 패널 윗모서리 귀 (메뉴바와 이어지는 곡선, 노치에서 펼쳐지는 연출)
    static let expandedTopRadius: CGFloat = 10
    /// 펼친 패널 아래 모서리 (DESIGN.md: 14)
    static let cardCornerRadius: CGFloat = 14
    /// 카드 그림자가 잘리지 않게 창 프레임에 두는 여백 (옆·아래). 그림자는 펼친 상태에서만 (ARCHITECTURE §5-3)
    static let shadowMargin: CGFloat = 12
    static let initialPeekSeconds: Double = 3
    /// 패널 밖으로 나간 뒤 접기 전 유예 (T-008 사용자 결정, ARCHITECTURE §3.3 "0.1초 이내 유예 허용")
    static let exitGraceSeconds: Double = 0.1

    /// 패널 프레임 크기 (귀 포함). 노치 알림이 떠 있으면 알림 크기 (T-005)
    var collapsedFrameSize: CGSize {
        if alertFrameActive {
            return CGSize(width: alertSize.width + 2 * Self.alertTopRadius, height: alertSize.height)
        }
        return CGSize(width: notchSize.width + 2 * Self.collapsedTopRadius, height: notchSize.height)
    }

    // MARK: 노치 알림 (T-005, PRD F8, DESIGN.md 노치 알림)

    /// 노치 알림 아랫줄(요약) 높이
    static let alertLineHeight: CGFloat = 24
    /// 노치 알림 모양 (윗모서리 귀 · 아래 모서리)
    static let alertTopRadius: CGFloat = 6
    static let alertBottomRadius: CGFloat = 14
    /// 노치 알림 표시 시간 (일회성 지연)
    static let alertSeconds: Double = 5
    /// 노치 양옆 최소 폭 (왼쪽 `● 오늘 마감 n개`, 오른쪽 `×`)
    static let alertSideMin: CGFloat = 110

    /// 지금 보이는 노치 알림 내용 (없으면 nil)
    private(set) var alertContent: NotchAlertContent?
    /// 노치 알림이 넓어진 상태인지 — 애니메이션 대상
    private(set) var isAlertOpen = false
    /// 노치 알림 몸통 크기 (귀 제외)
    private(set) var alertSize = CGSize(width: 0, height: 0)
    /// 창 프레임을 알림 크기로 쓰는 중
    @ObservationIgnored private var alertFrameActive = false
    /// 도착한 알림 내용 (상태 머신 처리 전)
    @ObservationIgnored private var pendingAlert: NotchAlertContent?
    /// 펼친 패널 맨 위 강조 (알림이 패널이 펼쳐진 동안 도착)
    private(set) var panelBanner: NotchAlertContent?
    @ObservationIgnored private var bannerToken = 0

    /// 노치 알림 띄우기 (스케줄러·테스트 알림이 부름). 상태에 따라 노치 알림 또는 패널 강조
    func presentAlert(_ content: NotchAlertContent) {
        pendingAlert = content
        stateLogger.debug("alert arrived state=\(self.state.rawValue, privacy: .public)")
        send(.alertArrived)
    }

    /// `×`: 마우스가 알림 위에 있어도 바로 닫는다
    func closeAlert() {
        send(.alertClose)
    }

    /// 노치 알림을 누름 → 패널
    func alertTapped() {
        send(.alertTapped)
    }

    /// 알림 크기: 노치 줄(노치 높이) + 요약 한 줄. 폭은 내용에 맞추되 패널 폭(440) 이하
    private func computeAlertSize(_ content: NotchAlertContent) -> CGSize {
        let font = NSFont.systemFont(ofSize: 12)
        let bodyWidth = (content.body as NSString).size(withAttributes: [.font: font]).width
        let minWidth = notchSize.width + 2 * Self.alertSideMin
        let width = min(PanelLayout.listCardWidth, max(minWidth, ceil(bodyWidth) + 40))
        return CGSize(width: width, height: notchSize.height + Self.alertLineHeight)
    }

    private func clearAlertState() {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { isAlertOpen = false }
        alertContent = nil
        alertFrameActive = false
    }
    var expandedFrameSize: CGSize {
        CGSize(width: frameCardWidth + 2 * Self.expandedTopRadius + 2 * Self.shadowMargin,
               height: frameBodyHeight + Self.shadowMargin)
    }

    /// 지금 화면 종류에 맞는 카드 폭
    private var targetCardWidth: CGFloat {
        panelMode == .calendar ? PanelLayout.calendarCardWidth : PanelLayout.listCardWidth
    }

    /// 지금 내용에 맞는 펼친 몸통 높이
    private var targetBodyHeight: CGFloat {
        if panelMode == .calendar {
            return PanelLayout.calendarBodyHeight(dayRowCount: calendarEntries.count, inputVisible: calendarInputVisible,
                                                  notchHeight: notchSize.height, screenHeight: screenHeight,
                                                  banner: panelBanner != nil)
        }
        return PanelLayout.bodyHeight(rowCount: store.visibleTodos.count, datePickerOpen: isDatePickerOpen,
                               notchHeight: notchSize.height, screenHeight: screenHeight,
                               lms: lmsPanel.map { PanelLayout.LmsBlock(rowCount: $0.items.count, collapsed: $0.collapsed,
                                                                         hasMessage: $0.message != nil) },
                               banner: panelBanner != nil)
    }

    // MARK: 달력 화면 (T-009, PRD F12)

    typealias PanelMode = PanelViewState.Mode
    /// 화면 종류·보던 달·고른 날짜 (T-011: 접혔다 펼쳐도 유지, 끄고 켜면 목록·오늘)
    private(set) var viewState: PanelViewState {
        didSet {
            if oldValue.mode != viewState.mode {
                stateLogger.debug("panel mode → \(self.viewState.mode == .list ? "list" : "calendar", privacy: .public)")
            }
        }
    }
    /// 날짜가 바뀐 것을 알아채기 위한 이전 '오늘'
    @ObservationIgnored private var lastKnownToday: LocalDate
    /// 목록 / 달력
    var panelMode: PanelMode { viewState.mode }
    /// 달력에 보이는 달 (1일)
    var calendarMonth: LocalDate { viewState.month }
    /// 달력에서 고른 날짜 (기본 오늘)
    var calendarSelected: LocalDate { viewState.selected }

    /// 고른 날짜가 오늘·미래면 입력창을 보인다 (지난 날짜는 보기 전용)
    var calendarInputVisible: Bool { !CalendarModel.isReadOnly(calendarSelected, today: store.today) }

    /// 고른 날짜의 내 할 일 + LMS 과제(현재 + 기록)
    var calendarEntries: [CalendarModel.Entry] {
        CalendarModel.entries(on: calendarSelected, todos: store.todos, lms: lms?.allItems ?? [], checked: lms?.checked ?? [:])
    }

    /// 보이는 달 42칸의 점
    var calendarSummaries: [LocalDate: CalendarModel.DaySummary] {
        CalendarModel.summaries(grid: CalendarModel.monthGrid(calendarMonth), todos: store.todos,
                                lms: lms?.allItems ?? [], checked: lms?.checked ?? [:], today: store.today)
    }

    /// 📆 버튼 ↔ 목록 버튼
    func togglePanelMode() {
        if panelMode == .list {
            if isDatePickerOpen { send(.datePickerToggled) }  // 달력 화면에는 날짜 선택 영역이 없다
            store.refreshToday()
            viewState = viewState.openingCalendar(today: store.today)
            draftDueDate = store.today
        } else {
            viewState = viewState.closingCalendar()
            draftDueDate = store.today
        }
        updateHeight()
    }

    func moveCalendarMonth(_ delta: Int) {
        viewState.month = CalendarModel.addingMonths(calendarMonth, delta)
    }

    func calendarGoToToday() {
        viewState.month = CalendarModel.firstOfMonth(store.today)
        selectCalendarDate(store.today)
    }

    /// 날짜 칸을 누름. 다른 달 날짜면 그 달로 넘어간다. 오늘·미래면 입력창 날짜를 그 날짜로
    func selectCalendarDate(_ date: LocalDate) {
        viewState.selected = date
        if date.year != calendarMonth.year || date.month != calendarMonth.month {
            viewState.month = CalendarModel.firstOfMonth(date)
        }
        if !CalendarModel.isReadOnly(date, today: store.today) {
            draftDueDate = date
        }
        updateHeight()
    }

    /// 달력 목록의 체크. 지난 날짜면 무시 (보기 전용)
    func toggleCalendarEntry(_ entry: CalendarModel.Entry) {
        guard !CalendarModel.isReadOnly(calendarSelected, today: store.today) else { return }
        switch entry.kind {
        case .todo(let id): toggleTodo(id: id)
        case .lms(let uid): toggleLmsCheck(uid: uid)
        }
        updateHeight()
    }

    /// 메뉴로 끔(즉시 숨김): 다음에 켜면 목록·오늘 (PRD F12). 접힘에서는 부르지 않는다 (직전 화면 유지, T-011)
    private func resetViewState() {
        let initial = PanelViewState.initial(today: store.today)
        guard viewState != initial else { return }
        viewState = initial
        draftDueDate = store.today
        updateHeight()
    }

    /// 날짜가 바뀜 (자정 알림 또는 펼칠 때 확인): 화면 종류는 유지, '어제의 오늘'을 보고 있었으면 새 오늘로
    private func todayChanged() {
        let old = lastKnownToday
        let new = store.today
        lastKnownToday = new
        let next = viewState.dayChanged(from: old, to: new)
        if next != viewState {
            viewState = next
            if panelMode == .calendar, !CalendarModel.isReadOnly(next.selected, today: new) {
                draftDueDate = next.selected
            }
        }
        updateHeight()
    }

    /// 머리줄 ⚙ 버튼: 설정 창 열기 (메뉴 `설정…`과 같은 동작, AppDelegate가 채움)
    @ObservationIgnored var onOpenSettings: () -> Void = {}

    func openSettings() {
        stateLogger.debug("open settings from panel")
        onOpenSettings()
    }

    /// 머리줄 편집기 버튼: 전체 편집기 열기 (메뉴 `전체 편집기…`와 같은 동작, AppDelegate가 채움, T-006).
    /// 앱 활성화는 편집기 창 컨트롤러 안에서만 (노치 패널 코드에서는 `NSApp.activate`를 쓰지 않음)
    @ObservationIgnored var onOpenEditor: () -> Void = {}

    func openEditor() {
        stateLogger.debug("open editor from panel")
        onOpenEditor()
    }

    /// 기록 정리 등 바깥에서 내용이 바뀌었을 때 (높이 재계산)
    func contentChanged() {
        updateHeight()
    }

    // MARK: LMS 칸 (T-007)

    /// 패널 LMS 칸에 그릴 것. 칸을 보이지 않을 때는 nil
    struct LmsPanel {
        let items: [LmsItem]
        let checked: Set<String>
        let message: String?
        let collapsed: Bool
        /// 머리 오른쪽 `2주 · 21:20 동기화` (T-011)
        let caption: String
    }

    var lmsPanel: LmsPanel? {
        guard let lms, lms.isSectionShown(today: store.today) else { return nil }
        let items = lms.visibleItems(today: store.today)
        return LmsPanel(items: items, checked: Set(items.map(\.uid).filter { lms.isChecked($0) }),
                        message: lms.panelMessage, collapsed: lms.isSectionCollapsed,
                        caption: LmsDisplay.headerCaption(weeks: lms.weeks, lastSuccess: lms.record.lastSuccessAt, now: lms.displayNow))
    }

    func toggleLmsCheck(uid: String) {
        lms?.toggleCheck(uid: uid)  // onChange → updateHeight
    }

    func toggleLmsSection() {
        lms?.isSectionCollapsed.toggle()
    }

    /// 패널을 펼칠 때 (LMS 자동 동기화 트리거, T-007). 창 컨트롤러가 아닌 AppDelegate가 채움
    @ObservationIgnored var onExpand: () -> Void = {}

    // MARK: 창 컨트롤러와 연결 (컨트롤러가 채움)
    @ObservationIgnored var onNeedsExpandedFrame: () -> Void = {}
    @ObservationIgnored var onNeedsCollapsedFrame: () -> Void = {}
    @ObservationIgnored var onReapplyFrame: () -> Void = {}
    @ObservationIgnored var onShow: () -> Void = {}
    @ObservationIgnored var onHide: () -> Void = {}
    @ObservationIgnored var onResignKey: () -> Void = {}
    /// 키보드 포커스(커서)만 지운다. 패널을 숨겼다 띄우지 않는다.
    @ObservationIgnored var onClearFocus: () -> Void = {}
    /// hover 추적 영역을 "마우스가 안에 있음"으로 다시 만든다
    @ObservationIgnored var onResyncTrackingAssumeInside: () -> Void = {}
    /// 패널을 key로 만든다 (입력창 포커스 전에) (T-004)
    @ObservationIgnored var onFocusInput: () -> Void = {}
    /// 마우스가 지금 패널 안에 있는지 1회 확인 (접힘 완료 시에만 사용)
    @ObservationIgnored var isMouseInsidePanelNow: () -> Bool = { false }

    /// Enter로 받은 제목 (`.addTodo` 실행 때 사용)
    @ObservationIgnored private var pendingTitle = ""

    // MARK: 외부에서 부르는 입구 (이름은 T-002와 같게 유지)

    func turnOn() { send(.turnOn) }
    func turnOff() { send(.turnOff) }
    /// 이미 실행 중인 DoIt을 다시 엶 (T-010). 앱 활성화는 하지 않는다 (노치 패널 NSApp.activate 금지)
    func reopened() { send(.reopened) }
    func screenChanged() { send(.screenChanged) }
    /// 노치 위치·크기가 실제로 바뀜 (모니터 연결·해제, 주 디스플레이 변경, 해상도, T-008)
    func displayChanged() {
        stateLogger.info("display changed state=\(self.state.rawValue, privacy: .public)")
        send(.displayChanged)
    }

    /// - Parameter windowInfo: 진단용 문자열 (패널 frame, isVisible, 마우스 좌표)
    func mouseEntered(windowInfo: String = "") {
        stateLogger.debug("mouseEntered state=\(self.state.rawValue, privacy: .public) gen=\(self.machine.generation, privacy: .public) mouseInside(before)=\(self.machine.mouseInside, privacy: .public) \(windowInfo, privacy: .public)")
        send(.mouseEntered)
    }

    /// - Parameter spurious: 프레임 변경 직후 + 좌표가 패널 안인 가짜 이탈인지 (`HoverGeometry.isSpuriousExit`)
    func mouseExited(windowInfo: String = "", spurious: Bool) {
        stateLogger.debug("mouseExited state=\(self.state.rawValue, privacy: .public) gen=\(self.machine.generation, privacy: .public) mouseInside(before)=\(self.machine.mouseInside, privacy: .public) spurious=\(spurious, privacy: .public) \(windowInfo, privacy: .public)")
        send(.mouseExited(spurious: spurious))
    }

    /// 입력창 포커스 변화 (뷰에서 호출)
    func inputFocusChanged(_ focused: Bool) {
        stateLogger.debug("inputFocusChanged(\(focused, privacy: .public)) state=\(self.state.rawValue, privacy: .public) mouseInside=\(self.machine.mouseInside, privacy: .public)")
        send(focused ? .inputFocusGained : .inputFocusLost)
    }

    /// Esc
    func cancelEditing() {
        stateLogger.debug("cancelEditing (Esc) state=\(self.state.rawValue, privacy: .public)")
        send(.escape)
    }

    /// 패널이 key 상태를 잃음 (= 패널 바깥 클릭 등)
    func panelDidResignKey() {
        stateLogger.debug("panelDidResignKey state=\(self.state.rawValue, privacy: .public) mouseInside=\(self.machine.mouseInside, privacy: .public)")
        send(.panelResignedKey)
    }

    /// 입력창 Enter
    func submit(title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        stateLogger.debug("submit state=\(self.state.rawValue, privacy: .public) empty=\(trimmed.isEmpty, privacy: .public) mouseInside=\(self.machine.mouseInside, privacy: .public)")
        pendingTitle = trimmed
        send(.submit(hasText: !trimmed.isEmpty))
    }

    // MARK: 할 일 조작 (패널에서 호출, T-004)

    func toggleTodo(id: UUID) {
        store.toggleDone(id: id)
        updateHeight()
    }

    func deleteTodo(id: UUID) {
        store.delete(id: id)
        updateHeight()
    }

    /// 날짜 버튼
    func toggleDatePicker() {
        guard panelMode == .list else { return }  // 달력 화면에서는 달력이 날짜 선택
        stateLogger.debug("date picker toggle (open=\(self.isDatePickerOpen, privacy: .public)) state=\(self.state.rawValue, privacy: .public)")
        send(.datePickerToggled)
    }

    /// 날짜 영역에서 날짜를 고름 (빠른 버튼 또는 달력)
    func pickDate(_ date: LocalDate) {
        draftDueDate = date
        stateLogger.debug("date picked \(date.string, privacy: .public)")
        send(.datePicked)
    }

    // MARK: 화면 구성 변경
    func updateScreen(notchSize size: CGSize, screenHeight: CGFloat) {
        notchSize = size
        self.screenHeight = screenHeight
        updateHeight()
    }

    // MARK: 높이 (T-004)

    /// 내용이 바뀌면 높이를 다시 맞춘다. 커질 때는 프레임을 먼저 키우고 모양을 애니메이션,
    /// 작아질 때는 모양 애니메이션이 끝난 뒤 프레임을 줄인다 (완료 콜백 안에서 직접 setFrame 금지 → main.async, ARCHITECTURE §3.2)
    /// 폭도 같은 방식 (목록 440 ↔ 달력 520, T-011): 한쪽이라도 커지면 프레임을 먼저 그 크기까지 키우고,
    /// 애니메이션이 끝난 뒤 남는 쪽을 줄인다.
    private func updateHeight() {
        let target = targetBodyHeight
        let targetWidth = targetCardWidth
        let isExpanded = state == .expanded || state == .editing
        guard isExpanded else {
            // 접혀 있으면 다음 펼칠 때 쓰도록 값만 맞춘다
            shapeBodyHeight = target
            contentBodyHeight = target
            frameBodyHeight = target
            shapeCardWidth = targetWidth
            frameCardWidth = targetWidth
            return
        }
        guard target != frameBodyHeight || target != shapeBodyHeight
                || targetWidth != frameCardWidth || targetWidth != shapeCardWidth else { return }
        heightGeneration += 1
        let token = heightGeneration
        stateLogger.debug("size \(Int(self.frameCardWidth), privacy: .public)x\(Int(self.frameBodyHeight), privacy: .public) → \(Int(targetWidth), privacy: .public)x\(Int(target), privacy: .public)")
        let grows = target > frameBodyHeight || targetWidth > frameCardWidth
        if grows {
            // 커지는 쪽만 키운 프레임 (작아지는 쪽은 애니메이션이 끝날 때까지 그대로)
            frameBodyHeight = max(frameBodyHeight, target)
            frameCardWidth = max(frameCardWidth, targetWidth)
            onNeedsExpandedFrame()
        }
        let needsShrink = target < frameBodyHeight || targetWidth < frameCardWidth
        guard needsShrink else {
            withAnimation(Self.heightAnimation) {
                shapeBodyHeight = target
                contentBodyHeight = target
                shapeCardWidth = targetWidth
            }
            return
        }
        withAnimation(Self.heightAnimation, completionCriteria: .logicallyComplete) {
            shapeBodyHeight = target
            contentBodyHeight = target
            shapeCardWidth = targetWidth
        } completion: { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, token == self.heightGeneration else { return }
                self.frameBodyHeight = target
                self.frameCardWidth = targetWidth
                if self.state == .expanded || self.state == .editing {
                    self.onNeedsExpandedFrame()
                }
            }
        }
    }

    // MARK: 이벤트 처리 → 해야 할 일 실행

    private func send(_ event: NotchStateMachine.Event) {
        let effects = machine.handle(event)
        for text in machine.notes {
            stateLogger.debug("\(text, privacy: .public)")
        }
        state = machine.mode
        for effect in effects {
            perform(effect)
        }
    }

    private func perform(_ effect: NotchStateMachine.Effect) {
        switch effect {
        case .showPanel:
            onShow()

        case .showAlert(let token):
            guard let content = pendingAlert ?? alertContent else { break }
            pendingAlert = nil
            alertContent = content
            alertSize = computeAlertSize(content)
            alertFrameActive = true
            onNeedsCollapsedFrame()  // 프레임을 먼저 알림 크기로 (이벤트·지연 콜백에서 호출됨 — 레이아웃 중이 아님)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {  // 펼침과 같은 spring
                isAlertOpen = true
            }
            // 일회성 지연 (ARCHITECTURE §5 예외): 5초 뒤 줄임. ×·hover로 먼저 닫히면 token이 달라 무시된다
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.alertSeconds) { [weak self] in
                self?.send(.alertDismiss(token: token))
            }

        case .hideAlert(let token):
            withAnimation(.easeIn(duration: 0.3), completionCriteria: .logicallyComplete) {
                isAlertOpen = false
            } completion: { [weak self] in
                // 레이아웃 도중일 수 있으므로 다음 차례에 (§3.2)
                DispatchQueue.main.async { [weak self] in
                    self?.send(.alertHideFinished(token: token))
                }
            }

        case .removeAlertNow:
            clearAlertState()

        case .resetPanelView:
            resetViewState()

        case .highlightInPanel:
            guard let content = pendingAlert else { break }
            pendingAlert = nil
            bannerToken += 1
            let token = bannerToken
            panelBanner = content
            updateHeight()
            // 일회성 지연: 5초 뒤 강조 줄을 치운다
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.alertSeconds) { [weak self] in
                guard let self, token == self.bannerToken else { return }
                self.panelBanner = nil
                self.updateHeight()
            }

        case .hideImmediately:
            clearAlertState()
            bannerToken += 1
            panelBanner = nil
            focusResetToken += 1
            isDatePickerOpen = false
            draftDueDate = store.today
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                isShapeExpanded = false
                isContentVisible = false
            }
            onNeedsCollapsedFrame()
            onHide()
            resetViewState()  // 메뉴로 끔 → 다음에 켜면 목록·오늘 (PRD F12)

        case .schedulePeek(let token):
            // 일회성 지연 (ARCHITECTURE §5 예외): 켜기 1번당 1번
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.initialPeekSeconds) { [weak self] in
                self?.send(.peekElapsed(token: token))
            }

        case .scheduleExitGrace(let token):
            // 일회성 지연 (ARCHITECTURE §5 예외): 이탈 1번당 1번. 그사이 다시 들어오면 상태 머신이 무시한다
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.exitGraceSeconds) { [weak self] in
                self?.send(.exitGraceElapsed(token: token))
            }

        case .expand:
            stateLogger.debug("expand gen=\(self.machine.generation, privacy: .public)")
            store.refreshToday()  // 잠자기 중 자정이 지나 알림을 놓쳤을 때 대비 (펼칠 때 1번, 이벤트 방식)
            lms?.refreshDisplayNow()  // "마지막 동기화: n시간 전" 기준 시각 (T-007)
            // 펼치기 전에 내용에 맞는 높이를 애니메이션 없이 맞춘다 (T-004)
            heightGeneration += 1
            let h = targetBodyHeight
            frameBodyHeight = h
            shapeBodyHeight = h
            contentBodyHeight = h
            frameCardWidth = targetCardWidth
            shapeCardWidth = targetCardWidth
            onNeedsExpandedFrame()  // 프레임을 먼저 키우고 (마우스 이벤트·지연 콜백에서 호출됨 — 레이아웃 중이 아님)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {  // 그다음 애니메이션
                isShapeExpanded = true
            }
            withAnimation(.easeOut(duration: 0.18).delay(0.05)) {
                isContentVisible = true
            }
            onExpand()  // LMS 동기화 시도 (6시간 제한, 비동기라 여기서 화면이 바뀌지 않음)

        case .startCollapse(let token):
            stateLogger.debug("collapse gen=\(token, privacy: .public) byEscape=\(self.machine.collapsingByEscape, privacy: .public)")
            // 1) 내용이 먼저 흐려지고
            withAnimation(.easeOut(duration: 0.12)) {
                isContentVisible = false
            }
            // 2) 모양이 노치 크기로 줄며 위로 올라감 (전체 약 0.4초)
            withAnimation(.easeIn(duration: 0.3).delay(0.1), completionCriteria: .logicallyComplete) {
                isShapeExpanded = false
            } completion: { [weak self] in
                // ARCHITECTURE §3.2 / T-001c: 이 완료 콜백은 NSHostingView.layout() 도중에 불린다.
                // 여기서 바로 setFrame하면 창이 화면 밖으로 밀려난다 → 레이아웃이 끝난 다음 차례로 1번 미룬다 (지연 0, 반복 없음)
                DispatchQueue.main.async { [weak self] in
                    self?.send(.collapseAnimationFinished(token: token))
                }
            }

        case .shrinkFrame:
            if alertFrameActive { clearAlertState() }  // 노치 알림이 닫힌 뒤 노치 크기로
            onNeedsCollapsedFrame()  // collapseAnimationFinished는 main.async로 미뤄진 뒤 오므로 레이아웃 바깥
            // 화면 종류·달·날짜는 그대로 둔다 → 다시 펼치면 같은 화면 (PRD F12 직전 화면 유지, T-011)

        case .queryMouseInside(let token):
            let inside = isMouseInsidePanelNow()
            stateLogger.debug("after shrink: mouseInside=\(inside, privacy: .public) byEscape=\(self.machine.collapsingByEscape, privacy: .public)")
            send(.mouseCheckResult(token: token, inside: inside))

        case .endInputFocus(let resignKey):
            focusResetToken += 1
            if resignKey {
                onResignKey()
            } else {
                stateLogger.debug("end focus: clear focus only, resign key after collapse")
                onClearFocus()
            }

        case .resignKey:
            onResignKey()

        case .resyncTrackingAssumeInside:
            onResyncTrackingAssumeInside()

        case .addTodo:
            store.refreshToday()
            store.add(title: pendingTitle, dueDate: draftDueDate)
            stateLogger.debug("added due=\(self.draftDueDate.string, privacy: .public)")
            pendingTitle = ""
            // PRD F5: 추가 후 날짜는 오늘로. 달력 화면에서는 고른 날짜 그대로 (T-009)
            draftDueDate = panelMode == .calendar ? calendarSelected : store.today
            updateHeight()

        case .reapplyFrame:
            onReapplyFrame()

        case .collapseNow:
            // 화면이 바뀌어 새 위치로 옮김 (T-008): 애니메이션 없이 접힌 모양으로. 화면 종류·입력하던 글자는 그대로
            heightGeneration += 1  // 진행 중이던 높이 변경 완료 콜백 무시
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                isShapeExpanded = false
                isContentVisible = false
            }

        case .setDatePicker(let open):
            isDatePickerOpen = open
            updateHeight()

        case .focusInput:
            onFocusInput()
            focusRequestToken += 1
        }
    }
}
