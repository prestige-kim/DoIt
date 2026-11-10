import XCTest
@testable import DoIt

/// T-003 상태 머신 테스트. 시계·마우스·AppKit 없이 이벤트 주입만으로 돈다.
final class NotchStateMachineTests: XCTestCase {

    /// 어댑터 흉내: 이벤트를 보내고, 접힘 애니메이션 완료·마우스 1회 확인처럼 어댑터가 되돌려 보내는 이벤트를 대신 보낸다.
    private struct Harness {
        var m = NotchStateMachine()
        /// 프레임을 줄인 직후 1회 확인했을 때 마우스가 패널 안인지 (테스트가 정함)
        var mouseOnNotchAfterShrink = false
        /// 지금까지 나온 모든 Effect
        var log: [NotchStateMachine.Effect] = []
        var lastPeekToken: Int?
        var lastCollapseToken: Int?
        /// 이탈 유예(T-008)가 자동으로 끝나게 할지
        var autoExitGrace = true
        var lastExitGraceToken: Int?

        @discardableResult
        mutating func send(_ e: NotchStateMachine.Event) -> [NotchStateMachine.Effect] {
            let effects = m.handle(e)
            log += effects
            for effect in effects {
                switch effect {
                case .schedulePeek(let t): lastPeekToken = t
                case .startCollapse(let t): lastCollapseToken = t
                case .queryMouseInside(let t):
                    send(.mouseCheckResult(token: t, inside: mouseOnNotchAfterShrink))
                case .scheduleExitGrace(let t):
                    // 기본: 유예(0.1초) 동안 다시 들어오지 않음 → 바로 경과를 보낸다. 유예 중 동작을 볼 때는 false
                    lastExitGraceToken = t
                    if autoExitGrace { send(.exitGraceElapsed(token: t)) }
                default: break
                }
            }
            return effects
        }

        mutating func peekElapsed() { send(.peekElapsed(token: lastPeekToken ?? -1)) }

        /// 접힘 애니메이션을 끝까지 진행
        mutating func finishCollapse() { send(.collapseAnimationFinished(token: lastCollapseToken ?? -1)) }

        var mode: NotchState { m.mode }
    }

    // MARK: 켜기·미리보기 (T-003 결정 2-1)

    func testTurnOnThenPeekElapsedCollapses() {
        var h = Harness()
        let effects = h.send(.turnOn)
        XCTAssertEqual(effects.first, .showPanel)
        XCTAssertTrue(effects.contains(.expand))
        XCTAssertEqual(h.mode, .expanded)
        h.peekElapsed()
        XCTAssertEqual(h.mode, .idle)
        h.finishCollapse()
        XCTAssertTrue(h.log.contains(.shrinkFrame))
        XCTAssertEqual(h.mode, .idle)
    }

    func testExitDuringPeekDoesNotCollapse() {
        // 켤 때 누른 메뉴 위치가 펼친 패널 안이라 진입 → 이탈이 생기는 경우
        var h = Harness()
        h.send(.turnOn)
        h.send(.mouseEntered)
        h.send(.mouseExited(spurious: false))
        XCTAssertEqual(h.mode, .expanded, "3초 미리보기 동안은 이탈로 접지 않음")
        h.peekElapsed()
        XCTAssertEqual(h.mode, .idle, "3초가 지났을 때 마우스가 밖이면 접힘")
    }

    func testPeekElapsedWithMouseInsideStaysThenExitCollapses() {
        var h = Harness()
        h.send(.turnOn)
        h.send(.mouseEntered)
        h.peekElapsed()
        XCTAssertEqual(h.mode, .expanded, "3초가 지났을 때 마우스가 안이면 펼친 채")
        h.send(.mouseExited(spurious: false))
        XCTAssertEqual(h.mode, .idle, "이후는 일반 hover 규칙")
    }

    func testStalePeekFromPreviousTurnOnIsIgnored() {
        var h = Harness()
        h.send(.turnOn)
        let oldToken = h.lastPeekToken!
        h.send(.turnOff)
        h.send(.turnOn)
        h.send(.mouseEntered)
        h.send(.mouseExited(spurious: false))
        h.send(.peekElapsed(token: oldToken))  // 이전 켜기의 3초
        XCTAssertEqual(h.mode, .expanded, "이전 켜기의 미리보기 종료는 무시")
        XCTAssertTrue(h.m.inPeek)
    }

