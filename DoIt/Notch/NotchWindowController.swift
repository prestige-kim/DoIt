import AppKit
import SwiftUI
import os

private let windowLogger = Logger(subsystem: "com.personal.doit", category: "window")

/// 노치 패널의 위치·크기·hover 감지를 담당한다. 상태 판단은 하지 않고 NotchViewModel에 전달만 한다.
@MainActor
final class NotchWindowController {
    private let viewModel: NotchViewModel
    private let panel: NotchPanel
    private let trackingView: HoverTrackingView
    private(set) var geometry: NotchGeometry?
    private var observers: [NSObjectProtocol] = []
    /// T-001c 진단: 마지막으로 지정한 프레임 (다른 곳에서 바뀌면 로그)
    private var requestedFrame: NSRect = .zero
    /// 마지막으로 패널 프레임을 바꾸거나 창을 다시 띄운 시각 (부팅 후 경과 초, `NSEvent.timestamp`와 같은 시계).
    /// 가짜 이탈 판정에만 쓴다 (T-003 결정 2-3)
    private var lastFrameChange: TimeInterval?
    /// T-008: 프레임 변경 직후라 무시한 이탈 횟수 (사용자 확인 H에서 로그로 관측)
    private var ignoredExitCount = 0

    /// 디버그: 물리 노치가 있어도 가상 노치로 그린다.
    var forceVirtualNotch = false {
        didSet { if oldValue != forceVirtualNotch { refreshGeometry() } }
    }

