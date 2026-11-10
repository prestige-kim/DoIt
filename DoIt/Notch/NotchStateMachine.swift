import Foundation
import CoreGraphics

/// 노치 상태 (PRD F3)
enum NotchState: String {
    case off, idle, expanded, editing
    /// 노치 알림이 떠 있음 (T-005, 다이나믹 아일랜드 방식). IDLE 또는 OFF(앱 실행 중)에서 들어온다
    case alert
}

/// 노치 상태 머신 — **판단만** 한다. AppKit·SwiftUI·시계를 쓰지 않는 순수 값 타입이라 단위 테스트로 고정할 수 있다. (T-003)
/// 이벤트를 받으면 상태를 바꾸고 "해야 할 일(Effect)" 목록을 돌려준다. 실행은 `NotchViewModel`(어댑터)이 한다.
/// 전환표는 `docs/reports/T-003.md` 참고.
struct NotchStateMachine {
    // MARK: 입력 이벤트
    enum Event: Equatable {
        case turnOn
        case turnOff
        /// 이미 실행 중인 DoIt을 다시 엶 (Finder·Spotlight, T-010): 켜기 미리보기처럼 한 번 펼쳤다 접는다. OFF면 켜지 않는다
        case reopened
        /// 켜기 후 3초 미리보기가 끝남 (어댑터가 일회성 지연으로 보냄. 테스트는 바로 주입)
        case peekElapsed(token: Int)
        case mouseEntered
        /// `spurious`: 프레임 변경 직후 + 좌표가 패널 안인 가짜 이탈 (`HoverGeometry.isSpuriousExit`로 판정)
        case mouseExited(spurious: Bool)
        /// 이탈 뒤 유예(0.1초)가 끝남 (어댑터가 일회성 지연으로 보냄. 테스트는 바로 주입) (T-008)
        case exitGraceElapsed(token: Int)
        case inputFocusGained
        case inputFocusLost
        /// Enter. `hasText`: 공백 아닌 글자가 있는지
        case submit(hasText: Bool)
        /// Esc. 날짜 영역이 열려 있으면 1번째는 날짜 영역만 닫는다 (T-004)
        case escape
        case panelResignedKey
        /// 날짜 버튼을 누름 (열려 있으면 닫고, 닫혀 있으면 연다) (T-004)
        case datePickerToggled
        /// 날짜 영역에서 날짜를 고름 → 영역을 닫고 입력창으로 (T-004)
        case datePicked
        /// 접힘 애니메이션 완료 (어댑터가 레이아웃 바깥으로 미룬 뒤 보냄 — ARCHITECTURE §3.2)
        case collapseAnimationFinished(token: Int)
        /// 프레임을 줄인 직후 1회 확인한 마우스 위치 결과 (`.queryMouseInside`에 대한 응답)
        case mouseCheckResult(token: Int, inside: Bool)
        case screenChanged
        /// 노치 위치·크기가 실제로 바뀜 (모니터 연결·해제, 주 디스플레이 변경, 해상도) (T-008).
        /// 펼침·입력·알림 중이면 정리하고 접힌 상태로 새 위치에 놓는다
        case displayChanged
        /// 노치 알림 도착 (T-005). 내용은 어댑터가 들고 있다
        case alertArrived
        /// 5초가 지남 (token이 다르면 오래된 것 → 무시). 마우스가 알림 위에 있으면 나갈 때까지 미룬다
        case alertDismiss(token: Int)
        /// `×` 누름 → 마우스 위치와 관계없이 바로 닫음
        case alertClose
        /// 노치 알림이 줄어드는 애니메이션이 끝남 (어댑터가 레이아웃 바깥으로 미룬 뒤 보냄)
        case alertHideFinished(token: Int)
        /// 노치 알림(본문)을 누름 → 패널로 펼침. **마우스를 올리는 것만으로는 펼치지 않는다** (× 누르기 위해, 2026-11-08 사용자 결정)
        case alertTapped
    }

