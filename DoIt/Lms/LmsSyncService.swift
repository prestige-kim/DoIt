import AppKit
import os

private let syncLogger = Logger(subsystem: "com.personal.doit", category: "lms")

/// 피드 요청 1번에 필요한 것
struct FeedRequest {
    let url: URL
    let etag: String?
    let lastModified: String?
}

/// 네트워크 계층 (테스트에서는 가짜 응답을 넣는다 — 실제 네트워크 호출 없음)
protocol FeedFetching: AnyObject {
    func fetch(_ request: FeedRequest) async -> FeedFetchOutcome
}

/// LMS 캘린더 피드 동기화 (ARCHITECTURE §3.8, D-008)
/// - 트리거: 앱 실행 / 잠자기 해제 / 패널 펼침 (자동, 마지막 시도 후 6시간) · 메뉴 "지금 새로고침" (수동, 5분)
/// - 주기 타이머·자동 재시도 없음. 요청은 항상 1개씩 (진행 중이면 무시)
/// - 실패해도 캐시는 그대로. 피드 주소는 요청할 때만 저장소(파일, D-018)에서 읽고 들고 있지 않는다
@MainActor
final class LmsSyncService {
    enum Trigger: String {
        case launch, wake, panelExpand, enabled, newURL, manual

        /// 6시간 제한을 따르는지 (manual·newURL은 5분 제한)
        var isManual: Bool { self == .manual || self == .newURL }
    }

    let store: LmsStore
    private let feedURLStore: FeedURLStoring
    private let fetcher: FeedFetching
    /// 날짜·시각을 정할 시간대 (테스트에서 고정)
    var timeZone: () -> TimeZone = { .current }
    /// 오늘 날짜 (캐시 범위 계산용)
    var today: () -> LocalDate = { LocalDate.today() }
    private var wakeObserver: NSObjectProtocol?

    init(store: LmsStore, feedURLStore: FeedURLStoring, fetcher: FeedFetching) {
        self.store = store
        self.feedURLStore = feedURLStore
        self.fetcher = fetcher
    }

    // MARK: 트리거

