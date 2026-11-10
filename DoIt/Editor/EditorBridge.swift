import Foundation

/// 전체 편집기 웹 화면 ↔ 앱 사이의 약속 (T-006, ARCHITECTURE §3.7·D-016).
/// **순수 함수만** 둔다: 웹에서 온 메시지 검사, 웹으로 넘길 상태 만들기, 창 이동 허용 판단. (테스트 대상)
enum EditorBridge {
    /// 제목 최대 길이 (앞뒤 공백을 뺀 글자 수)
    static let maxTitleLength = 200
    /// 메시지 핸들러 이름 (`window.webkit.messageHandlers.doit`)
    static let handlerName = "doit"

    // MARK: 웹 → 앱 메시지

    /// 검사를 통과한 메시지. LMS 쪽은 체크 전환 하나뿐이다 (읽기 전용, D-011)
    enum Message: Equatable {
        case ready
        case updateTodo(id: UUID, title: String, dueDate: LocalDate)
        case setDone(ids: Set<UUID>, done: Bool)
        case deleteTodos(ids: Set<UUID>)
        case toggleLmsCheck(uid: String)
    }

    enum Rejection: Error, Equatable {
        case notObject
        case unknownType
        case missingField(String)
        case unknownID
        case emptyTitle
        case titleTooLong
        case invalidTitle
        case invalidDate
    }

    /// 웹에서 온 메시지 본문(`WKScriptMessage.body`)을 검사한다. 웹은 믿지 않는다.
    /// - `todoIDs`: 지금 실제로 있는 내 할 일 id
    /// - `lmsUIDs`: 지금 편집기에 보이는 LMS 과제 uid (보여 준 적 없는 uid는 거부)
    /// - 여러 개(ids)는 실제로 있는 것만 남기고, 하나도 없으면 거부
    static func parse(_ body: Any, todoIDs: Set<UUID>, lmsUIDs: Set<String>) -> Result<Message, Rejection> {
        guard let dict = body as? [String: Any] else { return .failure(.notObject) }
        guard let type = dict["type"] as? String else { return .failure(.unknownType) }
        switch type {
        case "ready":
            return .success(.ready)

        case "updateTodo":
            guard let idText = dict["id"] as? String else { return .failure(.missingField("id")) }
            guard let id = UUID(uuidString: idText), todoIDs.contains(id) else { return .failure(.unknownID) }
            guard let rawTitle = dict["title"] as? String else { return .failure(.missingField("title")) }
            let title: String
            switch validateTitle(rawTitle) {
            case .success(let t): title = t
            case .failure(let r): return .failure(r)
            }
            guard let dateText = dict["dueDate"] as? String else { return .failure(.missingField("dueDate")) }
            guard let date = LocalDate(string: dateText) else { return .failure(.invalidDate) }
            return .success(.updateTodo(id: id, title: title, dueDate: date))

        case "setDone":
            guard let done = dict["done"] as? Bool else { return .failure(.missingField("done")) }
            switch existingIDs(dict["ids"], in: todoIDs) {
            case .success(let ids): return .success(.setDone(ids: ids, done: done))
            case .failure(let r): return .failure(r)
            }

        case "deleteTodos":
            switch existingIDs(dict["ids"], in: todoIDs) {
            case .success(let ids): return .success(.deleteTodos(ids: ids))
            case .failure(let r): return .failure(r)
            }

        case "toggleLmsCheck":
            guard let uid = dict["uid"] as? String else { return .failure(.missingField("uid")) }
            guard lmsUIDs.contains(uid) else { return .failure(.unknownID) }
            return .success(.toggleLmsCheck(uid: uid))

        default:
            return .failure(.unknownType)
        }
    }