    func testFocusDuringPeekFollowsEditingRules() {
        var h = Harness()
        h.send(.turnOn)
        h.send(.mouseEntered)
        h.send(.inputFocusGained)
        XCTAssertEqual(h.mode, .editing)
        XCTAssertFalse(h.m.inPeek, "입력창을 누르면 미리보기 끝")
        h.peekElapsed()
        XCTAssertEqual(h.mode, .editing, "편집 중에는 3초가 지나도 접지 않음")
    }

    // MARK: hover

    func testReenterDuringCollapseReexpands() {
        var h = Harness()
        h.send(.turnOn); h.peekElapsed(); h.finishCollapse()
        h.send(.mouseEntered)
        XCTAssertEqual(h.mode, .expanded)
        h.send(.mouseExited(spurious: false))
        XCTAssertEqual(h.mode, .idle, "접힘 시작")
        let staleToken = h.lastCollapseToken!
        h.send(.mouseEntered)  // 완료 전 재진입
        XCTAssertEqual(h.mode, .expanded, "다시 펼침")
        let before = h.log.count
        h.send(.collapseAnimationFinished(token: staleToken))  // 앞선 접힘의 완료 콜백이 늦게 옴
        XCTAssertEqual(h.mode, .expanded)
        XCTAssertFalse(h.log[before...].contains(.shrinkFrame), "오래된 완료는 프레임을 줄이지 않음")
    }

    func testCollapseFinishWithMouseOnNotchReexpands() {
        // T-001b: 일반 접힘 뒤 1회 확인에서 마우스가 노치 위면 다시 펼친다
        var h = Harness()
        h.send(.turnOn); h.send(.mouseEntered); h.peekElapsed()
        h.send(.mouseExited(spurious: false))
        h.mouseOnNotchAfterShrink = true
        h.finishCollapse()
        XCTAssertEqual(h.mode, .expanded)
    }

    // MARK: 편집

    func testFocusWhileMouseOutsideIsIgnored() {
        var h = Harness()
        h.send(.turnOn)
        let effects = h.send(.inputFocusGained)
        XCTAssertEqual(h.mode, .expanded, "editing 아님")
        XCTAssertEqual(effects, [.endInputFocus(resignKey: true)])
    }

    func testEditingSurvivesExitThenEnterEndsEditingAndCollapsesWhenOutside() {
        var h = Harness()
        h.send(.turnOn); h.peekElapsed(); h.finishCollapse()
        h.send(.mouseEntered)
        h.send(.inputFocusGained)
        XCTAssertEqual(h.mode, .editing)
        h.send(.mouseExited(spurious: false))
        XCTAssertEqual(h.mode, .editing, "편집 중에는 이탈해도 유지")
        let effects = h.send(.submit(hasText: true))
        XCTAssertEqual(effects.first, .addTodo)
        XCTAssertTrue(effects.contains(.endInputFocus(resignKey: true)), "마우스가 밖이면 key도 내려놓음")
        XCTAssertEqual(h.mode, .idle, "Enter → expanded → 마우스가 밖이라 바로 접힘")
    }

    func testEnterWithMouseInsideStaysExpandedUntilExit() {
        var h = Harness()
        h.send(.turnOn); h.peekElapsed(); h.finishCollapse()
        h.send(.mouseEntered)
        h.send(.inputFocusGained)
        let effects = h.send(.submit(hasText: false))
        XCTAssertFalse(effects.contains(.addTodo), "빈 입력은 추가하지 않음")
        XCTAssertTrue(effects.contains(.endInputFocus(resignKey: false)), "마우스가 안이면 커서만 지움 (깜빡임 방지)")
        XCTAssertEqual(h.mode, .expanded)
        h.send(.mouseExited(spurious: false))
        XCTAssertEqual(h.mode, .idle)
        h.finishCollapse()
        XCTAssertEqual(h.log.last, .resignKey, "접힌 뒤 미뤄 둔 key 내려놓기")
    }

