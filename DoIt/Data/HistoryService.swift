import Foundation
import Observation
import os

private let historyLogger = Logger(subsystem: "com.personal.doit", category: "history")

/// 기록 정리 (PRD F13, ARCHITECTURE §3.9). **자동으로 지우지 않는다** — 사용자 확인 후 `run`만 지운다.
/// 정리 필요 여부 계산은 앱 실행·날짜 변경·설정 창 열 때 (`recompute`, 타이머 없음)
@MainActor
@Observable
final class HistoryService {
    let todoStore: TodoStore
    let lmsStore: LmsStore
    @ObservationIgnored let archiveDirectory: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var now: () -> Date = { Date() }
    @ObservationIgnored var today: () -> LocalDate = { LocalDate.today() }
    /// 정리로 패널 내용이 바뀌었을 때 (높이 재계산)
    @ObservationIgnored var onDataChanged: () -> Void = {}

    static let retentionKey = "historyRetention"

    var retention: HistoryRetention {
        didSet {
            defaults.set(retention.rawValue, forKey: Self.retentionKey)
            recompute()
        }
    }
    /// 마지막으로 계산한 정리 대상
    private(set) var pending = HistoryCleanupPlan()

    init(todoStore: TodoStore, lmsStore: LmsStore,
         archiveDirectory: URL = TodoStore.defaultFileURL.deletingLastPathComponent().appendingPathComponent("archive", isDirectory: true),
         defaults: UserDefaults = .standard) {
        self.todoStore = todoStore
        self.lmsStore = lmsStore
        self.archiveDirectory = archiveDirectory
        self.defaults = defaults
        retention = defaults.string(forKey: Self.retentionKey).flatMap(HistoryRetention.init(rawValue:)) ?? .default
    }

    func recompute() {
        pending = HistoryPolicy.plan(today: today(), retention: retention, todos: todoStore.todos,
                                     history: lmsStore.history, checked: lmsStore.checked)
        historyLogger.info("cleanup candidates: \(self.pending.count, privacy: .public) (retention \(self.retention.rawValue, privacy: .public))")
    }

    var resetPlan: HistoryCleanupPlan {
        HistoryPolicy.resetPlan(todos: todoStore.todos, history: lmsStore.history, checked: lmsStore.checked)
    }

    enum CleanupError: Error {
        /// 백업 파일을 쓰지 못함 → 아무것도 지우지 않았다
        case backupFailed(String)
        /// 파일별로 일부 정리가 끝났을 수 있다. 남은 항목을 다시 확인한다.
        case saveFailed
    }

    struct CleanupResult: Equatable {
        let removedCount: Int
        /// 백업 파일 (백업하지 않았으면 nil)
        let backupURL: URL?
    }

    /// 정리 실행. `backup`이면 `archive/기록-YYYYMMDD.json`에 대상만 원자적으로 쓰고, **성공했을 때만** 지운다
    func run(_ plan: HistoryCleanupPlan, backup: Bool, kind: String = "cleanup") throws -> CleanupResult {
        var backupURL: URL?
        if backup {
            backupURL = try writeBackup(plan, kind: kind)
        }
        let ids = Set(plan.todos.map(\.id))
        let expected = todoStore.todos.filter { ids.contains($0.id) && $0.isDone }.count
        let removed = todoStore.removeCompleted(ids: ids)
        guard removed.count == expected else { recompute(); throw CleanupError.saveFailed }
        let historyUIDs = Set(plan.lmsHistory.map(\.uid))
        let expectedHistory = lmsStore.history.filter { historyUIDs.contains($0.uid) }.count
        guard lmsStore.removeHistory(uids: historyUIDs, checks: Set(plan.lmsChecks.keys)) else {
            recompute()
            onDataChanged()
            throw CleanupError.saveFailed
        }
        historyLogger.info("\(kind, privacy: .public) done: todos \(removed.count, privacy: .public), lms history \(plan.lmsHistory.count, privacy: .public), checks \(plan.lmsChecks.count, privacy: .public), backup \(backup, privacy: .public)")
        recompute()
        onDataChanged()
        return CleanupResult(removedCount: removed.count + expectedHistory, backupURL: backupURL)
    }

    /// 모든 기록 초기화: 항상 먼저 백업한다
    func resetAll() throws -> CleanupResult {
        try run(resetPlan, backup: true, kind: "reset")
    }

    private func writeBackup(_ plan: HistoryCleanupPlan, kind: String) throws -> URL {
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
            let existing = Set((try? fm.contentsOfDirectory(atPath: archiveDirectory.path)) ?? [])
            let url = archiveDirectory.appendingPathComponent(HistoryPolicy.archiveFileName(today: today(), existing: existing))
            let file = HistoryArchiveFile(kind: kind, createdAt: now(), todos: plan.todos,
                                          lmsHistory: plan.lmsHistory, lmsChecks: plan.lmsChecks)
            try TodoStore.makeEncoder().encode(file).write(to: url, options: .atomic)  // 이름은 위에서 겹치지 않게 골랐다
            historyLogger.info("backup written: \(url.lastPathComponent, privacy: .public)")
            return url
        } catch {
            historyLogger.error("backup failed, nothing removed: \(String(describing: type(of: error)), privacy: .public)")
            throw CleanupError.backupFailed(error.localizedDescription)
        }
    }
}