    init(viewModel: NotchViewModel) {
        self.viewModel = viewModel
        panel = NotchPanel(contentRect: NSRect(x: 0, y: 0, width: 188, height: 32))

        let hosting = FirstMouseHostingView(rootView: NotchRootView(viewModel: viewModel))
        hosting.sizingOptions = []  // SwiftUI가 창 크기를 바꾸지 않게 함 (크기는 이 컨트롤러가 정함)
        trackingView = HoverTrackingView(hosting: hosting)
        panel.contentView = trackingView

        trackingView.onEnter = { [weak viewModel] info in viewModel?.mouseEntered(windowInfo: info) }
        trackingView.onExit = { [weak self] info, _, _, time in
            guard let self else { return }
            // T-008: 프레임 변경 직후의 이탈은 이벤트 좌표를 믿지 않고, 이 이벤트에 대해 실제 마우스 위치를 1번만 읽어 판정한다
            // (ARCHITECTURE §5 허용 범위: 이벤트당 일회성 읽기, 주기 확인 아님)
            var actual: CGPoint?
            let spurious = HoverGeometry.isSpuriousExit(
                eventTime: time, lastFrameChange: self.lastFrameChange, hoverRect: self.panel.frame,
                currentMouse: { let m = NSEvent.mouseLocation; actual = m; return m })
            let sinceChange = self.lastFrameChange.map { String(format: "%.0fms", (time - $0) * 1000) } ?? "none"
            if spurious {
                self.ignoredExitCount += 1
                windowLogger.info("ignored exit #\(self.ignoredExitCount, privacy: .public): right after frame change (\(sinceChange, privacy: .public)), actual mouse inside \(NSStringFromPoint(actual ?? .zero), privacy: .public) · \(info, privacy: .public)")
            }
            let actualInfo = actual.map { " actual=\(NSStringFromPoint($0))" } ?? ""
            self.viewModel.mouseExited(windowInfo: "\(info) sinceFrameChange=\(sinceChange)\(actualInfo)", spurious: spurious)
        }

        viewModel.onNeedsExpandedFrame = { [weak self] in self?.applyFrame(expanded: true) }
        viewModel.onNeedsCollapsedFrame = { [weak self] in self?.applyFrame(expanded: false) }
        viewModel.onReapplyFrame = { [weak self] in self?.applyCurrentFrame() }
        viewModel.onShow = { [weak self] in self?.show() }
        viewModel.onHide = { [weak self] in self?.panel.orderOut(nil) }
        viewModel.onResignKey = { [weak self] in self?.resignKeyIfNeeded() }
        // 커서만 지운다. 포커스를 '없음'(nil)으로 두면 높이 변경 등으로 화면이 다시 배치될 때 입력창이 포커스를
        // 되돌려 받는다 (T-004 로그: 0.02초 뒤 inputFocusChanged(true)) → 바탕 뷰가 포커스를 받게 해서 빈자리를 없앤다
        viewModel.onClearFocus = { [weak self] in
            guard let self else { return }
            self.panel.makeFirstResponder(self.trackingView)
        }
        trackingView.onEscape = { [weak viewModel] in viewModel?.cancelEditing() }
        // 날짜 영역 사용 중 Esc를 받으려면 패널이 key여야 한다. nonactivating 패널이라 앱은 활성화되지 않음 (NSApp.activate 아님)
        viewModel.onFocusInput = { [weak self] in
            guard let self, !self.panel.isKeyWindow else { return }
            self.panel.makeKey()
            windowLogger.debug("focusInput: makeKey → isKey=\(self.panel.isKeyWindow, privacy: .public)")
        }
        viewModel.onResyncTrackingAssumeInside = { [weak self] in
            guard let self else { return }
            self.markFrameChange()
            self.trackingView.resetTrackingArea(assumeInside: true)
        }
        viewModel.isMouseInsidePanelNow = { [weak self] in self?.isMouseInsidePanelNow() ?? false }

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // 위치만 다시 계산하고, 프레임 적용은 상태 머신의 판단(.reapplyFrame)을 따른다.
                // 노치 위치·크기가 실제로 바뀌었을 때만 펼침·입력·알림을 정리한다 (T-008). 그 밖의 알림은 프레임만 다시 맞춘다
                if self.updateGeometry() {
                    self.markFrameChange()
                    self.viewModel.displayChanged()
                } else {
                    self.viewModel.screenChanged()
                }
            }
        })
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification,
                                            object: panel, queue: .main) { [weak viewModel] _ in
            MainActor.assumeIsolated { viewModel?.panelDidResignKey() }
        })

        // T-001c 진단: 지정한 프레임과 1pt 넘게 다른 크기·위치 변경이 생기면 로그를 남긴다 (이벤트 수신만, 폴링 아님)
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            observers.append(center.addObserver(forName: name, object: panel, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let a = self.panel.frame, r = self.requestedFrame
                    let off = max(abs(a.minX - r.minX), abs(a.minY - r.minY), abs(a.width - r.width), abs(a.height - r.height))
                    guard off > 1 else { return }  // 0.5pt 반올림 차이는 무시
                    windowLogger.error("UNEXPECTED \(note.name.rawValue, privacy: .public): actual=\(NSStringFromRect(a), privacy: .public) requested=\(NSStringFromRect(r), privacy: .public)")
                }
            })
        }

        refreshGeometry()
    }

    // MARK: 표시

    private func show() {
        refreshGeometry()
        markFrameChange()
        panel.orderFrontRegardless()
        // 표시 직후 어떤 뷰도 키보드 포커스를 갖지 않게 한다 (입력창 자동 포커스 방지, T-001b)
        panel.makeFirstResponder(nil)
        windowLogger.debug("show: isKey=\(self.panel.isKeyWindow, privacy: .public) appActive=\(NSApp.isActive, privacy: .public)")
    }

    /// 마우스가 지금 패널 프레임 안에 있는지 **한 번만** 확인한다.
    /// 접힘이 끝나 프레임이 줄어든 직후 1회만 호출된다 (주기적 확인 아님, ARCHITECTURE §5 / T-001b 허용).
    private func isMouseInsidePanelNow() -> Bool {
        let mouse = NSEvent.mouseLocation
        // 판정 규칙은 HoverGeometry.contains 하나로 통일 (화면 맨 위 끝 포함, T-003 결정 2-2)
        let inside = panel.isVisible && HoverGeometry.contains(panel.frame, mouse)
        windowLogger.debug("isMouseInsidePanelNow=\(inside, privacy: .public) mouse=\(NSStringFromPoint(mouse), privacy: .public) frame=\(NSStringFromRect(self.panel.frame), privacy: .public) isVisible=\(self.panel.isVisible, privacy: .public)")
        return inside
    }

    /// 화면 구성(모니터 연결/해제, 주 디스플레이 변경, 해상도)이 바뀌면 다시 계산하고 재배치한다.
    func refreshGeometry() {
        updateGeometry()
        applyCurrentFrame()
    }

    /// 화면 정보만 다시 계산한다 (프레임은 바꾸지 않음).
    /// - Returns: 화면·노치 위치나 크기가 바뀌었는지 (처음 계산은 false)
    @discardableResult
    private func updateGeometry() -> Bool {
        guard let newGeometry = NotchGeometry.compute(forceVirtual: forceVirtualNotch) else {
            windowLogger.error("no screen available")
            return false
        }
        let old = geometry
        let changed = newGeometry != old
        geometry = newGeometry
        viewModel.updateScreen(notchSize: newGeometry.notchRect.size, screenHeight: newGeometry.screenFrame.height)
        if changed {
            windowLogger.info("geometry: \(newGeometry.debugLines.joined(separator: " | "), privacy: .public)")
        }
        guard let old else { return false }
        return NotchGeometry.placementChanged(from: old, to: newGeometry)
    }

    /// 현재 상태에 맞는 프레임 (펼침/편집 → 펼친 크기, 그 외 → 노치 크기)
    private func applyCurrentFrame() {
        let expanded = viewModel.state == .expanded || viewModel.state == .editing
        applyFrame(expanded: expanded)
    }

    private func markFrameChange() {
        lastFrameChange = ProcessInfo.processInfo.systemUptime
    }

    /// 펼침: 펼친 크기 / 접힘: 노치 크기. 항상 화면 맨 위, 노치 중앙 정렬.
    private func applyFrame(expanded: Bool) {
        guard let geometry else { return }
        let size = expanded ? viewModel.expandedFrameSize : viewModel.collapsedFrameSize
        let screen = geometry.screenFrame
        var x = geometry.notchRect.midX - size.width / 2
        x = min(max(x, screen.minX), screen.maxX - size.width)
        let frame = NSRect(x: x, y: screen.maxY - size.height, width: size.width, height: size.height)
        if panel.frame != frame {
            requestedFrame = frame
            markFrameChange()
            panel.setFrame(frame, display: true)
            windowLogger.debug("frame \(expanded ? "expanded" : "collapsed", privacy: .public): \(NSStringFromRect(frame), privacy: .public) screen=\(NSStringFromRect(screen), privacy: .public)")
            // T-001c 진단: setFrame 직후 실제 값
            let content = panel.contentView
            windowLogger.debug("frame actual: \(NSStringFromRect(self.panel.frame), privacy: .public) content=\(NSStringFromRect(content?.frame ?? .zero), privacy: .public) fitting=\(NSStringFromSize(content?.fittingSize ?? .zero), privacy: .public) contentMin=\(NSStringFromSize(self.panel.contentMinSize), privacy: .public) minSize=\(NSStringFromSize(self.panel.minSize), privacy: .public)")
        }
    }

    /// 접히거나 편집이 끝났는데 패널이 키보드 입력을 계속 가져가지 않도록 key 상태를 내려놓는다.
    /// (nonactivating 패널이라 우리 앱은 활성화되지 않음. 잠깐 내렸다 다시 올리면 원래 앱이 키보드를 돌려받는다 — 동작은 사용자 확인 필요)
    private func resignKeyIfNeeded() {
        guard panel.isKeyWindow else { return }
        windowLogger.debug("resignKey: orderOut + orderFrontRegardless")
        panel.makeFirstResponder(nil)
        markFrameChange()  // 숨김→다시 띄움 직후에도 가짜 이탈·진입이 생긴다 (T-001c·T-002 로그)
        panel.orderOut(nil)
        if viewModel.isOn {
            panel.orderFrontRegardless()
        }
    }

    // MARK: 디버그

    var debugInfoLines: [String] {
        refreshGeometry()
        var lines = geometry?.debugLines ?? ["화면 정보를 가져올 수 없음"]
        let f = panel.frame
        lines.append("패널 프레임: x=\(Int(f.minX)) y=\(Int(f.minY)) w=\(Int(f.width)) h=\(Int(f.height)) · level \(panel.level.rawValue)")
        lines.append("상태: \(viewModel.state.rawValue)\(forceVirtualNotch ? " · 가상 노치 강제" : "")")
        return lines
    }
}

