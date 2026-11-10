import Foundation

/// 기록 보관 기간 (PRD F13 설정)
enum HistoryRetention: String, CaseIterable, Identifiable {
    case sixMonths, oneYear, twoYears, never

    static let `default`: HistoryRetention = .oneYear
    var id: String { rawValue }

    var months: Int? {
        switch self {
        case .sixMonths: return 6
        case .oneYear: return 12
        case .twoYears: return 24
        case .never: return nil
        }
    }

    var label: String {
        switch self {
        case .sixMonths: return "6개월"
        case .oneYear: return "1년"
        case .twoYears: return "2년"
        case .never: return "정리 안 함"
        }
    }
}

/// 정리할 것 목록 (지우기 전에 사용자에게 보여 주고, 백업에 쓴다)
struct HistoryCleanupPlan: Equatable {
    var todos: [Todo] = []
    var lmsHistory: [LmsHistoryItem] = []
    /// 함께 지울 체크 상태 (UID → 체크 시각)
    var lmsChecks: [String: Date] = [:]

    /// 화면에 보이는 개수 = 내 할 일 + LMS 기록 (체크 상태는 따로 세지 않음)
    var count: Int { todos.count + lmsHistory.count }
    var isEmpty: Bool { todos.isEmpty && lmsHistory.isEmpty && lmsChecks.isEmpty }
}

/// 백업 파일(`archive/기록-YYYYMMDD.json`) 형식
struct HistoryArchiveFile: Codable, Equatable {
    var schemaVersion = 1
    /// `cleanup`(보관 기간 정리) / `reset`(모든 기록 초기화)
    var kind: String
    var createdAt: Date
    var todos: [Todo]
    var lmsHistory: [LmsHistoryItem]
    var lmsChecks: [String: Date]
}

/// 정리 대상 계산 (순수 함수, ARCHITECTURE §3.9). **완료 안 한 내 할 일은 절대 대상이 아니다**
enum HistoryPolicy {
    /// 이 날짜보다 이전이면 보관 기간이 지난 것. "정리 안 함"이면 nil
    static func cutoff(today: LocalDate, retention: HistoryRetention) -> LocalDate? {
        guard let months = retention.months, let noon = today.noonDate,
              let d = LocalDate.calendar.date(byAdding: .month, value: -months, to: noon) else { return nil }
        return LocalDate(d)
    }

    /// 보관 기간이 지난 것: 완료한 내 할 일(`doneAt` 날짜 기준) + LMS 기록(마감일 기준) + 그 체크 상태
    /// `doneAt`이 없는 완료 항목(손으로 고친 파일)은 기준 날짜를 알 수 없어 대상에서 뺀다
    static func plan(today: LocalDate, retention: HistoryRetention, todos: [Todo],
                     history: [LmsHistoryItem], checked: [String: Date]) -> HistoryCleanupPlan {
        guard let cutoff = cutoff(today: today, retention: retention) else { return HistoryCleanupPlan() }
        let oldTodos = todos.filter { t in
            guard t.isDone, let doneAt = t.doneAt else { return false }
            return LocalDate(doneAt) < cutoff
        }
        let oldHistory = history.filter { $0.dueDate < cutoff }
        let uids = Set(oldHistory.map(\.uid))
        return HistoryCleanupPlan(todos: oldTodos, lmsHistory: oldHistory, lmsChecks: checked.filter { uids.contains($0.key) })
    }

    /// 모든 기록 초기화: 완료한 내 할 일 전부 + LMS 기록 전부 + 체크 상태 전부.
    /// 완료 안 한 할 일·설정·피드 연결·현재 LMS 과제(`lms.json`)는 그대로
    static func resetPlan(todos: [Todo], history: [LmsHistoryItem], checked: [String: Date]) -> HistoryCleanupPlan {
        HistoryCleanupPlan(todos: todos.filter(\.isDone), lmsHistory: history, lmsChecks: checked)
    }

    /// 예상 크기 = 백업 파일로 썼을 때의 바이트 수
    static func estimatedBytes(_ plan: HistoryCleanupPlan, now: Date) -> Int {
        let file = HistoryArchiveFile(kind: "cleanup", createdAt: now, todos: plan.todos,
                                      lmsHistory: plan.lmsHistory, lmsChecks: plan.lmsChecks)
        return (try? TodoStore.makeEncoder().encode(file).count) ?? 0
    }

    /// 백업 파일 이름: `기록-YYYYMMDD.json`, 같은 날 또 만들면 `기록-YYYYMMDD-2.json` …
    static func archiveFileName(today: LocalDate, existing: Set<String>) -> String {
        let base = String(format: "기록-%04d%02d%02d", today.year, today.month, today.day)
        if !existing.contains("\(base).json") { return "\(base).json" }
        var n = 2
        while existing.contains("\(base)-\(n).json") { n += 1 }
        return "\(base)-\(n).json"
    }
}