    /// 앞뒤 공백 제거 → 빈칸 거부 → 200자 초과 거부 → 줄바꿈·제어 문자 거부
    static func validateTitle(_ raw: String) -> Result<String, Rejection> {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return .failure(.emptyTitle) }
        guard t.count <= maxTitleLength else { return .failure(.titleTooLong) }
        guard !t.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return .failure(.invalidTitle)
        }
        return .success(t)
    }

    private static func existingIDs(_ value: Any?, in todoIDs: Set<UUID>) -> Result<Set<UUID>, Rejection> {
        guard let list = value as? [Any] else { return .failure(.missingField("ids")) }
        let ids = Set(list.compactMap { ($0 as? String).flatMap(UUID.init(uuidString:)) }.filter { todoIDs.contains($0) })
        return ids.isEmpty ? .failure(.unknownID) : .success(ids)
    }

    // MARK: 앱 → 웹 상태

    /// 내 할 일 한 줄. `dueRank`는 마감일순(`TodoOrdering`) 위치, `addedRank`는 추가순 위치
    struct TodoRow: Encodable, Equatable {
        let id: String
        let title: String
        let dueDate: String
        let isDone: Bool
        let dueRank: Int
        let addedRank: Int
    }

    /// LMS 과제 한 줄. **허용 필드만**: uid · 과제명 · 짧은 과목명 · 마감일 · 체크 여부 (T-006 보안 규칙)
    struct LmsRow: Encodable, Equatable {
        let uid: String
        let title: String
        let course: String?
        let dueDate: String
        let checked: Bool
    }

    struct State: Encodable, Equatable {
        let todos: [TodoRow]
        /// 패널에 LMS 칸이 안 보이는 상황(연동 꺼짐·주소 없음)이면 nil
        let lms: [LmsRow]?
        let today: String
        /// 역할 이름 → CSS 색 문자열 (앱이 Asset Catalog에서 읽음)
        let palette: [String: String]
        let dark: Bool
    }

    /// 보이는 내 할 일은 패널과 같은 `TodoOrdering.visible`. LMS는 패널 LMS 칸과 같은 항목(`visibleItems`)
    static func makeState(todos: [Todo], lmsItems: [LmsItem]?, checked: Set<String>, today: LocalDate,
                          palette: [String: String], dark: Bool) -> State {
        let visible = TodoOrdering.visible(todos, today: today)
        // 추가순: 미완료 먼저(패널과 같이 완료는 아래), 그 안에서 생성 시각 → id
        let added = visible.sorted { a, b in
            if a.isDone != b.isDone { return !a.isDone }
            if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
            return a.id.uuidString < b.id.uuidString
        }
        let addedRank = Dictionary(uniqueKeysWithValues: added.enumerated().map { ($1.id, $0) })
        let rows = visible.enumerated().map { i, t in
            TodoRow(id: t.id.uuidString, title: t.title, dueDate: t.dueDate.string, isDone: t.isDone,
                    dueRank: i, addedRank: addedRank[t.id] ?? i)
        }
        let lms = lmsItems.map { items in
            items.map { item in
                LmsRow(uid: item.uid, title: item.title,
                       course: item.courseName.map(LmsDisplay.shortCourseName),
                       dueDate: item.dueDate.string, checked: checked.contains(item.uid))
            }
        }
        return State(todos: rows, lms: lms, today: today.string, palette: palette, dark: dark)
    }

    /// `callAsyncJavaScript`의 인자로 넘길 값 (JSON → Foundation 객체). JS 문자열을 이어 붙이지 않는다
    static func jsArgument(_ state: State) -> Any? {
        guard let data = try? JSONEncoder().encode(state) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    // MARK: 창 이동 정책 (D-016)

    /// 처음 로드한 편집기 파일(`index.html`)로 가는 이동만 허용한다. `http(s)`·다른 파일·`about:` 등은 모두 거부
    static func allowsNavigation(to url: URL?, editorFile: URL) -> Bool {
        guard let url, url.isFileURL else { return false }
        return url.standardizedFileURL.resolvingSymlinksInPath().path
            == editorFile.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
