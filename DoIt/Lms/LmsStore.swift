import Foundation
import Observation
import os

private let lmsStoreLogger = Logger(subsystem: "com.personal.doit", category: "lms")

/// 마감이 지난 LMS 과제 기록 (PRD §6 `lms-history.json`, F13, D-012)
/// 과제명·과목명·마감일 + 보관 시작 시각만. 시각·설명·링크는 없다
struct LmsHistoryItem: Identifiable, Codable, Equatable {
    let uid: String
    var title: String
    var courseName: String?
    var dueDate: LocalDate
    /// 처음 기록에 넣은 시각 (갱신해도 바뀌지 않음)
    let archivedAt: Date

    var id: String { uid }
    /// 화면 표시용 (시각 없음)
    var asItem: LmsItem { LmsItem(uid: uid, title: title, courseName: courseName, dueDate: dueDate, dueTime: nil) }
}

/// LMS 과제 저장소 (ARCHITECTURE §3.8, D-010). `TodoStore`와 완전히 분리한다.
/// - `lms.json`: 피드 과제 중 마감이 **오늘 ~ 8주**인 것 (읽기 전용 캐시, 동기화 성공 시 통째로 교체, 원자적 쓰기)
/// - `lms-history.json`: 마감이 지난 과제 기록 (UID 기준 upsert, T-009). 정리는 사용자 확인 후에만
/// - `lms-state.json`: 사용자 체크 상태 (UID → 체크 시각). 그 UID가 `lms.json`이나 history에 있는 동안 유지
/// - 설정(켜기·기간·칸 접힘·가린 주소)과 동기화 기록은 UserDefaults. **피드 주소 자체는 본인만 읽는 파일 `lms-feed-url`에만** 있다 (D-009·D-018)
@MainActor
@Observable
final class LmsStore {
    static let schemaVersion = 1
    /// `lms-state.json` 형식 버전. v1(T-007, `goneSince` 있음) → v2(T-009, `doneUids`만)
    static let stateSchemaVersion = 2

    /// 마감 오늘 ~ 8주 (피드 순서)
    private(set) var items: [LmsItem] = []
    /// 마감이 지난 과제 기록 (마감일 순)
    private(set) var history: [LmsHistoryItem] = []
    /// UID → 체크한 시각
    private(set) var checked: [String: Date] = [:]