    // MARK: 해야 할 일
    enum Effect: Equatable {
        /// 패널을 화면에 띄움 (위치 계산 포함)
        case showPanel
        /// 애니메이션 없이 바로 접고 숨김 (끄기)
        case hideImmediately
        /// 3초 뒤 `.peekElapsed(token)`을 1번 보내 달라
        case schedulePeek(token: Int)
        /// 유예 시간 뒤 `.exitGraceElapsed(token)`을 1번 보내 달라 (T-008: 너무 빨리 접히지 않게)
        case scheduleExitGrace(token: Int)
        /// 프레임을 펼친 크기로 키운 뒤 펼침 애니메이션
        case expand
        /// 접힘 애니메이션 시작. 끝나면 `.collapseAnimationFinished(token)`
        case startCollapse(token: Int)
        /// 프레임을 노치 크기로 줄임
        case shrinkFrame
        /// 마우스가 지금 패널 안인지 1번 확인해 `.mouseCheckResult(token, inside)`로 알려 달라
        case queryMouseInside(token: Int)
        /// 입력창 포커스 해제. `resignKey`가 true면 key도 내려놓음(숨김→다시 띄움, 마우스가 밖일 때만 안전)
        case endInputFocus(resignKey: Bool)
        /// key를 내려놓음 (key가 아니면 아무것도 안 함)
        case resignKey
        /// hover 추적 영역을 "마우스가 안에 있음"으로 다시 만듦 (AppKit의 안/밖 판단을 앱과 맞춤)
        case resyncTrackingAssumeInside
        /// 할 일 추가 (Enter)
        case addTodo
        /// 현재 상태에 맞는 프레임을 다시 적용 (화면 구성 변경)
        case reapplyFrame
        /// 애니메이션 없이 바로 접힌 모양으로 (화면이 바뀌어 새 위치로 옮길 때, T-008). 패널은 계속 보인다
        case collapseNow
        /// 날짜 선택 영역을 열거나 닫음 (패널 높이도 다시 계산) (T-004)
        case setDatePicker(open: Bool)
        /// 패널을 key로 만들고 입력창에 포커스 (날짜 영역 사용 중 Esc를 받기 위해) (T-004)
        case focusInput
        /// 노치 알림을 띄움: 프레임을 알림 크기로 키우고 넓어지는 애니메이션, 5초 뒤 `.alertDismiss(token)` (T-005)
        case showAlert(token: Int)
        /// 노치 알림을 줄임. 끝나면 `.alertHideFinished(token)`
        case hideAlert(token: Int)
        /// 노치 알림을 애니메이션 없이 바로 치움 (패널로 펼칠 때·끌 때)
        case removeAlertNow
        /// 펼친 패널·입력 중: 노치 알림 대신 패널 맨 위에 같은 내용 강조 (5초)
        case highlightInPanel
        /// 알림에서 펼칠 때: 목록 화면·오늘로 (PRD F8)
        case resetPanelView
    }

    // MARK: 상태
    private(set) var mode: NotchState = .off
    /// 마우스가 패널 안인지 (추적 이벤트·1회 확인으로만 갱신)
    private(set) var mouseInside = false
    /// 켜기 직후 3초 미리보기 중 (이 동안은 이탈로 접지 않음 — T-003 결정 2-1)
    private(set) var inPeek = false
    /// Esc로 접은 뒤 마우스가 노치 위에 남음 → 한 번 나갈 때까지 펼치지 않음 (PRD F3)
    private(set) var blockExpandUntilExit = false
    /// 날짜 선택 영역이 열려 있음 → EDITING처럼 마우스가 나가도 접지 않음 (PRD F5, T-004)
    private(set) var datePickerOpen = false
    /// 진행 중인 접힘이 Esc로 시작됐는지
    private(set) var collapsingByEscape = false
    /// 오래된 애니메이션 완료·마우스 확인 결과를 무시하기 위한 세대 번호
    private(set) var generation = 0
    /// 오래된 미리보기 종료 이벤트를 무시하기 위한 번호 (켜기/끄기마다 바뀜)
    private(set) var peekToken = 0
    /// 이탈 유예 번호 (T-008). 이탈마다 새로 받고, 다시 들어오면 바뀌어 기다리던 접힘이 무시된다
    private(set) var exitGraceToken = 0
    /// 이탈 뒤 유예 중 (이 동안 다시 들어오면 접지 않는다)
    private(set) var exitGracePending = false
    /// 노치 알림 번호 (오래된 5초 지연·줄임 완료를 무시)
    private(set) var alertToken = 0
    /// 노치 알림이 줄어드는 중
    private(set) var alertClosing = false
    /// 마우스가 알림 위에 있는 동안 5초가 지남 → 마우스가 나가면 닫는다
    private(set) var alertDismissDeferred = false
    /// OFF(메뉴로 끔)에서 알림으로 잠깐 보이는 중 → 알림이 닫히거나, 알림에서 펼친 패널이 접히면 다시 OFF (T-005)
    private(set) var returnToOff = false