    func testEscapeWithMouseOnNotchStaysCollapsedUntilExit() {
        var h = Harness()
        h.send(.turnOn); h.peekElapsed(); h.finishCollapse()
        h.send(.mouseEntered)
        h.send(.inputFocusGained)
        h.send(.escape)
        XCTAssertEqual(h.mode, .idle, "Esc → 접힘")
        h.mouseOnNotchAfterShrink = true
        h.finishCollapse()
        XCTAssertEqual(h.mode, .idle, "마우스가 노치 위여도 다시 펼치지 않음")
        XCTAssertTrue(h.m.blockExpandUntilExit)
        XCTAssertEqual(h.log.last, .resyncTrackingAssumeInside)
        h.send(.mouseEntered)  // 노치 위에서 움직여 생긴 진입
        XCTAssertEqual(h.mode, .idle, "나가기 전 진입은 무시")
        let effects = h.send(.mouseExited(spurious: false))
        XCTAssertEqual(effects, [.resignKey], "나가면 차단 풀림 + 미뤄 둔 key 내려놓기")
        h.send(.mouseEntered)
        XCTAssertEqual(h.mode, .expanded, "다시 들어오면 펼침")
    }

    func testEscapeWithMouseBelowNotchJustCollapses() {
        var h = Harness()
        h.send(.turnOn); h.peekElapsed(); h.finishCollapse()
        h.send(.mouseEntered); h.send(.inputFocusGained); h.send(.escape)
        h.mouseOnNotchAfterShrink = false
        h.finishCollapse()
        XCTAssertFalse(h.m.blockExpandUntilExit)
        h.send(.mouseEntered)
        XCTAssertEqual(h.mode, .expanded)
    }

    func testResignKeyWhileEditingCollapsesWhenOutside() {
        var h = Harness()
        h.send(.turnOn); h.peekElapsed(); h.finishCollapse()
        h.send(.mouseEntered); h.send(.inputFocusGained)
        h.send(.mouseExited(spurious: false))
        h.send(.panelResignedKey)
        XCTAssertEqual(h.mode, .idle)
    }

    func testResignKeyWhileEditingWithMouseInsideStaysExpanded() {
        var h = Harness()
        h.send(.turnOn); h.peekElapsed(); h.finishCollapse()
        h.send(.mouseEntered); h.send(.inputFocusGained)
        h.send(.panelResignedKey)
        XCTAssertEqual(h.mode, .expanded, "입력은 끝나고 마우스가 안이라 펼친 채")
    }

    // MARK: 끄기

    func testTurnOffFromAnyStateThenEventsIgnored() {
        let setups: [(inout Harness) -> Void] = [
            { $0.send(.turnOn) },                                                  // expanded (미리보기)
            { $0.send(.turnOn); $0.peekElapsed() },                                // idle (접히는 중)
            { $0.send(.turnOn); $0.send(.mouseEntered); $0.send(.inputFocusGained) }, // editing
        ]
        for setup in setups {
            var h = Harness()
            setup(&h)
            let collapseToken = h.lastCollapseToken
            XCTAssertEqual(h.send(.turnOff), [.hideImmediately])
            XCTAssertEqual(h.mode, .off)
            for e: NotchStateMachine.Event in [.mouseEntered, .mouseExited(spurious: false), .inputFocusGained,
                                               .submit(hasText: true), .escape, .panelResignedKey, .screenChanged,
                                               .peekElapsed(token: h.lastPeekToken ?? 0),
                                               .collapseAnimationFinished(token: collapseToken ?? 0)] {
                XCTAssertEqual(h.send(e), [], "off에서는 \(e) 무시")
                XCTAssertEqual(h.mode, .off)
            }
            XCTAssertEqual(h.send(.turnOff), [], "두 번 끄기도 무시")
        }
    }

    func testScreenChangedReappliesFrame() {
        var h = Harness()
        h.send(.turnOn)
        XCTAssertEqual(h.send(.screenChanged), [.reapplyFrame])
        XCTAssertEqual(h.mode, .expanded)
    }

    // MARK: 가짜 이탈 (T-003 결정 2-3)

