import XCTest
import WebKit
@testable import DoIt

/// T-006 전체 편집기: 저장소 일괄 기능, 변경 알림 여러 구독자, 브리지 검사(순수), 상태 JSON 허용 필드, 이동 정책,
/// 그리고 실제 번들 웹 파일을 WKWebView에 올려 CSP·textContent 동작 확인. 임시 폴더·임시 UserDefaults만 쓴다
@MainActor
final class EditorTests: XCTestCase {
    private var tempDir: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let today = LocalDate(year: 2026, month: 11, day: 8)

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DoItEditorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        suiteName = "DoItEditorTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func at(_ day: LocalDate, _ hour: Int) -> Date {
        LocalDate.calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: hour))!
    }

    private func makeStore() -> TodoStore {
        let s = TodoStore(fileURL: tempDir.appendingPathComponent("todos.json"), saveDelay: 60)
        s.load()
        return s
    }

    // MARK: TodoStore 일괄 기능

    func testUpdateChangesTitleDateAndUpdatedAtWithOneCallback() throws {
        let store = makeStore()
        var clock = at(today, 10)
        store.now = { clock }
        let a = try XCTUnwrap(store.add(title: "보고서", dueDate: today))
        var calls = 0
        store.onTodosChanged = { calls += 1 }

        clock = at(today, 11)
        XCTAssertTrue(store.update(id: a.id, title: "  보고서 최종  ", dueDate: today.adding(days: 2)))
        let t = try XCTUnwrap(store.todos.first)
        XCTAssertEqual(t.title, "보고서 최종", "앞뒤 공백 제거")
        XCTAssertEqual(t.dueDate, today.adding(days: 2))
        XCTAssertEqual(t.updatedAt, at(today, 11))
        XCTAssertEqual(t.createdAt, at(today, 10))
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(store.hasPendingSave, "기존 지연 저장 규칙")

        XCTAssertFalse(store.update(id: a.id, title: "   ", dueDate: today), "빈 제목 거부")
        XCTAssertFalse(store.update(id: UUID(), title: "x", dueDate: today), "없는 id")
        XCTAssertTrue(store.update(id: a.id, title: "보고서 최종", dueDate: today.adding(days: 2)), "같은 값")
        XCTAssertEqual(calls, 1, "거부·같은 값은 변경 알림 없음")
    }

    func testSetDoneManyFollowsDoneAtRuleWithOneCallback() throws {
        let store = makeStore()
        var clock = at(today, 10)
        store.now = { clock }
        let a = try XCTUnwrap(store.add(title: "A", dueDate: today))
        let b = try XCTUnwrap(store.add(title: "B", dueDate: today))
        let c = try XCTUnwrap(store.add(title: "C", dueDate: today))
        clock = at(today, 11)
        store.toggleDone(id: c.id)  // C는 이미 11시에 완료
        var calls = 0
        store.onTodosChanged = { calls += 1 }

        clock = at(today, 12)
        store.setDone(ids: [a.id, b.id, c.id], done: true)
        XCTAssertEqual(calls, 1, "여러 개여도 변경 알림 1번")
        let byID = Dictionary(uniqueKeysWithValues: store.todos.map { ($0.id, $0) })
        XCTAssertEqual(byID[a.id]?.doneAt, at(today, 12))
        XCTAssertEqual(byID[b.id]?.isDone, true)
        XCTAssertEqual(byID[c.id]?.doneAt, at(today, 11), "이미 완료인 항목은 완료 시각 그대로")

        store.setDone(ids: [a.id, b.id], done: false)
        XCTAssertEqual(calls, 2)
        XCTAssertNil(store.todos.first { $0.id == a.id }?.doneAt, "미완료 → doneAt 지움")
        XCTAssertEqual(store.todos.first { $0.id == a.id }?.updatedAt, at(today, 12))

        store.setDone(ids: [a.id], done: false)
        XCTAssertEqual(calls, 2, "바뀐 것이 없으면 알림 없음")
    }

    func testDeleteManyWithOneCallbackAndSaves() throws {
        let store = makeStore()
        let a = try XCTUnwrap(store.add(title: "A", dueDate: today))
        let b = try XCTUnwrap(store.add(title: "B", dueDate: today))
        let c = try XCTUnwrap(store.add(title: "C", dueDate: today))
        var calls = 0
        store.onTodosChanged = { calls += 1 }
        store.delete(ids: [a.id, c.id, UUID()])
        XCTAssertEqual(store.todos.map(\.id), [b.id])
        XCTAssertEqual(calls, 1)
        store.delete(ids: [UUID()])
        XCTAssertEqual(calls, 1, "없는 id만이면 아무것도 안 함")

        store.flushPendingSave()
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.todos.map(\.id), [b.id], "파일에서도 지워짐")
    }

    // MARK: 변경 알림 여러 구독자

    private final class CountingTimers: OneShotTimerFactory {
        final class T: OneShotTimer { var cancelled = false; func cancel() { cancelled = true } }
        var scheduled: [Date] = []
        func schedule(at date: Date, _ handler: @escaping @MainActor () -> Void) -> OneShotTimer {
            scheduled.append(date)
            return T()
        }
    }

    func testEditorSubscriptionDoesNotReplaceAlertReschedule() throws {
        let store = makeStore()
        store.now = { self.at(self.today, 8) }
        let lms = LmsStore(directory: tempDir, defaults: defaults)
        let timers = CountingTimers()
        let scheduler = NotchAlertScheduler(settings: AlertSettings(defaults: defaults), defaults: defaults,
                                            timerFactory: timers) { [weak store, weak lms] in
            .init(todos: store?.todos ?? [], lms: lms?.items ?? [], checked: lms?.checked ?? [:])
        }
        scheduler.now = { self.at(self.today, 8) }
        // AppDelegate와 같은 연결
        store.onTodosChanged = { [weak scheduler] in scheduler?.reschedule() }
        lms.onChange = { [weak scheduler] in scheduler?.reschedule() }

        // 편집기 구독을 붙인다
        var editorTodo = 0, editorLms = 0
        let t1 = store.todosChangedObservers.add { editorTodo += 1 }
        let t2 = lms.changeObservers.add { editorLms += 1 }

        let a = try XCTUnwrap(store.add(title: "오늘 마감", dueDate: today))
        XCTAssertEqual(scheduler.scheduledFireDate, at(today, 9), "노치 알림 재설정이 계속 불림")
        XCTAssertEqual(editorTodo, 1)

        store.update(id: a.id, title: "오늘 마감", dueDate: today.adding(days: 1))
        XCTAssertEqual(scheduler.scheduledFireDate, at(today.adding(days: 1), 9), "편집기에서 날짜를 바꾸면 알림 시각도 바뀜")
        XCTAssertEqual(editorTodo, 2)

        let before = timers.scheduled.count
        lms.isSectionCollapsed.toggle()
        XCTAssertEqual(editorLms, 1)
        XCTAssertGreaterThan(timers.scheduled.count, before, "LMS 변경도 기존 콜백으로 재설정")

        // 편집기를 닫으면 구독 해제 → 기존 콜백만 남음
        store.todosChangedObservers.remove(t1)
        lms.changeObservers.remove(t2)
        store.setDone(ids: [a.id], done: true)
        XCTAssertEqual(editorTodo, 2)
        XCTAssertNil(scheduler.scheduledFireDate, "완료 → 대상 없음 → 타이머 없음 (재설정은 계속 동작)")
        XCTAssertEqual(store.todosChangedObservers.count, 0)
    }

    // MARK: EditorBridge — 메시지 검사

    private let id1 = UUID(), id2 = UUID()
    private var ids: Set<UUID> { [id1, id2] }
    private let lmsUIDs: Set<String> = ["event-assignment-1"]

    private func parse(_ body: Any) -> Result<EditorBridge.Message, EditorBridge.Rejection> {
        EditorBridge.parse(body, todoIDs: ids, lmsUIDs: lmsUIDs)
    }

    func testBridgeAcceptsValidMessages() {
        XCTAssertEqual(parse(["type": "ready"]), .success(.ready))
        XCTAssertEqual(parse(["type": "updateTodo", "id": id1.uuidString, "title": "  한글 제목 ", "dueDate": "2026-11-30"]),
                       .success(.updateTodo(id: id1, title: "한글 제목", dueDate: LocalDate(year: 2026, month: 11, day: 30))))
        XCTAssertEqual(parse(["type": "setDone", "ids": [id1.uuidString, id2.uuidString], "done": true]),
                       .success(.setDone(ids: [id1, id2], done: true)))
        XCTAssertEqual(parse(["type": "deleteTodos", "ids": [id2.uuidString, UUID().uuidString, "nope"]]),
                       .success(.deleteTodos(ids: [id2])), "없는 id·이상한 값은 빼고 있는 것만")
        XCTAssertEqual(parse(["type": "toggleLmsCheck", "uid": "event-assignment-1"]),
                       .success(.toggleLmsCheck(uid: "event-assignment-1")))
    }

    func testBridgeRejectsUnknownAndMalformed() {
        XCTAssertEqual(parse("hello"), .failure(.notObject))
        XCTAssertEqual(parse(["type": "addTodo", "title": "x"]), .failure(.unknownType), "편집기에서 새 할 일 추가 없음")
        XCTAssertEqual(parse(["type": "fetch", "url": "https://example.com"]), .failure(.unknownType))
        XCTAssertEqual(parse(["nope": 1]), .failure(.unknownType))
        XCTAssertEqual(parse(["type": "updateTodo", "id": UUID().uuidString, "title": "x", "dueDate": "2026-11-30"]), .failure(.unknownID))
        XCTAssertEqual(parse(["type": "updateTodo", "id": "not-a-uuid", "title": "x", "dueDate": "2026-11-30"]), .failure(.unknownID))
        XCTAssertEqual(parse(["type": "setDone", "ids": [UUID().uuidString], "done": true]), .failure(.unknownID))
        XCTAssertEqual(parse(["type": "setDone", "ids": [id1.uuidString], "done": "yes"]), .failure(.missingField("done")))
        XCTAssertEqual(parse(["type": "deleteTodos", "ids": "all"]), .failure(.missingField("ids")))
    }

    func testBridgeTitleRules() {
        func update(_ title: String) -> Result<EditorBridge.Message, EditorBridge.Rejection> {
            parse(["type": "updateTodo", "id": id1.uuidString, "title": title, "dueDate": "2026-11-30"])
        }
        XCTAssertEqual(update(""), .failure(.emptyTitle))
        XCTAssertEqual(update("   \n\t "), .failure(.emptyTitle), "공백만")
        XCTAssertEqual(update(String(repeating: "가", count: 201)), .failure(.titleTooLong))
        if case .failure = update(String(repeating: "가", count: 200)) { XCTFail("200자는 허용") }
        if case .failure = update("  " + String(repeating: "a", count: 200) + "  ") { XCTFail("앞뒤 공백을 뺀 길이로 판단") }
        XCTAssertEqual(update("첫 줄\n둘째 줄"), .failure(.invalidTitle), "가운데 줄바꿈·제어 문자 거부")
    }

    func testBridgeDateRules() {
        for bad in ["2026-02-30", "2026-13-01", "26-11-30", "2026/11/30", "", "2026-11-30T00:00", "<script>"] {
            XCTAssertEqual(parse(["type": "updateTodo", "id": id1.uuidString, "title": "x", "dueDate": bad]),
                           .failure(.invalidDate), bad)
        }
        XCTAssertEqual(parse(["type": "updateTodo", "id": id1.uuidString, "title": "x"]), .failure(.missingField("dueDate")))
    }

    func testBridgeLmsOnlyToggleCheck() {
        XCTAssertEqual(parse(["type": "toggleLmsCheck", "uid": "event-assignment-999"]), .failure(.unknownID), "보여 준 적 없는 uid")
        XCTAssertEqual(parse(["type": "toggleLmsCheck"]), .failure(.missingField("uid")))
        // LMS 과제를 고치거나 지우는 메시지는 없다
        for type in ["updateLms", "deleteLms", "hideLms", "updateLmsItem"] {
            XCTAssertEqual(parse(["type": type, "uid": "event-assignment-1", "title": "x"]), .failure(.unknownType), type)
        }
        // LMS uid를 내 할 일 동작에 넣어도 통하지 않음
        XCTAssertEqual(parse(["type": "deleteTodos", "ids": ["event-assignment-1"]]), .failure(.unknownID))
    }

    // MARK: 상태 JSON

    func testStateLmsHasOnlyAllowedFieldsAndTodosMatchPanel() throws {
        var old = Todo(title: "어제 완료", dueDate: today, createdAt: at(today.adding(days: -3), 9))
        old.isDone = true
        old.doneAt = at(today.adding(days: -1), 20)
        let late = Todo(title: "나중 추가 · 이른 마감", dueDate: today, createdAt: at(today, 10))
        let early = Todo(title: "먼저 추가 · 늦은 마감", dueDate: today.adding(days: 3), createdAt: at(today, 8))
        let item = LmsItem(uid: "event-assignment-7", title: "HW7", courseName: "컴퓨터구조(Computer Architecture) 02분반",
                           dueDate: today, dueTime: LocalTime(hour: 23, minute: 59))
        let state = EditorBridge.makeState(todos: [old, early, late], lmsItems: [item], checked: ["event-assignment-7"],
                                           today: today, palette: ["PanelBackground": "rgba(0, 0, 0, 1.000)"], dark: true)
        XCTAssertEqual(state.todos.map(\.title), TodoOrdering.visible([old, early, late], today: today).map(\.title),
                       "패널과 같은 visible 규칙(어제 완료는 숨김)")
        XCTAssertEqual(state.todos.map(\.title), ["나중 추가 · 이른 마감", "먼저 추가 · 늦은 마감"])
        XCTAssertEqual(state.todos.map(\.dueRank), [0, 1])
        XCTAssertEqual(state.todos.map(\.addedRank), [1, 0], "추가순은 생성 시각")

        let json = try XCTUnwrap(EditorBridge.jsArgument(state) as? [String: Any])
        let lms = try XCTUnwrap(json["lms"] as? [[String: Any]])
        XCTAssertEqual(Set(lms[0].keys), ["uid", "title", "course", "dueDate", "checked"], "허용 필드만")
        XCTAssertEqual(lms[0]["course"] as? String, "컴퓨터구조 02분반", "짧은 과목명")
        XCTAssertEqual(lms[0]["checked"] as? Bool, true)
        XCTAssertEqual(Set(json.keys), ["todos", "lms", "today", "palette", "dark"])
        XCTAssertEqual(json["today"] as? String, "2026-11-08")

        let off = EditorBridge.makeState(todos: [], lmsItems: nil, checked: [], today: today, palette: [:], dark: false)
        XCTAssertNil(off.lms, "연동이 꺼져 있으면 LMS 칸 없음")
    }

    func testPaletteHasEveryRoleWithoutHex() {
        for appearance in [NSAppearance(named: .aqua)!, NSAppearance(named: .darkAqua)!] {
            let p = EditorWindowController.palette(for: appearance)
            XCTAssertEqual(Set(p.keys), Set(EditorWindowController.paletteRoles), "모든 역할 색을 Asset Catalog에서 읽음")
            XCTAssertTrue(p.values.allSatisfy { $0.hasPrefix("rgba(") && !$0.contains("#") })
        }
        let dark = EditorWindowController.palette(for: NSAppearance(named: .darkAqua)!)
        XCTAssertEqual(dark["PanelBackground"], "rgba(0, 0, 0, 1.000)", "어두운 모드 바탕 검정 (DESIGN.md)")
        XCTAssertNotEqual(EditorWindowController.palette(for: NSAppearance(named: .aqua)!)["PanelBackground"],
                          dark["PanelBackground"], "밝은·어두운 값이 다름")
    }

    // MARK: 이동 정책 (D-016)

    func testNavigationPolicyAllowsOnlyEditorFile() {
        let dir = URL(fileURLWithPath: "/Applications/DoIt.app/Contents/Resources/Web", isDirectory: true)
        let index = dir.appendingPathComponent("index.html")
        XCTAssertTrue(EditorBridge.allowsNavigation(to: index, editorFile: index))
        XCTAssertTrue(EditorBridge.allowsNavigation(to: URL(string: "file:///Applications/DoIt.app/Contents/Resources/Web/./index.html"), editorFile: index))
        XCTAssertFalse(EditorBridge.allowsNavigation(to: URL(string: "https://example.com/"), editorFile: index))
        XCTAssertFalse(EditorBridge.allowsNavigation(to: URL(string: "http://127.0.0.1:8080/index.html"), editorFile: index))
        XCTAssertFalse(EditorBridge.allowsNavigation(to: dir.appendingPathComponent("editor.js"), editorFile: index), "같은 폴더의 다른 파일")
        XCTAssertFalse(EditorBridge.allowsNavigation(to: URL(fileURLWithPath: "/etc/hosts"), editorFile: index))
        XCTAssertFalse(EditorBridge.allowsNavigation(to: URL(string: "file:///Applications/DoIt.app/Contents/Resources/Web/../Info.plist"), editorFile: index))
        XCTAssertFalse(EditorBridge.allowsNavigation(to: URL(string: "about:blank"), editorFile: index))
        XCTAssertFalse(EditorBridge.allowsNavigation(to: URL(string: "data:text/html,hi"), editorFile: index))
        XCTAssertFalse(EditorBridge.allowsNavigation(to: nil, editorFile: index))
    }

    // MARK: 실제 웹 파일 (번들) — CSP·textContent

    private final class Collector: NSObject, WKScriptMessageHandler {
        var messages: [Any] = []
        var onMessage: (() -> Void)?
        func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
            messages.append(message.body)
            onMessage?()
        }
    }

    private func loadEditorPage() async throws -> (WKWebView, Collector) {
        let dir = try XCTUnwrap(Bundle.main.url(forResource: "Web", withExtension: nil), "번들에 Web 폴더")
        let collector = Collector()
        let ready = expectation(description: "ready")
        collector.onMessage = { if collector.messages.contains(where: { ($0 as? [String: Any])?["type"] as? String == "ready" }) { ready.fulfill(); collector.onMessage = nil } }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(collector, name: EditorBridge.handlerName)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 760, height: 560), configuration: config)
        web.loadFileURL(dir.appendingPathComponent("index.html"), allowingReadAccessTo: dir)
        await fulfillment(of: [ready], timeout: 10)
        return (web, collector)
    }

    func testBundledPageLoadsScriptUnderCSPAndBlocksConnections() async throws {
        let (web, _) = try await loadEditorPage()  // ready가 왔다 = CSP 아래에서 editor.js가 실행됨
        // connect-src 'none': 같은 폴더의 파일이라도 fetch는 막혀야 한다 (네트워크 없이 확인)
        let result = try await web.callAsyncJavaScript("""
            const violations = [];
            document.addEventListener('securitypolicyviolation', (e) => violations.push(e.violatedDirective));
            let fetched = false;
            try { await fetch('editor.css'); fetched = true; } catch (e) {}
            const img = document.createElement('img');
            img.src = 'editor.css';
            document.body.appendChild(img);
            await new Promise((r) => setTimeout(r, 300));
            const styled = getComputedStyle(document.body).overflow;
            return { fetched, violations: violations.join(','), styled };
            """, contentWorld: .page) as? [String: Any]
        XCTAssertEqual(result?["fetched"] as? Bool, false, "fetch 차단")
        let v = result?["violations"] as? String ?? ""
        XCTAssertTrue(v.contains("connect-src"), "CSP connect-src 위반으로 막힘: \(v)")
        XCTAssertTrue(v.contains("img-src"), "CSP img-src 위반으로 막힘: \(v)")
        XCTAssertEqual(result?["styled"] as? String, "hidden", "editor.css는 style-src 'self'로 적용됨")
    }

    func testRenderPutsTitlesAsTextNotHTML() async throws {
        let (web, _) = try await loadEditorPage()
        let evil = "<img src=x onerror=\"window.pwned=1\">한글 <b>굵게</b>"
        let state = EditorBridge.makeState(
            todos: [Todo(title: evil, dueDate: today, createdAt: at(today, 9))],
            lmsItems: [LmsItem(uid: "event-assignment-1", title: "<i>HW</i>", courseName: nil, dueDate: today, dueTime: nil)],
            checked: [], today: today, palette: EditorWindowController.palette(for: NSAppearance(named: .darkAqua)!), dark: true)
        let arg = try XCTUnwrap(EditorBridge.jsArgument(state))
        _ = try await web.callAsyncJavaScript("window.doit.render(state)", arguments: ["state": arg], contentWorld: .page)
        let r = try await web.callAsyncJavaScript("""
            return {
              title: document.querySelector('#todo-list .title').textContent,
              lms: document.querySelector('#lms-list .title').textContent,
              imgs: document.querySelectorAll('main img, main b, main i').length,
              pwned: window.pwned === 1,
              bg: document.documentElement.style.getPropertyValue('--PanelBackground'),
              lmsShown: !document.getElementById('lms-section').hidden
            };
            """, contentWorld: .page) as? [String: Any]
        XCTAssertEqual(r?["title"] as? String, evil, "제목은 글자 그대로")
        XCTAssertEqual(r?["lms"] as? String, "<i>HW</i>")
        XCTAssertEqual(r?["imgs"] as? Int, 0, "HTML로 해석되지 않음")
        XCTAssertEqual(r?["pwned"] as? Bool, false)
        XCTAssertEqual(r?["bg"] as? String, "rgba(0, 0, 0, 1.000)", "역할 색이 CSS 변수로")
        XCTAssertEqual(r?["lmsShown"] as? Bool, true)
    }

    /// 다크 모드 흰색 번쩍임 방지: WebView가 기본 흰 바탕을 칠하지 않는다 (창 바탕이 비쳐 보임)
    func testWebViewDoesNotDrawDefaultBackground() {
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        XCTAssertEqual(web.value(forKey: "drawsBackground") as? Bool, true, "기본값은 흰 바탕을 칠함")
        EditorWindowController.disableWebViewBackground(web)
        XCTAssertEqual(web.value(forKey: "drawsBackground") as? Bool, false)
    }
}