    /// 진단 로그용: 마지막 처리에서 무시된 이유 등
    private(set) var notes: [String] = []
    private var effects: [Effect] = []

    /// 사용자가 켠 상태인지 (OFF에서 알림으로 잠깐 보이는 동안은 꺼진 것으로 본다)
    var isOn: Bool { mode != .off && !returnToOff }

    // MARK: 처리

    /// 이벤트 하나를 처리하고 해야 할 일을 순서대로 돌려준다.
    mutating func handle(_ event: Event) -> [Effect] {
        effects = []
        notes = []
        if mode == .off, event != .turnOn, event != .alertArrived, event != .reopened {
            if event != .screenChanged, event != .displayChanged { note("ignored (off): \(event)") }
            return []
        }
        if mode == .alert {
            handleInAlert(event)
            return effects
        }
        switch event {
        case .turnOn:
            if returnToOff {
                // OFF에서 알림으로 펼친 패널이 보이는 중에 켬 → 그대로 켜진 상태로
                returnToOff = false
                note("turned on while visible from alert")
            } else {
                turnOn()
            }
        case .turnOff: turnOff()
        case .reopened: reopened()
        case .peekElapsed(let token): peekElapsed(token)
        case .mouseEntered: mouseEntered()
        case .mouseExited(let spurious): mouseExited(spurious: spurious)
        case .exitGraceElapsed(let token): exitGraceElapsed(token)
        case .inputFocusGained: focusGained()
        case .inputFocusLost:
            if mode == .editing, datePickerOpen {
                // 달력을 누르면 포커스가 입력창에서 달력으로 옮겨 간다 → 편집이 끝난 것이 아님 (T-004)
                note("focus lost while date picker open: keep editing")
            } else if mode == .editing {
                finishEditing(collapseIfOutside: true)
            }
        case .submit(let hasText):
            if hasText { effects.append(.addTodo) }
            // T-001c 사용자 결정: Enter를 누르면 마우스 위치와 상관없이 입력을 끝낸다
            if mode == .editing { finishEditing(collapseIfOutside: true) }
        case .escape: escape()
        case .panelResignedKey:
            if mode == .editing { finishEditing(collapseIfOutside: true) }
        case .datePickerToggled:
            if datePickerOpen { closeDatePicker() } else { openDatePicker() }
        case .datePicked:
            if datePickerOpen { closeDatePicker() }
        case .collapseAnimationFinished(let token): collapseFinished(token)
        case .mouseCheckResult(let token, let inside): mouseCheck(token, inside)
        case .screenChanged: effects.append(.reapplyFrame)
        case .displayChanged: displayChanged()
        case .alertArrived: alertArrived()
        case .alertDismiss, .alertClose, .alertHideFinished, .alertTapped:
            note("alert event ignored: mode=\(mode.rawValue)")
        }
        return effects
    }

    // MARK: 노치 알림 (T-005, ARCHITECTURE §3.6)

    /// 알림 도착 (알림 상태가 아닐 때)
    private mutating func alertArrived() {
        switch mode {
        case .off:
            // 앱이 실행 중이면 OFF에서도 띄운다. 닫히면 다시 OFF
            returnToOff = true
            mouseInside = false
            effects.append(.showPanel)
            startAlert()
        case .idle:
            startAlert()
        case .expanded, .editing:
            // 펼친 패널·입력 중: 노치 알림 대신 패널 위쪽 강조 (입력 방해 없음)
            effects.append(.highlightInPanel)
        case .alert:
            break
        }
    }

    private mutating func startAlert() {
        exitGracePending = false  // 기다리던 이탈 유예는 버린다 (T-008)
        generation += 1  // 진행 중이던 접힘 완료·마우스 확인 결과는 무시
        alertToken += 1
        alertClosing = false
        alertDismissDeferred = false
        blockExpandUntilExit = false
        collapsingByEscape = false
        mode = .alert
        effects.append(.showAlert(token: alertToken))
    }