    func testSpuriousExitIsIgnoredAndResyncsTracking() {
        var h = Harness()
        h.send(.turnOn); h.send(.mouseEntered); h.peekElapsed()
        let effects = h.send(.mouseExited(spurious: true))
        XCTAssertEqual(effects, [.resyncTrackingAssumeInside], "무시하되 추적 영역을 '안'으로 맞춤")
        XCTAssertEqual(h.mode, .expanded)
        XCTAssertTrue(h.m.mouseInside)
        // 갇히지 않음: 다시 맞춘 추적 영역이 진짜 이탈을 보내면 접힌다
        h.send(.mouseExited(spurious: false))
        XCTAssertEqual(h.mode, .idle)
    }

    func testSpuriousExitAfterEscapeKeepsBlock() {
        var h = Harness()
        h.send(.turnOn); h.peekElapsed(); h.finishCollapse()
        h.send(.mouseEntered); h.send(.inputFocusGained); h.send(.escape)
        h.mouseOnNotchAfterShrink = true
        h.finishCollapse()
        h.send(.mouseExited(spurious: true))   // 프레임을 줄인 직후 가짜 이탈 (T-002 로그)
        h.send(.mouseEntered)                  // 이어 오는 가짜 진입
        XCTAssertEqual(h.mode, .idle)
        XCTAssertTrue(h.m.blockExpandUntilExit, "가짜 이탈로는 차단이 풀리지 않음")
    }

    /// 테스트용: 실제 마우스 위치를 몇 번 읽었는지 센다
    private func spurious(mouse: CGPoint, rect: CGRect, eventTime: TimeInterval, lastFrameChange: TimeInterval?,
                          reads: inout Int) -> Bool {
        HoverGeometry.isSpuriousExit(eventTime: eventTime, lastFrameChange: lastFrameChange, hoverRect: rect,
                                     currentMouse: { reads += 1; return mouse })
    }

    func testSpuriousExitFilterTimingAndPosition() {
        let frame = CGRect(x: 866, y: 1049, width: 188, height: 31)
        let inside = CGPoint(x: 956.9, y: 1076)
        var reads = 0
        // 로그에서 관측된 간격 (5~59ms) 안 + 실제 마우스가 안 → 가짜
        XCTAssertTrue(spurious(mouse: inside, rect: frame, eventTime: 100.023, lastFrameChange: 100.0, reads: &reads))
        XCTAssertTrue(spurious(mouse: inside, rect: frame, eventTime: 100.059, lastFrameChange: 100.0, reads: &reads))
        XCTAssertTrue(spurious(mouse: inside, rect: frame, eventTime: 100.149, lastFrameChange: 100.0, reads: &reads))
        XCTAssertEqual(reads, 3, "이벤트 1개당 실제 위치는 1번만 읽는다")
        // 프레임 변경 후 오래 지남 → 이벤트대로(진짜), 위치를 읽지 않음
        reads = 0
        XCTAssertFalse(spurious(mouse: inside, rect: frame, eventTime: 100.2, lastFrameChange: 100.0, reads: &reads))
        // 프레임 변경 기록 없음 → 진짜
        XCTAssertFalse(spurious(mouse: inside, rect: frame, eventTime: 100.01, lastFrameChange: nil, reads: &reads))
        // 이벤트 시각이 프레임 변경보다 이르면(이전 이벤트) → 진짜
        XCTAssertFalse(spurious(mouse: inside, rect: frame, eventTime: 99.99, lastFrameChange: 100.0, reads: &reads))
        XCTAssertEqual(reads, 0, "프레임 변경 직후가 아니면 마우스 위치를 읽지 않는다")
        // 직후라도 실제 마우스가 밖 → 진짜 (접힘)
        XCTAssertFalse(spurious(mouse: CGPoint(x: 956, y: 1040), rect: frame, eventTime: 100.01, lastFrameChange: 100.0, reads: &reads))
        // 실제 마우스가 경계선(아래 끝 y = minY, 오른쪽 끝 x = maxX)이면 밖 → 진짜
        XCTAssertFalse(spurious(mouse: CGPoint(x: 900, y: 1049), rect: frame, eventTime: 100.01, lastFrameChange: 100.0, reads: &reads))
        XCTAssertFalse(spurious(mouse: CGPoint(x: 1054, y: 1070), rect: frame, eventTime: 100.01, lastFrameChange: 100.0, reads: &reads))
    }