// MARK: - Hover 감지 뷰

/// content view 전체에 NSTrackingArea를 건다. (ARCHITECTURE §3.3 — 마우스 위치 폴링 없음)
final class HoverTrackingView: NSView {
    /// 인자: 진단용 문자열 (패널 frame, isVisible, 이벤트 좌표)
    var onEnter: (String) -> Void = { _ in }
    /// 인자: 진단 문자열, 이벤트 화면 좌표, 패널 프레임, 이벤트 시각 — 가짜 이탈 판별용 (T-003)
    var onExit: (String, CGPoint, CGRect, TimeInterval) -> Void = { _, _, _, _ in }
    private var trackingArea: NSTrackingArea?
    /// 이 뷰가 포커스를 가진 상태(입력을 끝낸 뒤)에서 Esc
    var onEscape: () -> Void = {}

    /// 입력을 끝낸 뒤 포커스를 맡아 둔다 (입력창이 저절로 포커스를 되찾지 않도록, T-004)
    override var acceptsFirstResponder: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape() }

    init(hosting: NSView) {
        super.init(frame: .zero)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        resetTrackingArea(assumeInside: false)
    }

    /// 추적 영역을 새로 만든다. `assumeInside`가 true면 "지금 마우스가 안에 있음"으로 시작해서,
    /// 진짜로 나갈 때 mouseExited가 온다 (Esc 후 노치 위 마우스, 가짜 이탈을 무시한 뒤 — T-002, T-003).
    func resetTrackingArea(assumeInside: Bool) {
        if let trackingArea { removeTrackingArea(trackingArea) }
        // .inVisibleRect: 뷰 크기가 바뀌면 추적 영역도 자동으로 따라간다.
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
        if assumeInside { options.insert(.assumeInside) }
        let area = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// 우리 추적 영역의 이벤트인지. 하위 뷰(SwiftUI `.onHover`, 입력창, 달력 등)의 추적 영역 이벤트도
    /// 응답자 체인을 타고 여기로 올라오기 때문에 걸러야 한다 (T-004 로그: 진입·이탈이 2번씩, 엉뚱한 좌표).
    private func isOwnEvent(_ event: NSEvent) -> Bool {
        guard let trackingArea, event.trackingArea === trackingArea else { return false }
        return true
    }

    override func mouseEntered(with event: NSEvent) {
        guard isOwnEvent(event) else { return }
        onEnter(diagnosticInfo(event))
    }
    override func mouseExited(with event: NSEvent) {
        guard isOwnEvent(event) else { return }
        guard let window else { return }
        // 이벤트에 담긴 좌표·시각만 쓴다 (마우스 위치를 따로 읽지 않음)
        let p = window.convertPoint(toScreen: event.locationInWindow)
        onExit(diagnosticInfo(event), p, window.frame, event.timestamp)
    }

    /// 진단 로그용: 이벤트 순간의 패널 frame·표시 여부·마우스 좌표 (이벤트가 올 때만 만들어짐, 폴링 아님)
    private func diagnosticInfo(_ event: NSEvent) -> String {
        guard let window else { return "window=nil" }
        let screenPoint = window.convertPoint(toScreen: event.locationInWindow)
        return "frame=\(NSStringFromRect(window.frame)) isVisible=\(window.isVisible) isKey=\(window.isKeyWindow) at=\(NSStringFromPoint(screenPoint))"
    }
}

/// 비활성 앱의 패널에서도 첫 클릭(체크박스 등)이 바로 먹도록 한다.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