    /// 알림 상태에서의 이벤트
    private mutating func handleInAlert(_ event: Event) {
        switch event {
        case .alertArrived:
            // 새 알림이 오면 내용을 바꿔 다시 5초
            alertToken += 1
            alertClosing = false
            alertDismissDeferred = false
            effects.append(.showAlert(token: alertToken))
        case .alertDismiss(let token):
            guard token == alertToken, !alertClosing else {
                note("alert dismiss ignored: token=\(token) current=\(alertToken) closing=\(alertClosing)")
                return
            }
            if mouseInside {
                // 읽는 중 → 마우스가 나갈 때 닫는다
                alertDismissDeferred = true
                note("alert dismiss deferred: mouse on alert")
                return
            }
            hideAlert()
        case .alertClose:
            guard !alertClosing else { return }
            hideAlert()
        case .alertHideFinished(let token):
            guard token == alertToken, alertClosing else {
                note("alert hide finish ignored: token=\(token) current=\(alertToken)")
                return
            }
            alertClosing = false
            if returnToOff {
                returnToOff = false
                mode = .off
                mouseInside = false
                effects.append(.hideImmediately)
            } else {
                mode = .idle
                generation += 1
                effects.append(.shrinkFrame)
                effects.append(.queryMouseInside(token: generation))  // 마우스가 노치 위면 펼침 (접힘 완료와 같은 규칙)
            }
        case .mouseEntered:
            // 올리기만 해서는 펼치지 않는다 (× 를 누를 수 있게). 5초 자동 닫힘은 나갈 때까지 미룸
            mouseInside = true
        case .alertTapped:
            mouseInside = true
            openPanelFromAlert()
        case .mouseExited(let spurious):
            if spurious {
                note("exit ignored (alert): spurious")
                effects.append(.resyncTrackingAssumeInside)
            } else {
                mouseInside = false
                if alertDismissDeferred, !alertClosing { hideAlert() }
            }
        case .turnOff:
            alertToken += 1
            alertClosing = false
            returnToOff = false
            effects.append(.removeAlertNow)
            turnOff()
        case .turnOn:
            guard returnToOff else { return }
            // OFF에서 뜬 알림 중에 켬 → 알림을 치우고 평소 켜기 (3초 미리보기)
            alertToken += 1
            alertClosing = false
            returnToOff = false
            effects.append(.removeAlertNow)
            mode = .off
            turnOn()
        case .screenChanged:
            effects.append(.reapplyFrame)
        case .displayChanged:
            // T-008: 알림을 치우고 재배치. OFF에서 뜬 알림이면 다시 OFF(숨김)
            alertToken += 1  // 남은 5초 지연·줄임 완료 무시
            alertClosing = false
            alertDismissDeferred = false
            effects.append(.removeAlertNow)
            note("display changed during alert: alert removed")
            if returnToOff {
                returnToOff = false
                mode = .off
                mouseInside = false
                effects.append(.hideImmediately)
            } else {
                mode = .idle
                generation += 1
                mouseInside = false
                effects.append(.reapplyFrame)
                effects.append(.queryMouseInside(token: generation))
            }
        default:
            note("ignored (alert): \(event)")
        }
    }

    private mutating func hideAlert() {
        alertClosing = true
        alertDismissDeferred = false
        effects.append(.hideAlert(token: alertToken))
    }

    /// 알림에서 패널로: 목록·오늘로 펼친다 (OFF에서 왔으면 접힐 때 다시 OFF)
    private mutating func openPanelFromAlert() {
        alertToken += 1  // 남은 5초 지연·줄임 완료 무시
        alertClosing = false
        effects.append(.removeAlertNow)
        effects.append(.resetPanelView)
        mode = .idle
        expand()
    }

    // MARK: 켜기/끄기

    private mutating func turnOn() {
        guard mode == .off else { return }
        mode = .idle
        mouseInside = false
        blockExpandUntilExit = false
        collapsingByEscape = false
        effects.append(.showPanel)
        startPeek()
    }