    /// T-008 (T-004 문제·한계 1): 프레임 변경 직후 이벤트 좌표가 엉뚱해도(예: {1778.5, 1080}) 이벤트 좌표는 쓰지 않는다.
    /// 실제 마우스가 안이면 무시, 밖이면 접힘
    func testRightAfterFrameChangeUsesActualMouseNotEventPoint() {
        let rect = CGRect(x: 718, y: 700, width: 484, height: 380)
        var reads = 0
        // 직후 + 실제 마우스는 패널 안 → 무시 (이벤트 좌표 {1778.5, 1080}은 판정에 들어가지 않음)
        XCTAssertTrue(spurious(mouse: CGPoint(x: 960, y: 1000), rect: rect, eventTime: 50.026, lastFrameChange: 50.0, reads: &reads))
        // 직후 + 실제 마우스는 밖 → 진짜 이탈
        XCTAssertFalse(spurious(mouse: CGPoint(x: 1778.5, y: 1080), rect: rect, eventTime: 50.013, lastFrameChange: 50.0, reads: &reads))
        // 직후 + 실제 마우스가 패널 바로 옆(밖) → 진짜 이탈
        XCTAssertFalse(spurious(mouse: CGPoint(x: 710, y: 900), rect: rect, eventTime: 50.013, lastFrameChange: 50.0, reads: &reads))
        // 오래 지남 → 이벤트대로 (진짜)
        XCTAssertFalse(spurious(mouse: CGPoint(x: 960, y: 1000), rect: rect, eventTime: 51, lastFrameChange: 50.0, reads: &reads))
        XCTAssertEqual(reads, 3)
    }

    // MARK: 다시 열기 (T-010)

    func testReopenWhileIdlePeeksThenCollapses() {
        var h = idleHarness()
        let effects = h.send(.reopened)
        XCTAssertTrue(effects.contains(.expand))
        XCTAssertTrue(effects.contains(.schedulePeek(token: h.lastPeekToken!)))
        XCTAssertFalse(effects.contains(.showPanel), "이미 보이는 패널")
        XCTAssertEqual(h.mode, .expanded)
        XCTAssertTrue(h.m.isOn)
        h.peekElapsed()
        XCTAssertEqual(h.mode, .idle, "3초 뒤 마우스가 밖이면 접힘")
        h.finishCollapse()
        XCTAssertEqual(h.mode, .idle, "켜진 상태 유지")
    }

    func testReopenWhileOffPeeksWithoutTurningOn() {
        var h = Harness()
        let effects = h.send(.reopened)
        XCTAssertEqual(effects.first, .showPanel)
        XCTAssertEqual(h.mode, .expanded)
        XCTAssertFalse(h.m.isOn, "다시 열기는 켜지 않는다")
        h.peekElapsed()
        h.finishCollapse()
        XCTAssertEqual(h.mode, .off, "접히면 다시 OFF")
        XCTAssertEqual(h.log.last, .hideImmediately)
        XCTAssertEqual(h.send(.mouseEntered), [], "OFF라 hover 감지 없음")
    }

    func testReopenWhileOffPeekMouseInsideThenTurnOnStaysOn() {
        var h = Harness()
        h.send(.reopened)
        h.send(.mouseEntered)
        h.peekElapsed()
        XCTAssertEqual(h.mode, .expanded, "마우스가 안이면 펼친 채")
        h.send(.turnOn)
        XCTAssertTrue(h.m.isOn, "미리보기 중 메뉴로 켜면 그대로 켜진 상태")
        h.send(.mouseExited(spurious: false))
        h.finishCollapse()
        XCTAssertEqual(h.mode, .idle, "켰으니 OFF로 돌아가지 않음")
    }

    func testReopenWhileExpandedOrEditingDoesNothing() {
        var h = idleHarness()
        h.send(.mouseEntered)
        XCTAssertEqual(h.send(.reopened), [])
        h.send(.inputFocusGained)
        XCTAssertEqual(h.send(.reopened), [])
        XCTAssertEqual(h.mode, .editing)
    }

