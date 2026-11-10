import Foundation
import Observation
import os

private let storeLogger = Logger(subsystem: "com.personal.doit", category: "store")

/// 할 일 저장소. 앱 전체에서 하나만 쓰고, 뷰는 여기서만 읽고 쓴다. (ARCHITECTURE §3.5)
/// - 불러오기: 앱 시작 시 1번 (`load()`)
/// - 저장: 변경이 있을 때만. 연속 변경은 약 0.5초 디바운스 후 원자적 쓰기 (반복 저장 루프 없음)
@MainActor
@Observable
final class TodoStore {
    static let schemaVersion = 1

    /// 저장된 순서 그대로 (화면에는 `sortedTodos`를 쓴다)
    private(set) var todos: [Todo] = [] {
        didSet {
            onTodosChanged()              // 알림 재계산 (T-005)
            todosChangedObservers.notify() // 추가 구독자 (T-006 전체 편집기)
        }
    }
    /// D-day 계산 기준 날짜. 날짜가 바뀌면 갱신되어 화면이 다시 그려진다
    private(set) var today: LocalDate

    @ObservationIgnored let fileURL: URL
    @ObservationIgnored private let saveDelay: TimeInterval
    @ObservationIgnored private var pendingSave: DispatchWorkItem?
    @ObservationIgnored private var dayObserver: NSObjectProtocol?
    /// 현재 시각 (테스트에서 바꿀 수 있게)
    @ObservationIgnored var now: () -> Date = { Date() }