    /// 다시 열기 (T-010): 3초 미리보기를 한 번. OFF면 켜지 않고 미리보기만 → 접히면 다시 OFF (알림에서 펼친 패널과 같은 규칙).
    /// 이미 펼쳐져 있거나 입력 중이면 아무것도 하지 않는다 (알림 중 다시 열기는 알림 처리에서 무시)
    private mutating func reopened() {
        switch mode {
        case .off:
            returnToOff = true
            mode = .idle
            mouseInside = false
            blockExpandUntilExit = false
            collapsingByEscape = false
            effects.append(.showPanel)
            startPeek()
        case .idle:
            startPeek()
        case .expanded, .editing, .alert:
            note("reopened while \(mode.rawValue): nothing to do")
        }
    }

    private mutating func startPeek() {
        inPeek = true
        peekToken += 1
        expand()
        effects.append(.schedulePeek(token: peekToken))
    }

    private mutating func turnOff() {
        exitGracePending = false  // 기다리던 이탈 유예는 버린다 (T-008)
        generation += 1
        peekToken += 1
        returnToOff = false
        mode = .off
        inPeek = false
        datePickerOpen = false
        blockExpandUntilExit = false
        collapsingByEscape = false
        effects.append(.hideImmediately)
    }

    /// T-003 결정 2-1: 3초가 지난 시점에 마우스가 밖이면 접고, 안이면 펼친 채로 두고 이후는 일반 hover 규칙
    private mutating func peekElapsed(_ token: Int) {
        guard token == peekToken, inPeek else {
            note("peek ignored: token=\(token) current=\(peekToken) inPeek=\(inPeek)")
            return
        }
        inPeek = false
        if mode == .expanded, !mouseInside {
            collapse()
        } else {
            note("peek end: stay (mode=\(mode.rawValue) mouseInside=\(mouseInside))")
        }
    }

    // MARK: Hover

    private mutating func mouseEntered() {
        mouseInside = true
        if exitGracePending {
            exitGracePending = false
            exitGraceToken += 1
            note("re-entered within exit grace: stay expanded")
        }
        if blockExpandUntilExit {
            note("entered: blocked until exit (after Esc)")
            return
        }
        if mode == .idle { expand() }
    }

    private mutating func mouseExited(spurious: Bool) {
        if spurious {
            // T-003 결정 2-3: 프레임 변경 직후 + 좌표가 패널 안 → 가짜. 무시하되 AppKit의 판단을 "안"으로 맞춰
            // 진짜로 나갈 때 이탈 이벤트가 다시 오게 한다 (펼친 채 갇히는 것 방지)
            note("exit ignored: spurious")
            effects.append(.resyncTrackingAssumeInside)
            return
        }
        mouseInside = false
        if blockExpandUntilExit {
            blockExpandUntilExit = false
            note("exit: expand unblocked")
            // Esc 때 미뤄 둔 key 내려놓기 (이제 마우스가 밖이라 깜빡임 없음)
            if mode == .idle { effects.append(.resignKey) }
        }
        if mode == .expanded {
            if inPeek { note("exit during peek: stay expanded") }
            else if datePickerOpen { note("exit while date picker open: stay expanded") }
            else {
                // T-008 사용자 결정: 살짝 벗어나자마자 접히지 않게 0.1초 유예 (ARCHITECTURE §3.3 허용 범위)
                exitGraceToken += 1
                exitGracePending = true
                effects.append(.scheduleExitGrace(token: exitGraceToken))
            }
        }
    }

    /// 이탈 유예가 끝남: 그동안 다시 들어오지 않았고 여전히 펼친 상태(입력·달력·미리보기 아님)면 접는다
    private mutating func exitGraceElapsed(_ token: Int) {
        guard exitGracePending, token == exitGraceToken else {
            note("exit grace ignored: token=\(token) current=\(exitGraceToken)")
            return
        }
        exitGracePending = false
        guard mode == .expanded, !mouseInside, !inPeek, !datePickerOpen else {
            note("exit grace elapsed but no collapse: mode=\(mode.rawValue) inside=\(mouseInside)")
            return
        }
        collapse()
    }

    // MARK: 화면 구성 변경 (T-008)