    // MARK: 이탈 유예 0.1초 (T-008 사용자 결정)

    private func expandedHarness() -> Harness {
        var h = Harness()
        h.send(.turnOn); h.peekElapsed(); h.finishCollapse()
        h.send(.mouseEntered)
        h.autoExitGrace = false
        return h
    }

    func testExitWaitsForGraceBeforeCollapsing() {
        var h = expandedHarness()
        XCTAssertEqual(h.mode, .expanded)
        let effects = h.send(.mouseExited(spurious: false))
        XCTAssertEqual(effects, [.scheduleExitGrace(token: h.lastExitGraceToken!)], "나가자마자 접지 않고 유예만 건다")
        XCTAssertEqual(h.mode, .expanded)
        h.send(.exitGraceElapsed(token: h.lastExitGraceToken!))
        XCTAssertEqual(h.mode, .idle, "유예가 끝날 때 밖이면 접힘")
        XCTAssertTrue(h.log.contains { if case .startCollapse = $0 { return true }; return false })
    }

    func testReenterWithinGraceStaysExpanded() {
        var h = expandedHarness()
        h.send(.mouseExited(spurious: false))
        let token = h.lastExitGraceToken!
        h.send(.mouseEntered)
        XCTAssertEqual(h.send(.exitGraceElapsed(token: token)), [], "다시 들어왔으면 기다리던 접힘은 무시")
        XCTAssertEqual(h.mode, .expanded)
        // 다시 나가면 새 유예
        h.send(.mouseExited(spurious: false))
        XCTAssertNotEqual(h.lastExitGraceToken, token)
        h.send(.exitGraceElapsed(token: token))
        XCTAssertEqual(h.mode, .expanded, "이전 유예 번호는 무시")
        h.send(.exitGraceElapsed(token: h.lastExitGraceToken!))
        XCTAssertEqual(h.mode, .idle)
    }

    func testGraceWithFocusOrDisplayChange() {
        // 다시 들어와 입력을 시작 → 유예 끝나도 그대로 편집
        var h = expandedHarness()
        h.send(.mouseExited(spurious: false))
        let token = h.lastExitGraceToken!
        h.send(.mouseEntered)
        h.send(.inputFocusGained)
        h.send(.exitGraceElapsed(token: token))
        XCTAssertEqual(h.mode, .editing, "입력 중에는 유예가 끝나도 접지 않음")

        // 유예 중 마우스가 밖인데 생긴 포커스(무시됨) → 유예는 그대로 살아 있어 접힌다 (펼친 채 갇히지 않게)
        var f = expandedHarness()
        f.send(.mouseExited(spurious: false))
        f.send(.inputFocusGained)
        f.send(.exitGraceElapsed(token: f.lastExitGraceToken!))
        XCTAssertEqual(f.mode, .idle)

        var d = expandedHarness()
        d.send(.mouseExited(spurious: false))
        d.send(.displayChanged)
        XCTAssertEqual(d.mode, .idle)
        XCTAssertEqual(d.send(.exitGraceElapsed(token: d.lastExitGraceToken!)), [])
    }

    func testDuringPeekExitDoesNotScheduleGrace() {
        var h = Harness()
        h.autoExitGrace = false
        h.send(.turnOn)
        h.send(.mouseEntered)
        XCTAssertEqual(h.send(.mouseExited(spurious: false)), [], "미리보기 중에는 유예도 걸지 않음")
        XCTAssertNil(h.lastExitGraceToken)
    }

    // MARK: 패널 안 판정 경계값 (T-003 결정 2-2)

