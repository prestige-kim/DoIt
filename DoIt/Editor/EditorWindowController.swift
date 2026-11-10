import AppKit
import WebKit
import os

private let editorLogger = Logger(subsystem: "com.personal.doit", category: "editor")

/// 전체 편집기 창 (PRD F9, ARCHITECTURE §3.7, T-006). 앱 번들의 `Web/index.html`을 WKWebView로 띄운다.
/// - 창은 하나만. 이미 열려 있으면 앞으로
/// - 닫으면 WebView·메시지 핸들러·구독을 모두 풀어 메모리를 돌려준다 (다음에 열 때 새로 만든다)
/// - 네트워크 차단(D-016): 번들 폴더만 읽기 허용, 비영구 데이터 저장소, 편집기 파일 외 이동은 모두 취소, HTML의 CSP
/// - 웹에서 온 메시지는 `EditorBridge.parse`로 검사한 뒤에만 TodoStore / LmsStore에 반영한다 (LMS는 체크만)
@MainActor
final class EditorWindowController: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    static let windowSize = NSSize(width: 760, height: 560)
    static let minSize = NSSize(width: 600, height: 420)

    /// 웹으로 넘기는 색 역할 (Asset Catalog 이름 그대로 CSS 변수 `--이름`이 된다)
    static let paletteRoles = [
        "PanelBackground", "PrimaryText", "SecondaryText", "TodoAccent", "TodoAccentSoft",
        "LmsAccent", "LmsAccentSoft", "OverdueAccent", "OverdueSoft", "CheckRing", "Separator",
        "InputBackground", "CardBorder", "OnAccent",
    ]

    private let store: TodoStore
    private let lms: LmsStore?

    private var window: NSWindow?
    private var webView: WKWebView?
    private var editorFile: URL?
    private var isReady = false
    private var renderScheduled = false
    /// 새 창을 첫 render 뒤에 보이려고 기다리는 중
    private var revealPending = false
    private var todoToken: ChangeObservers.Token?
    private var lmsToken: ChangeObservers.Token?
    private var appearanceObservation: NSKeyValueObservation?
    /// 편집기를 열기 전에 앞에 있던 앱 (닫으면 돌려준다, 설정 창과 같은 방식)
    private var previousApp: NSRunningApplication?

    init(store: TodoStore, lms: LmsStore?) {
        self.store = store
        self.lms = lms
    }

    var isOpen: Bool { window != nil }

    // MARK: 열기·닫기

    func show() {
        let isNew = self.window == nil
        let window = self.window ?? makeWindow()
        self.window = window

        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = front
        }
        // T-006 허용 예외(설정 창과 같음): 사용자가 메뉴·패널 버튼으로 편집기를 열 때만 앱을 앞으로. 노치 패널 코드에서는 쓰지 않는다
        NSApp.activate()
        if isNew {
            // 새 창은 웹 화면이 처음 그려진 뒤에 띄운다 → 빈 창이 잠깐 보이지 않게. 흰색 번쩍임 자체는 disableWebViewBackground로 막는다
            revealPending = true
            editorLogger.info("editor opening (appearance: \(window.effectiveAppearance.name.rawValue, privacy: .public))")
        } else {
            reveal()
        }
    }

    /// 창을 맨 앞에 보이고 키보드 입력을 웹 화면으로
    private func reveal() {
        guard let window else { return }
        revealPending = false
        window.makeKeyAndOrderFront(nil)
        // macOS 14+ 협조형 활성화는 다른 앱(예: 닫을 때 포커스를 돌려준 VS Code)이 양보하지 않으면 거절될 수 있다.
        // 그래도 창은 다른 앱 창들 위로 보이게 한다 (사용자 확인 J에서 관찰, T-006)
        window.orderFrontRegardless()
        if let webView { window.makeFirstResponder(webView) }
        editorLogger.info("editor shown")
        DispatchQueue.main.async {
            editorLogger.info("editor activation: app active = \(NSApp.isActive, privacy: .public), key = \(window.isKeyWindow, privacy: .public)")
        }
    }

    /// WKWebView는 웹 내용이 그려지기 전·다시 그려지는 순간(창이 활성화될 때 등)에 자기 기본 바탕(흰색)을 칠한다.
    /// 다크 모드에서 흰색이 번쩍이던 원인 (사용자 확인 J, 앞에 있던 앱과 무관하게 발생).
    /// 바탕을 칠하지 않게 해서 그 순간에는 창 바탕색(PanelBackground, 다크 모드 = 검정)이 비쳐 보이게 한다.
    /// 공개 API가 없어 WebKit의 `_setDrawsBackground:`를 KVC(`drawsBackground`)로 쓴다. 없으면 건너뛴다(그때는 예전처럼 흰 바탕 가능)
    static func disableWebViewBackground(_ web: WKWebView) {
        guard web.responds(to: NSSelectorFromString("_setDrawsBackground:")) else {
            editorLogger.notice("drawsBackground not available: web view keeps default background")
            return
        }
        web.setValue(false, forKey: "drawsBackground")
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: Self.windowSize),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "DoIt 편집기"
        w.minSize = Self.minSize
        w.titlebarAppearsTransparent = true
        w.backgroundColor = NSColor(named: "PanelBackground")
        w.isReleasedWhenClosed = false
        w.delegate = self

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()  // 쿠키·저장소·캐시를 디스크에 남기지 않음
        config.userContentController.add(WeakScriptHandler(self), name: EditorBridge.handlerName)
        let web = WKWebView(frame: w.contentLayoutRect, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = false
        web.allowsMagnification = false
        web.underPageBackgroundColor = NSColor(named: "PanelBackground")
        Self.disableWebViewBackground(web)
        web.autoresizingMask = [.width, .height]
        w.contentView = web
        webView = web

        // 창 밝기 모드가 바뀌면 색을 다시 넘긴다 (이벤트 방식)
        appearanceObservation = w.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.scheduleRender() }
        }
        // 데이터가 바뀌면 다시 그린다 (편집기가 열려 있는 동안만 구독)
        todoToken = store.todosChangedObservers.add { [weak self] in self?.scheduleRender() }
        lmsToken = lms?.changeObservers.add { [weak self] in self?.scheduleRender() }

        if let dir = Bundle.main.url(forResource: "Web", withExtension: nil) {
            let index = dir.appendingPathComponent("index.html")
            editorFile = index
            web.loadFileURL(index, allowingReadAccessTo: dir)  // 읽기 허용은 Web 폴더만
        } else {
            editorLogger.error("editor web folder missing in bundle")
        }
        w.center()
        return w
    }

    func windowWillClose(_ notification: Notification) {
        teardown()
        if let app = previousApp, !app.isTerminated {
            app.activate(options: [])
        }
        previousApp = nil
        editorLogger.info("editor closed: web view released")
    }

    /// 창을 닫을 때 모두 해제 (WebView 프로세스·핸들러·구독·KVO)
    private func teardown() {
        if let todoToken { store.todosChangedObservers.remove(todoToken) }
        if let lmsToken { lms?.changeObservers.remove(lmsToken) }
        todoToken = nil
        lmsToken = nil
        appearanceObservation?.invalidate()
        appearanceObservation = nil
        if let webView {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.configuration.userContentController.removeScriptMessageHandler(forName: EditorBridge.handlerName)
            webView.removeFromSuperview()
        }
        webView = nil
        window?.contentView = nil
        window?.delegate = nil
        window = nil
        editorFile = nil
        isReady = false
        renderScheduled = false
        revealPending = false
    }

    // MARK: 앱 → 웹

    /// 오늘 날짜가 바뀌었을 때 등 바깥에서 부른다. 닫혀 있으면 아무것도 안 함
    func refreshIfOpen() {
        scheduleRender()
    }

    /// 같은 차례에 변경이 여러 번 와도 한 번만 그린다 (일회성 `main.async`, 반복 없음)
    private func scheduleRender() {
        guard webView != nil, isReady, !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.renderScheduled = false
            self.render()
        }
    }

    private var lmsShown: Bool { lms.map { $0.isEnabled && $0.hasFeedURL } ?? false }

    private func currentLmsItems() -> [LmsItem]? {
        guard let lms, lmsShown else { return nil }
        return lms.visibleItems(today: store.today)
    }

    private func render() {
        guard let webView, isReady else { return }
        let appearance = window?.effectiveAppearance ?? NSApp.effectiveAppearance
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let state = EditorBridge.makeState(
            todos: store.todos, lmsItems: currentLmsItems(),
            checked: Set(lms?.checked.keys.map { $0 } ?? []),
            today: store.today, palette: Self.palette(for: appearance), dark: dark)
        guard let arg = EditorBridge.jsArgument(state) else { return }
        webView.callAsyncJavaScript("window.doit.render(state)", arguments: ["state": arg],
                                    in: nil, in: .page) { [weak self, weak webView] result in
            if case .failure(let error) = result {
                editorLogger.error("render failed: \(String(describing: error), privacy: .public)")
            }
            // 새 창은 첫 render 뒤에 보인다 (실패해도 빈 창으로 남지 않게 보인다)
            guard let self, self.revealPending, webView != nil else { return }
            DispatchQueue.main.async { if self.revealPending { self.reveal() } }
        }
    }

    /// Asset Catalog 역할 색을 창의 밝기 모드로 풀어 `rgba(r, g, b, a)` 문자열로 (코드·CSS에 hex 없음)
    static func palette(for appearance: NSAppearance) -> [String: String] {
        var out: [String: String] = [:]
        appearance.performAsCurrentDrawingAppearance {
            for name in paletteRoles {
                guard let c = NSColor(named: name)?.usingColorSpace(.sRGB) else { continue }
                let r = Int((c.redComponent * 255).rounded()), g = Int((c.greenComponent * 255).rounded())
                let b = Int((c.blueComponent * 255).rounded())
                out[name] = "rgba(\(r), \(g), \(b), \(String(format: "%.3f", c.alphaComponent)))"
            }
        }
        return out
    }

    // MARK: 웹 → 앱

    fileprivate func receive(_ body: Any) {
        let todoIDs = Set(store.todos.map(\.id))
        let lmsUIDs = Set(currentLmsItems()?.map(\.uid) ?? [])
        switch EditorBridge.parse(body, todoIDs: todoIDs, lmsUIDs: lmsUIDs) {
        case .failure(let reason):
            editorLogger.notice("message rejected: \(String(describing: reason), privacy: .public)")
            scheduleRender()  // 웹 화면을 실제 데이터로 되돌린다
        case .success(let message):
            apply(message)
        }
    }

    private func apply(_ message: EditorBridge.Message) {
        switch message {
        case .ready:
            isReady = true
            render()
        case let .updateTodo(id, title, dueDate):
            store.update(id: id, title: title, dueDate: dueDate)
            scheduleRender()  // 값이 같아 저장소 변경이 없어도 화면을 맞춘다
        case let .setDone(ids, done):
            store.setDone(ids: ids, done: done)
            scheduleRender()
        case let .deleteTodos(ids):
            store.delete(ids: ids)
            editorLogger.info("deleted \(ids.count, privacy: .public) todos from editor")
        case let .toggleLmsCheck(uid):
            lms?.toggleCheck(uid: uid)  // LMS로 가는 유일한 동작: 내 맥 안 체크 기록 (D-011)
        }
    }

    // MARK: 이동 차단 (D-016)

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let editorFile, EditorBridge.allowsNavigation(to: navigationAction.request.url, editorFile: editorFile) else {
            editorLogger.notice("navigation cancelled (scheme: \(navigationAction.request.url?.scheme ?? "nil", privacy: .public))")
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    /// 편집기 파일을 못 불러왔으면 기다리지 않고 창을 보인다 (빈 창으로라도 열림을 알 수 있게)
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        editorLogger.error("editor load failed: \(String(describing: error), privacy: .public)")
        if revealPending { reveal() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        editorLogger.error("editor load failed: \(String(describing: error), privacy: .public)")
        if revealPending { reveal() }
    }

    /// 새 창(`target=_blank`, `window.open`)은 만들지 않는다
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        editorLogger.notice("new window blocked")
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // 웹 프로세스가 죽으면 다시 불러온다 (ready가 오면 다시 그림)
        editorLogger.error("web content process terminated: reloading")
        isReady = false
        if let editorFile {
            webView.loadFileURL(editorFile, allowingReadAccessTo: editorFile.deletingLastPathComponent())
        }
    }
}

/// `WKUserContentController`는 핸들러를 강하게 잡는다 → 컨트롤러를 약하게 잡는 래퍼로 순환 참조를 끊는다
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: EditorWindowController?

    init(_ target: EditorWindowController) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // 메인 프레임에서 온 메시지만 받는다
        guard message.frameInfo.isMainFrame, message.name == EditorBridge.handlerName else { return }
        let body = message.body
        MainActor.assumeIsolated { target?.receive(body) }
    }
}