    /// 노치 위치·크기가 바뀜: 펼침·입력·달력 영역을 정리하고 애니메이션 없이 접힌 상태로 새 위치에 놓는다.
    /// 입력하던 글자는 버리지 않는다(포커스만 끝냄 → 입력창에 남음). 접힌 뒤 마우스가 새 노치 위면 일반 규칙대로 펼친다
    private mutating func displayChanged() {
        exitGracePending = false  // 기다리던 이탈 유예는 버린다 (T-008)
        let wasOpen = mode == .expanded || mode == .editing
        if mode == .editing {
            mode = .expanded
            effects.append(.endInputFocus(resignKey: true))  // 마우스는 새 노치 위가 아니므로 key도 내려놓는다
        }
        if datePickerOpen {
            datePickerOpen = false
            effects.append(.setDatePicker(open: false))
        }
        inPeek = false
        blockExpandUntilExit = false
        collapsingByEscape = false
        mouseInside = false
        generation += 1  // 진행 중이던 접힘 완료·마우스 확인 결과는 무시
        if wasOpen {
            note("display changed while \(mode.rawValue): collapse now")
            mode = .idle
            effects.append(.collapseNow)
        }
        if returnToOff {
            // 알림에서 펼친 패널(OFF에서 옴) → 다시 OFF
            returnToOff = false
            mode = .off
            effects.append(.hideImmediately)
            return
        }
        effects.append(.reapplyFrame)
        effects.append(.queryMouseInside(token: generation))
    }

    // MARK: 편집

    private mutating func focusGained() {
        // 이미 편집 중이면 (날짜 영역을 닫고 입력창으로 포커스를 되돌린 경우 등) 그대로
        if mode == .editing { return }
        // T-001b 방어: 마우스가 밖일 때 생긴 포커스는 사용자가 클릭한 것이 아니다 → 무시하고 풀기
        guard mouseInside else {
            note("focus ignored: mouse outside")
            effects.append(.endInputFocus(resignKey: true))
            return
        }
        guard mode == .expanded || mode == .idle else { return }
        exitGracePending = false  // 기다리던 이탈 유예는 버린다 (T-008)
        if mode == .idle { expand() }
        mode = .editing
        inPeek = false  // T-003 결정 2-1: 미리보기 중 입력창을 누르면 일반 편집 규칙
    }

    private mutating func escape() {
        if datePickerOpen {
            // T-004: Esc 1번째는 날짜 영역만 닫는다
            closeDatePicker()
            return
        }
        guard mode == .editing || mode == .expanded else {
            note("escape ignored: mode=\(mode.rawValue)")
            return
        }
        finishEditing(collapseIfOutside: false)
        collapse(byEscape: true)
    }

    private mutating func finishEditing(collapseIfOutside: Bool) {
        guard mode == .editing else { return }
        mode = .expanded
        if datePickerOpen {
            datePickerOpen = false
            effects.append(.setDatePicker(open: false))
        }
        // 마우스가 패널 위에서 key를 내려놓으면 가짜 이탈·진입으로 깜빡인다 → 커서만 지우고 key는 접힘 뒤로 (T-001c)
        effects.append(.endInputFocus(resignKey: !mouseInside))
        if collapseIfOutside, !mouseInside { collapse() }
    }

    // MARK: 날짜 선택 영역 (T-004)

    private mutating func openDatePicker() {
        guard mode == .expanded || mode == .editing else { return }
        guard mouseInside else {
            note("date picker open ignored: mouse outside")
            return
        }
        datePickerOpen = true
        inPeek = false
        effects.append(.setDatePicker(open: true))
        effects.append(.focusInput)
    }

    private mutating func closeDatePicker() {
        datePickerOpen = false
        effects.append(.setDatePicker(open: false))
        if mode == .editing {
            effects.append(.focusInput)  // 달력에 있던 포커스를 입력창으로 되돌린다
        } else if mode == .expanded, !mouseInside, !inPeek {
            collapse()  // 편집이 아니었고 마우스가 이미 밖이면 일반 이탈 규칙대로 접는다
        }
    }

    // MARK: 펼침/접힘

    private mutating func expand() {
        guard mode == .idle else { return }
        generation += 1
        mode = .expanded
        effects.append(.expand)
    }

    private mutating func collapse(byEscape: Bool = false) {
        exitGracePending = false  // 기다리던 이탈 유예는 버린다 (T-008)
        guard mode == .expanded else { return }
        if datePickerOpen {
            datePickerOpen = false
            effects.append(.setDatePicker(open: false))
        }
        generation += 1
        collapsingByEscape = byEscape
        mode = .idle
        effects.append(.startCollapse(token: generation))
    }