    func testContainsBoundaries() {
        // 외부 모니터 접힌 패널 (T-001c 로그) — 화면 높이 1080
        let f = CGRect(x: 866, y: 1049, width: 188, height: 31)   // x 866~1054, y 1049~1080
        // 위쪽 끝(화면 맨 위) 포함
        XCTAssertTrue(HoverGeometry.contains(f, CGPoint(x: 950, y: 1080)))
        XCTAssertFalse(HoverGeometry.contains(f, CGPoint(x: 950, y: 1080.5)))
        // 아래 끝: 바로 안은 안, 경계(minY)와 그 아래는 밖
        XCTAssertTrue(HoverGeometry.contains(f, CGPoint(x: 950, y: 1049.5)))
        XCTAssertFalse(HoverGeometry.contains(f, CGPoint(x: 950, y: 1049)))
        XCTAssertFalse(HoverGeometry.contains(f, CGPoint(x: 950, y: 1048.5)))
        // 왼쪽 끝: 경계(minX)는 안, 바로 밖은 밖
        XCTAssertTrue(HoverGeometry.contains(f, CGPoint(x: 866, y: 1070)))
        XCTAssertFalse(HoverGeometry.contains(f, CGPoint(x: 865.5, y: 1070)))
        // 오른쪽 끝: 바로 안은 안, 경계(maxX)는 밖
        XCTAssertTrue(HoverGeometry.contains(f, CGPoint(x: 1053.5, y: 1070)))
        XCTAssertFalse(HoverGeometry.contains(f, CGPoint(x: 1054, y: 1070)))
        // 모서리: 왼쪽 위 끝은 안
        XCTAssertTrue(HoverGeometry.contains(f, CGPoint(x: 866, y: 1080)))
    }

    // MARK: 화면 구성 변경 (T-008)

    /// 켜고 미리보기가 끝난 뒤 접힌 상태(IDLE)로 만든다
    private func idleHarness() -> Harness {
        var h = Harness()
        h.send(.turnOn)
        h.peekElapsed()
        h.finishCollapse()
        h.log = []
        return h
    }

    func testDisplayChangedWhileExpandedCollapsesNowAtNewPlace() {
        var h = idleHarness()
        h.send(.mouseEntered)
        XCTAssertEqual(h.mode, .expanded)
        let effects = h.send(.displayChanged)
        XCTAssertEqual(h.mode, .idle)
        XCTAssertTrue(effects.contains(.collapseNow), "애니메이션 없이 바로 접음")
        XCTAssertTrue(effects.contains(.reapplyFrame), "새 위치에 접힌 크기로")
        XCTAssertFalse(effects.contains { if case .startCollapse = $0 { return true }; return false })
        XCTAssertFalse(h.m.mouseInside)
    }

    func testDisplayChangedWhileEditingEndsInputButStaysCollapsed() {
        var h = idleHarness()
        h.send(.mouseEntered)
        h.send(.inputFocusGained)
        XCTAssertEqual(h.mode, .editing)
        let effects = h.send(.displayChanged)
        XCTAssertEqual(h.mode, .idle)
        XCTAssertTrue(effects.contains(.endInputFocus(resignKey: true)), "입력은 끝내고 key도 내려놓음(글자는 입력창에 남음)")
        XCTAssertFalse(effects.contains(.addTodo), "입력하던 내용을 추가하지 않음")
        XCTAssertTrue(effects.contains(.collapseNow))
        // 이어서 오는 포커스 해제·key 해제 이벤트로 다시 바뀌지 않음
        h.send(.inputFocusLost)
        h.send(.panelResignedKey)
        XCTAssertEqual(h.mode, .idle)
    }

    func testDisplayChangedWithDatePickerOpenClosesIt() {
        var h = idleHarness()
        h.send(.mouseEntered)
        h.send(.inputFocusGained)
        h.send(.datePickerToggled)
        XCTAssertTrue(h.m.datePickerOpen)
        let effects = h.send(.displayChanged)
        XCTAssertFalse(h.m.datePickerOpen)
        XCTAssertTrue(effects.contains(.setDatePicker(open: false)))
        XCTAssertEqual(h.mode, .idle)
    }

    func testDisplayChangedThenMouseOnNewNotchExpandsByNormalRule() {
        var h = idleHarness()
        h.send(.mouseEntered)
        h.mouseOnNotchAfterShrink = true  // 새 노치 자리에 마우스가 이미 있음
        h.send(.displayChanged)
        XCTAssertEqual(h.mode, .expanded, "1회 확인 결과 안이면 일반 규칙대로 펼침")
    }