    // MARK: 설정 (UserDefaults)
    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Keys.enabled); notifyChanged() }
    }
    var weeks: Int {
        didSet {
            let w = LmsDisplay.clampWeeks(weeks)
            if w != weeks { weeks = w }  // didSet 안에서의 대입은 didSet을 다시 부르지 않는다
            defaults.set(w, forKey: Keys.weeks)
            notifyChanged()
        }
    }
    var isSectionCollapsed: Bool {
        didSet { defaults.set(isSectionCollapsed, forKey: Keys.collapsed); notifyChanged() }
    }
    /// 설정 창에 보일 가린 주소 (`https://<호스트>/…/••••.ics`). nil이면 주소가 저장되지 않음.
    /// 주소 파일을 매번 읽지 않으려고 가린 문자열만 따로 둔다 (주소 원문 아님)
    private(set) var maskedFeedURL: String?
    private(set) var record: LmsSyncRecord
    /// 지금 요청 중인지
    var isSyncing = false
    private(set) var saveError: String?
    private(set) var isDisconnectPending: Bool
    @ObservationIgnored private var failedWrites: Set<String> = []
    @ObservationIgnored private var unpersistedPast: [LmsItem] = []
    @ObservationIgnored private var pendingReplacement: (items: [LmsItem], today: LocalDate)?
    var hasPendingSave: Bool { pendingReplacement != nil || !failedWrites.isEmpty }

    /// 상대 시각("n시간 전")·버튼 활성 판단 기준 시각. 패널 펼침·설정 열기·일회성 지연 때 갱신 (주기 타이머 없음)
    private(set) var displayNow: Date

    @ObservationIgnored let cacheURL: URL
    @ObservationIgnored let stateURL: URL
    @ObservationIgnored let historyURL: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var now: () -> Date = { Date() }
    /// 패널 높이에 영향을 주는 변화 (항목·체크·설정·상태)
    @ObservationIgnored var onChange: () -> Void = {}
    /// 추가 구독자 (T-006 전체 편집기 등). `onChange`와 함께 불린다
    @ObservationIgnored let changeObservers = ChangeObservers()

    private func notifyChanged() {
        onChange()
        changeObservers.notify()
    }

    enum Keys {
        static let enabled = "lmsEnabled"
        static let weeks = "lmsWeeks"
        static let collapsed = "lmsSectionCollapsed"
        static let masked = "lmsMaskedFeedURL"
        static let record = "lmsSyncRecord"
        static let historySeeded = "lmsHistorySeeded"
        static let disconnectPending = "lmsDisconnectPending"
    }

    /// T-009 이후 피드 전체(200)를 한 번이라도 받아 지난 과제를 기록에 채웠는지.
    /// false면 다음 요청은 조건부 헤더(ETag) 없이 보낸다 — 304로는 본문이 없어 지난 과제를 채울 수 없기 때문 (1번만)
    var isHistorySeeded: Bool { defaults.bool(forKey: Keys.historySeeded) }
    func markHistorySeeded() { defaults.set(true, forKey: Keys.historySeeded) }

    nonisolated static var defaultDirectory: URL {
        TodoStore.defaultFileURL.deletingLastPathComponent()
    }

    init(directory: URL = LmsStore.defaultDirectory, defaults: UserDefaults = .standard) {
        cacheURL = directory.appendingPathComponent("lms.json")
        stateURL = directory.appendingPathComponent("lms-state.json")
        historyURL = directory.appendingPathComponent("lms-history.json")
        self.defaults = defaults
        isDisconnectPending = defaults.bool(forKey: Keys.disconnectPending)
        isEnabled = defaults.bool(forKey: Keys.enabled)  // 기본 끔
        let w = defaults.integer(forKey: Keys.weeks)
        weeks = w == 0 ? LmsDisplay.defaultWeeks : LmsDisplay.clampWeeks(w)
        isSectionCollapsed = defaults.bool(forKey: Keys.collapsed)
        maskedFeedURL = defaults.string(forKey: Keys.masked)
        record = defaults.data(forKey: Keys.record).flatMap { try? JSONDecoder().decode(LmsSyncRecord.self, from: $0) } ?? LmsSyncRecord()
        displayNow = Date()
    }

    // MARK: 읽기

    var hasFeedURL: Bool { maskedFeedURL != nil }

    /// 현재 과제 + 기록 (화면 표시·달력용, 같은 UID는 현재 쪽)
    var allItems: [LmsItem] {
        let current = Set(items.map(\.uid))
        return items + history.filter { !current.contains($0.uid) }.map(\.asItem)
    }

    /// 패널 LMS 칸에 보일 항목. 어제 마감인 미완료(빨간색)는 history에서 온다
    func visibleItems(today: LocalDate) -> [LmsItem] {
        LmsDisplay.visible(allItems, checked: checked, today: today, weeks: weeks)
    }

    func isChecked(_ uid: String) -> Bool { checked[uid] != nil }

    /// 패널 오류 문구
    var panelMessage: String? { LmsDisplay.panelMessage(record: record, now: displayNow) }

    /// 패널에 LMS 칸을 보일지: 연동 켜짐 + 주소 있음 + (보일 항목이 있거나 오류 문구가 있음)
    func isSectionShown(today: LocalDate) -> Bool {
        isEnabled && hasFeedURL && (!visibleItems(today: today).isEmpty || panelMessage != nil)
    }

    func refreshDisplayNow() {
        displayNow = now()
    }

    // MARK: 불러오기

    func load(today: LocalDate = LocalDate.today()) {
        items = loadCache()
        history = loadHistory()
        loadState()
        archivePastItems(today: today)  // 앱을 꺼 둔 사이 마감이 지난 과제
        lmsStoreLogger.info("lms loaded: \(self.items.count, privacy: .public) items, \(self.history.count, privacy: .public) history, \(self.checked.count, privacy: .public) checked")
    }

    private func loadCache() -> [LmsItem] {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return [] }
        do {
            let file = try TodoStore.makeDecoder().decode(CacheFile.self, from: Data(contentsOf: cacheURL))
            guard file.schemaVersion == Self.schemaVersion else { return [] }
            return file.items
        } catch {
            // 캐시일 뿐이라 버리고 다음 동기화 때 다시 받는다
            lmsStoreLogger.error("lms cache unreadable, ignore: \(String(describing: type(of: error)), privacy: .public)")
            return []
        }
    }

    private func loadHistory() -> [LmsHistoryItem] {
        guard FileManager.default.fileExists(atPath: historyURL.path) else { return [] }
        do {
            let file = try TodoStore.makeDecoder().decode(HistoryFile.self, from: Data(contentsOf: historyURL))
            guard file.schemaVersion == Self.schemaVersion else { throw StoreError.unsupported }
            return file.items
        } catch {
            // 기록은 사용자 데이터라 지우지 않고 이름을 바꿔 보관한다
            lmsStoreLogger.error("lms history unreadable, backup: \(String(describing: type(of: error)), privacy: .public)")
            backupCorrupt(historyURL, prefix: "lms-history")
            return []
        }
    }

    private func loadState() {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return }
        do {
            let data = try Data(contentsOf: stateURL)
            let file = try TodoStore.makeDecoder().decode(StateFile.self, from: data)
            switch file.schemaVersion {
            case Self.stateSchemaVersion:
                checked = file.doneUids
            case 1:
                // T-007 형식(`goneSince` 포함) → 원본을 복사해 두고 v2로 변환 (PRD §6: 형식 변경 시 백업 후 변환)
                checked = file.doneUids
                let backup = uniqueURL(prefix: "lms-state.v1-backup")
                try FileManager.default.copyItem(at: stateURL, to: backup)
                writeState()
                lmsStoreLogger.info("lms state v1 → v2 (backup \(backup.lastPathComponent, privacy: .public))")
            default:
                throw StoreError.unsupported
            }
        } catch {
            // 사용자 체크 상태는 지우지 않고 이름을 바꿔 보관한다
            lmsStoreLogger.error("lms state unreadable, backup: \(String(describing: type(of: error)), privacy: .public)")
            backupCorrupt(stateURL, prefix: "lms-state")
        }
    }

    // MARK: 동기화 결과 반영 (LmsSyncService가 호출)

    /// 동기화 성공:
    /// - 마감이 지난 과제(피드에 있는 것 + 지금 캐시에 있던 것) → history로 upsert
    /// - 마감 오늘 ~ 8주 → `lms.json` 통째로 교체. 마감 전에 피드에서 사라진 과제는 history에 넣지 않는다
    /// - 체크 상태: `lms.json`이나 history에 없는 UID는 정리
    @discardableResult
    func replaceItems(with parsed: [LmsItem], today: LocalDate) -> Bool {
        // history를 먼저 내구성 있게 저장한다. 어느 단계에서 멈춰도 과거 원본은
        // 기존 cache 또는 history 중 적어도 한 파일에 남는다.
        pendingReplacement = (parsed, today)
        // 다음 응답이 와도 이전 응답의 아직 저장하지 못한 과거 기록은 합쳐서 보존한다.
        for item in parsed.filter({ $0.dueDate < today }) {
            unpersistedPast.removeAll { $0.uid == item.uid }
            unpersistedPast.append(item)
        }
        let previousHistory = history
        _ = upsertHistory(unpersistedPast)
        _ = upsertHistory(items.filter { $0.dueDate < today })
        _ = upsertHistory(parsed.filter { $0.dueDate < today })
        let nextHistory = history
        history = previousHistory
        if nextHistory != history || failedWrites.contains(historyURL.lastPathComponent) {
            guard write(HistoryFile(schemaVersion: Self.schemaVersion, items: nextHistory), to: historyURL) else { return false }
        }
        history = nextHistory
        unpersistedPast = []
        let nextItems = parsed.filter { LmsDisplay.cacheRange(today: today).contains($0.dueDate) }
        guard write(CacheFile(schemaVersion: Self.schemaVersion, items: nextItems), to: cacheURL) else {
            notifyChanged()
            return false
        }
        items = nextItems
        pendingReplacement = nil
        let checksSaved = cleanUpChecks()
        notifyChanged()
        return checksSaved
    }

    /// history 저장이 실패하면 기존 cache를 줄이지 않는다.
    @discardableResult
    func archivePastItems(today: LocalDate) -> Bool {
        if pendingReplacement != nil, !retryPendingSaves() { return false }
        guard items.contains(where: { $0.dueDate < today }) else { return true }
        return replaceItems(with: items, today: today)
    }

    /// 자동 재시도 루프 없이 설정 버튼·종료 시에만 호출한다.
    @discardableResult
    func retryPendingSaves() -> Bool {
        var success = true
        if let pending = pendingReplacement {
            success = replaceItems(with: pending.items, today: pending.today)
        } else if failedWrites.contains(historyURL.lastPathComponent) {
            success = writeHistory()
        }
        if failedWrites.contains(stateURL.lastPathComponent) { success = writeState() && success }
        return success && !hasPendingSave
    }

    func setDisconnectPending(_ pending: Bool) {
        isDisconnectPending = pending
        defaults.set(pending, forKey: Keys.disconnectPending)
        notifyChanged()
    }

    /// UID 기준으로 넣거나 고친다 (`archivedAt`은 처음 값 유지). 바뀐 게 있으면 true
    @discardableResult
    private func upsertHistory(_ past: [LmsItem]) -> Bool {
        guard !past.isEmpty else { return false }
        var changed = false
        for item in past {
            if let i = history.firstIndex(where: { $0.uid == item.uid }) {
                let h = history[i]
                if h.title != item.title || h.courseName != item.courseName || h.dueDate != item.dueDate {
                    history[i].title = item.title
                    history[i].courseName = item.courseName
                    history[i].dueDate = item.dueDate
                    changed = true
                }
            } else {
                history.append(LmsHistoryItem(uid: item.uid, title: item.title, courseName: item.courseName,
                                              dueDate: item.dueDate, archivedAt: now()))
                changed = true
            }
        }
        if changed { history.sort { ($0.dueDate, $0.uid) < ($1.dueDate, $1.uid) } }
        return changed
    }

    func setRecord(_ r: LmsSyncRecord) {
        record = r
        if let data = try? JSONEncoder().encode(r) { defaults.set(data, forKey: Keys.record) }
        refreshDisplayNow()
        notifyChanged()
    }

    /// 새 주소를 저장했을 때
    func feedURLSaved(masked: String) {
        pendingReplacement = nil
        // 이전 연결의 미저장 응답은 재시도로 복원하지 않는다. 원본 cache는 다음 안전한 교체까지 유지.
        failedWrites.remove(cacheURL.lastPathComponent)
        failedWrites.remove(historyURL.lastPathComponent)
        updateSaveError()
        setDisconnectPending(false)
        defaults.set(false, forKey: Keys.historySeeded)
        maskedFeedURL = masked
        defaults.set(masked, forKey: Keys.masked)
        setRecord(record.resetForNewURL())
    }

    /// 연결 해제: 가린 주소·캐시(`lms.json`)·동기화 기록 삭제. **체크 상태와 기록(history)은 유지** (주소 파일 삭제는 서비스가 함)
    @discardableResult
    func disconnect() -> Bool {
        // 미저장 이동을 먼저 저장한다. 실패하면 원본 cache를 지우지 않는다.
        guard retryPendingSaves() else { return false }
        do {
            if FileManager.default.fileExists(atPath: cacheURL.path) {
                try FileManager.default.removeItem(at: cacheURL)
            }
        } catch { return false }
        pendingReplacement = nil
        maskedFeedURL = nil
        defaults.removeObject(forKey: Keys.masked)
        defaults.set(false, forKey: Keys.historySeeded)
        items = []
        setDisconnectPending(false)
        setRecord(record.resetForNewURL())
        return true
    }

    // MARK: 체크

    @discardableResult
    func toggleCheck(uid: String) -> Bool {
        if checked[uid] != nil {
            checked[uid] = nil
        } else {
            checked[uid] = now()
        }
        let saved = writeState()
        notifyChanged()
        return saved
    }

    /// `lms.json`에도 history에도 없는 UID의 체크 상태를 지운다 (동기화 성공 때만, T-009 규칙)
    private func cleanUpChecks() -> Bool {
        let known = Set(items.map(\.uid)).union(history.map(\.uid))
        let gone = checked.keys.filter { !known.contains($0) }
        guard !gone.isEmpty else { return true }
        for uid in gone { checked[uid] = nil }
        return writeState()
    }

    // MARK: 기록 정리 (HistoryService가 사용자 확인 후 호출)

    /// history 항목과 체크 상태를 지운다. 백업은 호출한 쪽이 먼저 끝낸다
    @discardableResult
    func removeHistory(uids: Set<String>, checks checkUIDs: Set<String>) -> Bool {
        // 대기 중인 응답 때문에 사용자가 지운 기록이 나중에 복원되지 않게 한다.
        guard retryPendingSaves() else { return false }
        let nextHistory = history.filter { !uids.contains($0.uid) }
        if nextHistory != history {
            guard write(HistoryFile(schemaVersion: Self.schemaVersion, items: nextHistory), to: historyURL) else { return false }
            history = nextHistory
        }
        let nextChecks = checked.filter { !checkUIDs.contains($0.key) }
        if nextChecks != checked {
            guard write(StateFile(schemaVersion: Self.stateSchemaVersion, doneUids: nextChecks), to: stateURL) else {
                notifyChanged()
                return false
            }
            checked = nextChecks
        }
        notifyChanged()
        return true
    }

    // MARK: 파일 쓰기 (원자적)

    struct CacheFile: Codable {
        var schemaVersion: Int
        var items: [LmsItem]
    }

    struct HistoryFile: Codable {
        var schemaVersion: Int
        var items: [LmsHistoryItem]
    }

    /// PRD §6 `LmsCheckState { doneUids }`. v1에 있던 `goneSince`는 읽기만 하고 버린다
    struct StateFile: Codable {
        var schemaVersion: Int
        var doneUids: [String: Date]
    }

    enum StoreError: Error { case unsupported }

    @discardableResult
    private func writeHistory() -> Bool {
        write(HistoryFile(schemaVersion: Self.schemaVersion, items: history), to: historyURL)
    }

    @discardableResult
    private func writeState() -> Bool {
        write(StateFile(schemaVersion: Self.stateSchemaVersion, doneUids: checked), to: stateURL)
    }

    private func updateSaveError() {
        saveError = failedWrites.isEmpty ? nil : "LMS 변경을 저장하지 못했어요. 앱을 종료하지 말고 저장을 다시 시도해 주세요."
    }

    private func write<T: Encodable>(_ value: T, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try TodoStore.makeEncoder().encode(value).write(to: url, options: .atomic)
            failedWrites.remove(url.lastPathComponent)
            updateSaveError()
            return true
        } catch {
            failedWrites.insert(url.lastPathComponent)
            updateSaveError()
            lmsStoreLogger.error("lms write failed \(url.lastPathComponent, privacy: .public): \(String(describing: type(of: error)), privacy: .public)")
            return false
        }
    }

    private func uniqueURL(prefix: String) -> URL {
        let dir = stateURL.deletingLastPathComponent()
        let stamp = Int(now().timeIntervalSince1970)
        var url = dir.appendingPathComponent("\(prefix)-\(stamp).json")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(prefix)-\(stamp)-\(n).json")
            n += 1
        }
        return url
    }

    private func backupCorrupt(_ url: URL, prefix: String) {
        try? FileManager.default.moveItem(at: url, to: uniqueURL(prefix: "\(prefix).corrupt"))
    }
}