    private mutating func collapseFinished(_ token: Int) {
        guard token == generation, mode == .idle else {
            note("collapse finish ignored: token=\(token) gen=\(generation) mode=\(mode.rawValue)")
            return
        }
        effects.append(.shrinkFrame)
        if returnToOff {
            // 알림에서 펼친 패널이 접힘 → 다시 OFF 규칙 (hover 감지 없음, T-005)
            returnToOff = false
            mode = .off
            mouseInside = false
            inPeek = false
            blockExpandUntilExit = false
            collapsingByEscape = false
            effects.append(.hideImmediately)
            return
        }
        effects.append(.queryMouseInside(token: token))
    }

    /// 줄어든 프레임 기준 1회 확인 결과 (T-001b): 마우스가 노치 위면 다시 펼친다. 단 Esc로 접었으면 펼치지 않는다 (PRD F3)
    private mutating func mouseCheck(_ token: Int, _ inside: Bool) {
        guard token == generation, mode == .idle else {
            note("mouse check ignored: token=\(token) gen=\(generation) mode=\(mode.rawValue)")
            return
        }
        mouseInside = inside
        let byEscape = collapsingByEscape
        collapsingByEscape = false
        if inside, byEscape {
            blockExpandUntilExit = true
            effects.append(.resyncTrackingAssumeInside)
            note("after Esc: mouse on notch → stay collapsed until exit")
        } else if inside {
            expand()
        } else {
            effects.append(.resignKey)  // 편집 후 미뤄 둔 key 내려놓기
        }
    }

    private mutating func note(_ text: String) { notes.append(text) }
}

// MARK: - 위치 판정 (순수 함수)

/// 마우스가 패널 안인지, 이탈 이벤트가 가짜인지 판정한다. (T-003 결정 2-2, 2-3)
enum HoverGeometry {
    /// 패널 안 판정. AppKit 추적 영역과 같은 규칙: **왼쪽·위쪽 경계는 안, 오른쪽·아래쪽 경계는 밖.**
    /// 근거(로그): 진입은 화면 맨 위 y = maxY에서 일어나고, 진짜 이탈은 x = maxX, y = minY 좌표로 찍힌다.
    /// 화면 맨 위 끝(y = 화면 maxY = 패널 maxY)에 붙인 마우스도 안으로 친다.
    static func contains(_ frame: CGRect, _ p: CGPoint) -> Bool {
        p.x >= frame.minX && p.x < frame.maxX && p.y > frame.minY && p.y <= frame.maxY
    }

    /// 프레임 변경 직후로 보는 시간. 관측된 가짜 이탈은 프레임 변경 후 5~59ms (T-003·T-004 보고서) → 여유를 두어 150ms
    static let spuriousExitWindow: TimeInterval = 0.15

    /// 이 이탈 이벤트가 프레임 변경(또는 창을 다시 띄움) 직후에 왔는지.
    /// - Parameters:
    ///   - eventTime: 이벤트 시각 (`NSEvent.timestamp`, 부팅 후 경과 초)
    ///   - lastFrameChange: 마지막 프레임 변경 시각 (같은 시계)
    static func isRightAfterFrameChange(eventTime: TimeInterval, lastFrameChange: TimeInterval?) -> Bool {
        guard let lastFrameChange else { return false }
        let elapsed = eventTime - lastFrameChange
        return elapsed >= 0 && elapsed <= spuriousExitWindow
    }

    /// 가짜 이탈인지 (T-008). 프레임 변경 직후의 이탈은 **이벤트 좌표를 믿지 않는다**:
    /// 그 순간 엉뚱한 좌표(패널에서 550~700pt 떨어진 곳)가 찍힌 일이 있었다 (T-004 문제·한계 1).
    /// 대신 `currentMouse`로 실제 마우스 위치를 **이 이벤트에 대해 1번만** 읽어, 감지 영역 안이면 가짜로 본다.
    /// 프레임 변경 직후가 아니면 `currentMouse`를 부르지 않고 이벤트대로(진짜 이탈) 처리한다.
    /// - Parameter hoverRect: 마우스 감지 영역 (패널 프레임)
    static func isSpuriousExit(eventTime: TimeInterval, lastFrameChange: TimeInterval?, hoverRect: CGRect,
                               currentMouse: () -> CGPoint) -> Bool {
        guard isRightAfterFrameChange(eventTime: eventTime, lastFrameChange: lastFrameChange) else { return false }
        return contains(hoverRect, currentMouse())
    }
}