    func testDisplayChangedDuringPeekStopsPeek() {
        var h = Harness()
        h.send(.turnOn)
        XCTAssertTrue(h.m.inPeek)
        h.send(.displayChanged)
        XCTAssertEqual(h.mode, .idle)
        XCTAssertFalse(h.m.inPeek)
        h.peekElapsed()  // 남은 3초 지연은 무시
        XCTAssertEqual(h.mode, .idle)
    }

    func testDisplayChangedDuringCollapseIgnoresOldCollapseFinish() {
        var h = idleHarness()
        h.send(.mouseEntered)
        h.send(.mouseExited(spurious: false))  // 접히는 중
        let staleToken = h.lastCollapseToken!
        h.send(.displayChanged)
        h.log = []
        h.send(.collapseAnimationFinished(token: staleToken))
        XCTAssertFalse(h.log.contains(.shrinkFrame), "화면 변경 전에 시작한 접힘 완료는 무시 (새 위치 프레임은 이미 적용)")
        XCTAssertEqual(h.mode, .idle)
    }

    func testDisplayChangedWhileIdleOnlyReplaces() {
        var h = idleHarness()
        let effects = h.send(.displayChanged)
        XCTAssertEqual(h.mode, .idle)
        XCTAssertFalse(effects.contains(.collapseNow))
        XCTAssertTrue(effects.contains(.reapplyFrame))
    }

    func testDisplayChangedWhileOffDoesNothing() {
        var h = Harness()
        XCTAssertEqual(h.send(.displayChanged), [])
        XCTAssertEqual(h.mode, .off)
    }

    func testDisplayChangedDuringAlertRemovesAlertAndReplaces() {
        var h = idleHarness()
        h.send(.alertArrived)
        XCTAssertEqual(h.mode, .alert)
        let alertToken = h.m.alertToken
        let effects = h.send(.displayChanged)
        XCTAssertEqual(h.mode, .idle)
        XCTAssertTrue(effects.contains(.removeAlertNow))
        XCTAssertTrue(effects.contains(.reapplyFrame))
        // 남은 5초 지연은 무시
        h.log = []
        h.send(.alertDismiss(token: alertToken))
        XCTAssertTrue(h.log.isEmpty)
        XCTAssertEqual(h.mode, .idle)
    }

    func testDisplayChangedDuringAlertFromOffReturnsToOff() {
        var h = Harness()
        h.send(.alertArrived)
        XCTAssertEqual(h.mode, .alert)
        let effects = h.send(.displayChanged)
        XCTAssertEqual(h.mode, .off)
        XCTAssertTrue(effects.contains(.removeAlertNow))
        XCTAssertTrue(effects.contains(.hideImmediately))
    }

    func testDisplayChangedOnPanelOpenedFromOffAlertReturnsToOff() {
        var h = Harness()
        h.send(.alertArrived)
        h.send(.alertTapped)
        XCTAssertEqual(h.mode, .expanded)
        let effects = h.send(.displayChanged)
        XCTAssertEqual(h.mode, .off, "OFF에서 알림으로 펼친 패널 → 다시 OFF")
        XCTAssertTrue(effects.contains(.hideImmediately))
        XCTAssertFalse(h.m.isOn)
    }

    func testPlacementChangedOnlyWhenFrameOrNotchMoves() {
        func g(_ screen: CGRect, _ notch: CGRect, name: String = "A", scale: CGFloat = 2) -> NotchGeometry {
            NotchGeometry(screenFrame: screen, notchRect: notch, hasPhysicalNotch: false, isVirtual: true,
                          screenName: name, pixelSize: CGSize(width: screen.width * scale, height: screen.height * scale),
                          backingScale: scale)
        }
        let s1 = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let n1 = CGRect(x: 870, y: 1056, width: 180, height: 24)
        XCTAssertFalse(NotchGeometry.placementChanged(from: g(s1, n1), to: g(s1, n1, name: "B", scale: 1)), "이름·배율만 바뀜")
        XCTAssertTrue(NotchGeometry.placementChanged(from: g(s1, n1), to: g(CGRect(x: 0, y: 0, width: 2560, height: 1440), n1)), "해상도")
        XCTAssertTrue(NotchGeometry.placementChanged(from: g(s1, n1), to: g(s1, CGRect(x: 830, y: 1048, width: 260, height: 32))), "실제 노치로")
    }
}