    /// `~/Library/Application Support/DoIt/todos.json`
    nonisolated static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("DoIt", isDirectory: true).appendingPathComponent("todos.json")
    }

    init(fileURL: URL = TodoStore.defaultFileURL, saveDelay: TimeInterval = 0.5) {
        self.fileURL = fileURL
        self.saveDelay = saveDelay
        self.today = LocalDate.today()
    }

    // MARK: 읽기

    var sortedTodos: [Todo] { TodoOrdering.sorted(todos) }

    /// 패널에 보일 항목 (전날 이전에 완료한 항목 숨김, PRD F4)
    var visibleTodos: [Todo] { TodoOrdering.visible(todos, today: today) }

    /// 오늘 날짜가 바뀌었을 때 (보이는 항목 수가 바뀔 수 있어 패널 높이 재계산용)
    @ObservationIgnored var onTodayChanged: () -> Void = {}
    /// 할 일이 추가·체크·삭제·정리·불러오기로 바뀌었을 때 (T-005 노치 알림 재계산)
    @ObservationIgnored var onTodosChanged: () -> Void = {}
    /// 할 일 변경을 받을 추가 구독자 (T-006). `onTodosChanged`를 덮어쓰지 않고 여러 곳이 받을 수 있다
    @ObservationIgnored let todosChangedObservers = ChangeObservers()

    var hasPendingSave: Bool { pendingSave != nil }

    // MARK: 날짜 변경 (이벤트 방식, 타이머 없음)

    /// 자정이 지나면 시스템이 보내는 알림을 받아 D-day를 다시 계산한다.
    func startObservingDayChanges() {
        guard dayObserver == nil else { return }
        dayObserver = NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                storeLogger.info("calendar day changed")
                self?.refreshToday()
            }
        }
    }

    /// 오늘 날짜를 다시 계산한다 (바뀌었을 때만 화면 갱신)
    func refreshToday() {
        let newToday = LocalDate.today(now: now())
        if newToday != today {
            storeLogger.info("today \(self.today.string, privacy: .public) → \(newToday.string, privacy: .public)")
            today = newToday
            onTodayChanged()
        }
    }

    // MARK: 쓰기

    /// 할 일 추가. 빈 문자열·공백만 있는 제목은 무시하고 nil을 돌려준다.
    @discardableResult
    func add(title: String, dueDate: LocalDate) -> Todo? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let todo = Todo(title: trimmed, dueDate: dueDate, createdAt: now())
        todos.append(todo)
        scheduleSave()
        return todo
    }

    /// 완료/미완료 전환. `doneAt`을 기록하거나 지우고 `updatedAt`을 갱신한다.
    func toggleDone(id: UUID) {
        guard let i = todos.firstIndex(where: { $0.id == id }) else { return }
        let t = now()
        todos[i].isDone.toggle()
        todos[i].doneAt = todos[i].isDone ? t : nil
        todos[i].updatedAt = t
        scheduleSave()
    }

    /// 삭제 (PRD F7). 없는 id면 아무것도 안 함
    func delete(id: UUID) {
        guard let i = todos.firstIndex(where: { $0.id == id }) else { return }
        todos.remove(at: i)
        scheduleSave()
    }

    // MARK: 전체 편집기용 (T-006). 여러 개를 바꿔도 `todos`에 한 번만 대입해 변경 알림은 1번

    /// 제목·마감일 수정. 제목은 앞뒤 공백을 빼고 비면 거부(false). 바뀐 것이 없으면 아무것도 안 함(true)
    @discardableResult
    func update(id: UUID, title: String, dueDate: LocalDate) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = todos.firstIndex(where: { $0.id == id }) else { return false }
        guard todos[i].title != trimmed || todos[i].dueDate != dueDate else { return true }
        var next = todos
        next[i].title = trimmed
        next[i].dueDate = dueDate
        next[i].updatedAt = now()
        todos = next
        scheduleSave()
        return true
    }

    /// 여러 개 완료/미완료. `doneAt` 규칙은 `toggleDone`과 같다 (완료 → 지금, 미완료 → nil).
    /// 이미 그 상태인 항목은 건드리지 않는다 (완료 시각이 바뀌지 않게)
    func setDone(ids: Set<UUID>, done: Bool) {
        let t = now()
        var next = todos
        var changed = false
        for i in next.indices where ids.contains(next[i].id) && next[i].isDone != done {
            next[i].isDone = done
            next[i].doneAt = done ? t : nil
            next[i].updatedAt = t
            changed = true
        }
        guard changed else { return }
        todos = next
        scheduleSave()
    }

    /// 여러 개 삭제 (진짜 삭제, PRD F7·F13). 없는 id는 무시
    func delete(ids: Set<UUID>) {
        let next = todos.filter { !ids.contains($0.id) }
        guard next.count != todos.count else { return }
        todos = next
        scheduleSave()
    }

    /// 기록 정리 (T-009): 주어진 id 중 **완료한 항목만** 지우고 즉시 저장한다. 완료 안 한 할 일은 절대 지우지 않는다.
    /// 지운 항목을 돌려준다 (백업은 호출한 쪽이 먼저 끝낸다)
    @discardableResult
    func removeCompleted(ids: Set<UUID>) -> [Todo] {
        let removed = todos.filter { ids.contains($0.id) && $0.isDone }
        guard !removed.isEmpty else { return [] }
        let removedIDs = Set(removed.map(\.id))
        todos.removeAll { removedIDs.contains($0.id) }
        pendingSave?.cancel()
        pendingSave = nil
        saveNow()
        return removed
    }

    // MARK: 불러오기

    /// 앱 시작 시 1번. 파일이 없으면 빈 목록, 깨졌으면 백업해 두고 빈 목록으로 시작한다 (사용자 데이터를 지우지 않는다).
    func load() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            storeLogger.info("no file, start empty: \(self.fileURL.path, privacy: .public)")
            todos = []
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let file = try Self.makeDecoder().decode(TodoFile.self, from: data)
            guard file.schemaVersion == Self.schemaVersion else {
                throw StoreError.unsupportedSchema(file.schemaVersion)
            }
            todos = file.todos
            storeLogger.info("loaded \(file.todos.count, privacy: .public) todos")
        } catch {
            storeLogger.error("load failed: \(String(describing: error), privacy: .public)")
            backupCorruptFile()
            todos = []
        }
    }

    /// 깨진 파일을 `todos.corrupt-<시각>.json`으로 이름을 바꿔 보관한다.
    private func backupCorruptFile() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: now())
        let dir = fileURL.deletingLastPathComponent()
        var backup = dir.appendingPathComponent("todos.corrupt-\(stamp).json")
        var n = 2
        while FileManager.default.fileExists(atPath: backup.path) {  // 같은 초에 두 번 생겨도 덮어쓰지 않음
            backup = dir.appendingPathComponent("todos.corrupt-\(stamp)-\(n).json")
            n += 1
        }
        do {
            try FileManager.default.moveItem(at: fileURL, to: backup)
            storeLogger.error("corrupt file backed up: \(backup.path, privacy: .public)")
        } catch {
            storeLogger.error("backup failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: 저장

    /// 변경 1번마다 이전 대기 작업을 취소하고 1번만 기다린다 (일회성 디바운스, ARCHITECTURE §5 예외).
    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flushPendingSave() }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDelay, execute: work)
    }

    /// 대기 중인 저장이 있으면 지금 저장한다 (디바운스 만료 시, 앱 종료 시).
    func flushPendingSave() {
        guard let work = pendingSave else { return }
        work.cancel()
        pendingSave = nil
        saveNow()
    }

    /// 즉시 원자적으로 저장한다.
    func saveNow() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try Self.makeEncoder().encode(TodoFile(schemaVersion: Self.schemaVersion, todos: todos))
            try data.write(to: fileURL, options: .atomic)
            storeLogger.debug("saved \(self.todos.count, privacy: .public) todos")
        } catch {
            storeLogger.error("save failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: JSON 형식

    struct TodoFile: Codable {
        var schemaVersion: Int
        var todos: [Todo]
    }

    enum StoreError: Error {
        case unsupportedSchema(Int)
    }

    /// 사람이 읽을 수 있게 prettyPrinted + sortedKeys, 날짜·시각은 ISO 8601 (밀리초 포함)
    nonisolated static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(isoFormatter(fractional: true).string(from: date))
        }
        return encoder
    }

    nonisolated static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            // 손으로 고친 파일도 읽을 수 있게 밀리초 없는 형식도 받는다
            if let date = isoFormatter(fractional: true).date(from: text) ?? isoFormatter(fractional: false).date(from: text) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "ISO 8601 시각이 아님: \(text)")
        }
        return decoder
    }

    private nonisolated static func isoFormatter(fractional: Bool) -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        f.timeZone = .current
        return f
    }
}