    /// 잠자기에서 깨어날 때 (이벤트 방식)
    func startObservingWake() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.trigger(.wake) }
        }
    }

    /// 동기화 시도. 조건이 안 맞으면 아무것도 하지 않는다. 테스트에서 끝날 때까지 기다릴 수 있게 Task를 돌려준다
    @discardableResult
    func trigger(_ trigger: Trigger) -> Task<Void, Never>? {
        guard store.isEnabled, store.hasFeedURL else { return nil }
        guard !store.isSyncing else {
            syncLogger.debug("lms sync skipped (\(trigger.rawValue, privacy: .public)): in flight")
            return nil
        }
        let now = store.now()
        switch LmsSyncPolicy.decide(manual: trigger.isManual, now: now, record: store.record) {
        case .proceed:
            break
        case .skipTooSoon(let at):
            syncLogger.debug("lms sync skipped (\(trigger.rawValue, privacy: .public)): too soon, \(Int(at.timeIntervalSince(now)), privacy: .public)s left")
            return nil
        case .skipRateLimited(let until):
            syncLogger.info("lms sync skipped (\(trigger.rawValue, privacy: .public)): rate limited, \(Int(until.timeIntervalSince(now)), privacy: .public)s left")
            return nil
        }

        let url: URL
        do {
            guard let u = try feedURLStore.load() else {
                syncLogger.error("lms sync: no stored feed URL")
                return nil
            }
            url = u
        } catch {
            return nil  // 저장소 오류는 저장소가 상태 코드만 기록
        }

        store.isSyncing = true
        store.setRecord(LmsSyncPolicy.recordingAttempt(store.record, now: now))  // 실패해도 시도로 계산
        // 기록(T-009)을 처음 채울 때는 전체를 받도록 조건부 헤더를 빼고 보낸다 (요청 방식은 그대로 GET 1개)
        let conditional = store.isHistorySeeded
        let request = FeedRequest(url: url, etag: conditional ? store.record.etag : nil,
                                  lastModified: conditional ? store.record.lastModified : nil)
        let host = url.host ?? "?"
        syncLogger.info("lms sync start (\(trigger.rawValue, privacy: .public)) host=\(host, privacy: .public) conditional=\(request.etag != nil || request.lastModified != nil, privacy: .public)")
        scheduleManualReenableRefresh()

        return Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.fetcher.fetch(request)
            await self.finish(outcome)
        }
    }

    private func finish(_ outcome: FeedFetchOutcome) async {
        let now = store.now()
        let evaluation = LmsSyncPolicy.evaluate(outcome, now: now)
        var parseSucceeded = false
        switch evaluation {
        case .fresh(let body, _, _):
            let zone = timeZone()
            // 파싱은 메인 스레드 밖에서 (응답은 최대 5MB)
            let parsed = await Task.detached { try? IcsParser.parse(data: body, timeZone: zone) }.value
            if let parsed {
                parseSucceeded = true
                store.replaceItems(with: parsed.items, today: today())
                store.markHistorySeeded()
                syncLogger.info("lms sync ok: \(parsed.items.count, privacy: .public) assignments, non-assignment \(parsed.skippedNonAssignment, privacy: .public), broken \(parsed.skippedBroken, privacy: .public)")
            } else {
                syncLogger.error("lms sync: parse failed (not a calendar)")
            }
        case .notModified:
            syncLogger.info("lms sync: not modified (304)")
        case .failed(let status):
            syncLogger.error("lms sync failed: \(status.rawValue, privacy: .public) \(Self.describe(outcome), privacy: .public)")
        case .rateLimited(let retryAfter):
            syncLogger.error("lms sync: 429 retryAfter=\(retryAfter.map { Int($0) } ?? -1, privacy: .public)")
        }
        store.setRecord(LmsSyncPolicy.recording(evaluation, parseSucceeded: parseSucceeded, into: store.record, now: now))
        store.isSyncing = false
    }

    private static func describe(_ outcome: FeedFetchOutcome) -> String {
        switch outcome {
        case .response(let status, _, _): return "http \(status)"
        case .networkError: return "network"
        case .redirectRejected: return "redirect rejected"
        case .tooLarge: return "too large"
        case .notHTTPS: return "not https"
        }
    }

    /// 수동 새로고침이 다시 가능해지는 순간 화면(설정 창 버튼)을 1번 갱신한다 (일회성 지연, ARCHITECTURE §5 예외)
    private func scheduleManualReenableRefresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + LmsSyncPolicy.manualInterval + 1) { [weak self] in
            self?.store.refreshDisplayNow()
        }
    }

    // MARK: 수동 새로고침 가능 여부 (메뉴·설정 창)

    struct ManualAvailability: Equatable {
        let enabled: Bool
        /// 비활성 이유 (예: `3분 뒤 가능`)
        let note: String?
    }

    func manualAvailability(now: Date) -> ManualAvailability {
        Self.manualAvailability(isEnabled: store.isEnabled, hasFeedURL: store.hasFeedURL,
                                isSyncing: store.isSyncing, record: store.record, now: now)
    }

    nonisolated static func manualAvailability(isEnabled: Bool, hasFeedURL: Bool, isSyncing: Bool,
                                               record: LmsSyncRecord, now: Date) -> ManualAvailability {
        guard isEnabled else { return ManualAvailability(enabled: false, note: "연동 꺼짐") }
        guard hasFeedURL else { return ManualAvailability(enabled: false, note: "피드 주소 없음") }
        guard !isSyncing else { return ManualAvailability(enabled: false, note: "동기화 중") }
        switch LmsSyncPolicy.decide(manual: true, now: now, record: record) {
        case .proceed:
            return ManualAvailability(enabled: true, note: nil)
        case .skipTooSoon(let at):
            let minutes = max(1, Int((at.timeIntervalSince(now) / 60).rounded(.up)))
            return ManualAvailability(enabled: false, note: "\(minutes)분 뒤 가능")
        case .skipRateLimited(let until):
            return ManualAvailability(enabled: false, note: "\(LmsDisplay.hoursLeft(until, now: now))시간 뒤 가능")
        }
    }

    // MARK: 주소 저장·연결 해제 (설정 창)

    /// 주소를 검증하고 저장소(파일)에 저장한다. 실패하면 저장하지 않고 이유를 돌려준다.
    /// 저장에 성공하면 이전 주소의 기록을 지우고(429 멈춤은 유지) 바로 1번 동기화를 시도한다.
    @discardableResult
    func saveFeedURL(_ text: String) -> FeedURLError? {
        switch FeedURLValidator.validate(text) {
        case .failure(let error):
            syncLogger.info("feed URL rejected: \(String(describing: error), privacy: .public)")
            return error
        case .success(let url):
            do {
                try feedURLStore.save(url)
            } catch let error as FeedURLError {
                return error
            } catch {
                return .storageFailed(-1)
            }
            store.feedURLSaved(masked: FeedURLValidator.masked(url))
            trigger(.newURL)
            return nil
        }
    }

    /// 연결 해제: 피드 주소 삭제(파일 + 남은 키체인 항목) + `lms.json` 삭제 (체크 상태는 유지)
    func disconnect() {
        feedURLStore.delete()
        store.disconnect()
    }
}

