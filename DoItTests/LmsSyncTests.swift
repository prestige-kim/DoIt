import XCTest
@testable import DoIt

/// 가짜 네트워크: 실제로 접속하지 않고 미리 정한 응답을 돌려준다
final class FakeFetcher: FeedFetching {
    var outcomes: [FeedFetchOutcome] {
        get { lock.withLock { _outcomes } }
        set { lock.withLock { _outcomes = newValue } }
    }
    var requests: [FeedRequest] { lock.withLock { _requests } }
    /// true면 `release()`를 부를 때까지 응답을 미룬다 (진행 중 무시 테스트)
    var hold: Bool {
        get { lock.withLock { _hold } }
        set { lock.withLock { _hold = newValue } }
    }

    // fetch는 백그라운드에서, 테스트는 메인에서 읽고 쓴다 → 잠금으로 보호 (T-008)
    private let lock = NSLock()
    private var _outcomes: [FeedFetchOutcome] = []
    private var _requests: [FeedRequest] = []
    private var _hold = false
    private var held: CheckedContinuation<Void, Never>?
    /// 응답 대기가 등록되기 전에 `release()`가 먼저 불린 경우 (예전에는 이 풀어 주기가 사라져 테스트가 가끔 실패했다)
    private var releasedEarly = false

    func fetch(_ request: FeedRequest) async -> FeedFetchOutcome {
        let mustHold = lock.withLock { () -> Bool in
            _requests.append(request)
            return _hold
        }
        if mustHold {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock { () -> Bool in
                    if releasedEarly { releasedEarly = false; return true }
                    held = c
                    return false
                }
                if resumeNow { c.resume() }
            }
        }
        return lock.withLock { _outcomes.isEmpty ? .networkError : _outcomes.removeFirst() }
    }

    func release() {
        let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            let c = held
            held = nil
            if c == nil { releasedEarly = true }
            return c
        }
        c?.resume()
    }
}

/// 가짜 피드 주소 저장소 (실제 파일·키체인을 건드리지 않는다)
final class FakeFeedURLStore: FeedURLStoring {
    var stored: URL?
    var saveCount = 0
    func save(_ url: URL) throws { stored = url; saveCount += 1 }
    func load() throws -> URL? { stored }
    @discardableResult func delete() -> Bool { stored = nil; return true }
}

/// T-007: LmsStore 파일 저장·체크 정리, LmsSyncService 흐름 (가짜 응답만)
@MainActor
final class LmsSyncTests: XCTestCase {
    private var dir: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private let seoul = TimeZone(identifier: "Asia/Seoul")!
    private let today = LocalDate(year: 2026, month: 10, day: 9)
    private let fakeFeed = "https://lms.example.invalid/feeds/calendars/user_FAKE.ics"

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("DoItLmsTests-\(UUID().uuidString)")
        suiteName = "DoItLmsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeStore() -> LmsStore {
        let store = LmsStore(directory: dir, defaults: defaults)
        store.now = { [unowned self] in self.clock }
        return store
    }

    private func makeService(_ store: LmsStore, _ fetcher: FakeFetcher, _ feedURLStore: FakeFeedURLStore = FakeFeedURLStore()) -> LmsSyncService {
        let s = LmsSyncService(store: store, feedURLStore: feedURLStore, fetcher: fetcher)
        s.timeZone = { [seoul] in seoul }
        s.today = { [today] in today }
        return s
    }

    private func fixtureBody() throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "fake-feed", withExtension: "ics")))
    }

    private func ok(_ body: Data, etag: String? = "\"v1\"") -> FeedFetchOutcome {
        .response(status: 200, headers: etag.map { ["etag": $0] } ?? [:], body: body)
    }

    /// 켜고 주소를 저장하면 바로 1번 동기화 (newURL)
    private func connect(_ service: LmsSyncService, _ fetcher: FakeFetcher, first: FeedFetchOutcome) async {
        service.store.isEnabled = true
        fetcher.outcomes = [first]
        XCTAssertNil(service.saveFeedURL(fakeFeed))
        // saveFeedURL이 시작한 Task가 끝날 때까지 기다림
        await waitUntil("동기화 끝남") { !service.store.isSyncing }
    }

    // MARK: 서비스

    func testDisabledOrNoURLDoesNotTouchNetwork() async {
        let fetcher = FakeFetcher()
        let feedStore = FakeFeedURLStore()
        let service = makeService(makeStore(), fetcher, feedStore)
        XCTAssertNil(service.trigger(.launch), "기본 끔")
        service.store.isEnabled = true
        XCTAssertNil(service.trigger(.launch), "주소 없음")
        XCTAssertEqual(fetcher.requests.count, 0)
    }

    func testInvalidURLIsNotSaved() {
        let feedStore = FakeFeedURLStore()
        let service = makeService(makeStore(), FakeFetcher(), feedStore)
        XCTAssertEqual(service.saveFeedURL("https://lms.example.invalid/courses/1"), .notFeed)
        XCTAssertEqual(feedStore.saveCount, 0)
        XCTAssertNil(service.store.maskedFeedURL)
    }

    func testFirstSyncFillsCacheAndSecondAutomaticIsSkipped() async throws {
        let fetcher = FakeFetcher()
        let feedStore = FakeFeedURLStore()
        let store = makeStore()
        let service = makeService(store, fetcher, feedStore)
        await connect(service, fetcher, first: ok(try fixtureBody()))

        XCTAssertEqual(feedStore.stored?.absoluteString, fakeFeed)
        XCTAssertEqual(store.maskedFeedURL, "https://lms.example.invalid/…/••••.ics")
        XCTAssertEqual(store.record.status, .ok)
        XCTAssertEqual(store.record.etag, "\"v1\"")
        XCTAssertEqual(store.items.count, 5)
        XCTAssertFalse(store.isSyncing)

        clock += 3600
        XCTAssertNil(service.trigger(.panelExpand), "6시간 안에는 자동 건너뜀")
        XCTAssertTrue(service.manualAvailability(now: clock).enabled, "수동은 5분이 지났으니 가능")
        XCTAssertEqual(fetcher.requests.count, 1)
    }

    func testManualAfterFiveMinutesSendsConditionalHeadersAnd304KeepsCache() async throws {
        let fetcher = FakeFetcher()
        let store = makeStore()
        let service = makeService(store, fetcher)
        await connect(service, fetcher, first: ok(try fixtureBody()))
        let before = store.items

        XCTAssertNil(fetcher.requests.first?.etag, "기록을 처음 채울 때는 조건부 헤더 없이 (T-009)")
        clock += 299
        XCTAssertNil(service.trigger(.manual), "5분 안")
        clock += 1
        fetcher.outcomes = [.response(status: 304, headers: [:], body: Data())]
        await service.trigger(.manual)?.value
        XCTAssertEqual(fetcher.requests.last?.etag, "\"v1\"", "기록을 채운 뒤에는 If-None-Match")
        XCTAssertEqual(store.items, before)
        XCTAssertEqual(store.record.status, .ok)
        XCTAssertEqual(store.record.lastSuccessAt, clock)
    }

    func testFailuresKeepCacheAndSetStatus() async throws {
        let fetcher = FakeFetcher()
        let store = makeStore()
        let service = makeService(store, fetcher)
        await connect(service, fetcher, first: ok(try fixtureBody()))
        let before = store.items

        let cases: [(FeedFetchOutcome, LmsSyncStatus)] = [
            (.response(status: 404, headers: [:], body: Data()), .disconnected),
            (.networkError, .offline),
            (.response(status: 503, headers: [:], body: Data()), .offline),
            (.response(status: 200, headers: [:], body: Data("<html>로그인</html>".utf8)), .invalidFeed),
            (.redirectRejected, .invalidFeed),
            (.tooLarge, .invalidFeed),
        ]
        for (outcome, status) in cases {
            clock += 301
            fetcher.outcomes = [outcome]
            await service.trigger(.manual)?.value
            XCTAssertEqual(store.record.status, status)
            XCTAssertEqual(store.items, before, "실패해도 기존 캐시 유지 (\(status))")
        }
        XCTAssertEqual(fetcher.requests.count, 1 + cases.count)
    }

    func test429BlocksManualAndAutomatic() async throws {
        let fetcher = FakeFetcher()
        let store = makeStore()
        let service = makeService(store, fetcher)
        await connect(service, fetcher, first: .response(status: 429, headers: [:], body: Data()))
        XCTAssertEqual(store.record.status, .rateLimited)
        XCTAssertEqual(store.record.rateLimitedUntil, clock + 24 * 3600)

        clock += 7 * 3600
        XCTAssertNil(service.trigger(.manual))
        XCTAssertNil(service.trigger(.wake))
        XCTAssertFalse(service.manualAvailability(now: clock).enabled)
        store.refreshDisplayNow()  // 패널을 펼칠 때처럼
        XCTAssertEqual(store.panelMessage, "LMS가 잠시 쉬어 달래요 · 17시간 뒤 다시 시도")
        XCTAssertEqual(fetcher.requests.count, 1)

        clock += 17 * 3600
        fetcher.outcomes = [.response(status: 429, headers: ["retry-after": "3600"], body: Data())]
        await service.trigger(.launch)?.value
        XCTAssertEqual(store.record.consecutiveRateLimits, 2)
        XCTAssertEqual(store.record.rateLimitedUntil, clock + 7200, "Retry-After 1시간 × 2 (연속)")
    }

    func testInFlightRequestIgnoresNewTriggers() async throws {
        let fetcher = FakeFetcher()
        fetcher.hold = true
        let store = makeStore()
        store.isEnabled = true
        let service = makeService(store, fetcher)
        fetcher.outcomes = [ok(try fixtureBody())]
        XCTAssertNil(service.saveFeedURL(fakeFeed))
        XCTAssertTrue(store.isSyncing)
        await waitUntil("요청이 가짜 네트워크에 도착") { !fetcher.requests.isEmpty }
        clock += 7 * 3600
        XCTAssertNil(service.trigger(.manual), "진행 중이면 무시 (요청은 1개씩)")
        XCTAssertFalse(service.manualAvailability(now: clock).enabled)
        fetcher.release()
        await waitUntil("풀어 준 뒤 동기화 끝남") { !store.isSyncing }
        XCTAssertEqual(fetcher.requests.count, 1)
        XCTAssertEqual(store.record.status, .ok)
    }

    func testDisconnectRemovesFeedURLAndCacheButKeepsChecks() async throws {
        let fetcher = FakeFetcher()
        let feedStore = FakeFeedURLStore()
        let store = makeStore()
        let service = makeService(store, fetcher, feedStore)
        await connect(service, fetcher, first: ok(try fixtureBody()))
        store.toggleCheck(uid: "event-assignment-1001")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.cacheURL.path))

        service.disconnect()
        XCTAssertNil(feedStore.stored)
        XCTAssertNil(store.maskedFeedURL)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.cacheURL.path))
        XCTAssertTrue(store.isChecked("event-assignment-1001"), "체크 상태는 유지")
        XCTAssertFalse(store.isSectionShown(today: today), "LMS 칸 사라짐")
    }

    // MARK: 저장소

    func testCacheFileContainsOnlyAllowedFields() async throws {
        let fetcher = FakeFetcher()
        let store = makeStore()
        let service = makeService(store, fetcher)
        await connect(service, fetcher, first: ok(try fixtureBody()))
        let text = try String(contentsOf: store.cacheURL, encoding: .utf8)
        for marker in IcsParserTests.forbiddenMarkers + ["user_FAKE", "feeds/calendars"] {
            XCTAssertFalse(text.contains(marker), "lms.json에 \(marker)가 있으면 안 됨")
        }
        let keys = try JSONSerialization.jsonObject(with: Data(contentsOf: store.cacheURL)) as? [String: Any]
        let item = try XCTUnwrap((keys?["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(item.keys).subtracting(["courseName", "dueTime"]), ["uid", "title", "dueDate"])
        // 설정·기록(UserDefaults)에도 주소 원문은 없다
        for key in [LmsStore.Keys.masked, LmsStore.Keys.record] {
            let value = defaults.object(forKey: key).map { String(describing: $0) } ?? ""
            let decoded = (defaults.data(forKey: key)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            XCTAssertFalse(value.contains("user_FAKE") || decoded.contains("user_FAKE"), key)
        }
    }

    func testReloadKeepsItemsChecksAndSettings() throws {
        let store = makeStore()
        store.isEnabled = true
        store.weeks = 3
        store.isSectionCollapsed = true
        store.replaceItems(with: [LmsItem(uid: "event-assignment-1", title: "가짜", courseName: "가짜과목",
                                          dueDate: today, dueTime: LocalTime(hour: 23, minute: 59))], today: today)
        store.toggleCheck(uid: "event-assignment-1")

        let reloaded = makeStore()
        reloaded.load(today: today)  // 테스트 날짜 기준 (실제 오늘이면 지난 과제로 기록에 옮겨짐)
        XCTAssertEqual(reloaded.items, store.items)
        XCTAssertTrue(reloaded.isChecked("event-assignment-1"))
        XCTAssertTrue(reloaded.isEnabled)
        XCTAssertEqual(reloaded.weeks, 3)
        XCTAssertTrue(reloaded.isSectionCollapsed, "칸 접힘 기억")
    }

    func testWeeksClamped() {
        let store = makeStore()
        XCTAssertEqual(store.weeks, 2, "기본 2주")
        store.weeks = 20
        XCTAssertEqual(store.weeks, 8)
        store.weeks = 0
        XCTAssertEqual(store.weeks, 1)
        XCTAssertEqual(makeStore().weeks, 1, "저장된 값도 범위 안")
    }

    func testCacheKeepsTodayToEightWeeksAndPastGoesToHistory() {
        // T-009: lms.json은 오늘 ~ 8주, 마감이 지난 과제는 lms-history.json
        let store = makeStore()
        let items = [-2, -1, 0, 56, 57].map { LmsItem(uid: "event-assignment-\($0)", title: "t", courseName: nil,
                                                       dueDate: today.adding(days: $0), dueTime: nil) }
        store.replaceItems(with: items, today: today)
        XCTAssertEqual(store.items.map(\.uid), ["event-assignment-0", "event-assignment-56"])
        XCTAssertEqual(store.history.map(\.uid), ["event-assignment--2", "event-assignment--1"])
    }

    func testSectionShownRules() {
        let store = makeStore()
        let a = LmsItem(uid: "event-assignment-a", title: "a", courseName: nil, dueDate: today, dueTime: nil)
        store.replaceItems(with: [a], today: today)
        XCTAssertFalse(store.isSectionShown(today: today), "연동 꺼짐")
        store.isEnabled = true
        XCTAssertFalse(store.isSectionShown(today: today), "주소 없음")
        store.feedURLSaved(masked: "https://lms.example.invalid/…/••••.ics")
        XCTAssertTrue(store.isSectionShown(today: today))
        store.replaceItems(with: [], today: today)
        XCTAssertFalse(store.isSectionShown(today: today), "보일 항목 없음")
        var r = store.record
        r.status = .disconnected
        store.setRecord(r)
        XCTAssertTrue(store.isSectionShown(today: today), "오류 문구가 있으면 보임")
    }

    func testCorruptStateFileIsBackedUpNotDeleted() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = makeStore()
        try Data("{망가짐".utf8).write(to: store.stateURL)
        store.load()
        XCTAssertTrue(store.checked.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("lms-state.corrupt-") }, "\(files)")
    }
}

extension LmsSyncTests {
    /// T-009: 업그레이드 직후 304만 오면 지난 과제를 채울 수 없으므로, 처음 1번은 조건부 헤더 없이 보낸다
    func testFirstRequestAfterUpgradeIsUnconditional() async throws {
        let fetcher = FakeFetcher()
        let store = makeStore()
        var r = LmsSyncRecord()
        r.etag = "\"old\""  // T-007 때 받은 ETag가 남아 있는 상태
        store.setRecord(r)
        store.isEnabled = true
        store.feedURLSaved(masked: "https://lms.example.invalid/…/••••.ics")
        var rr = store.record
        rr.etag = "\"old\""
        store.setRecord(rr)
        let feedStore = FakeFeedURLStore()
        feedStore.stored = URL(string: "https://lms.example.invalid/feeds/calendars/user_FAKE.ics")
        let service = makeService(store, fetcher, feedStore)

        fetcher.outcomes = [.response(status: 304, headers: [:], body: Data())]
        await service.trigger(.launch)?.value
        XCTAssertNil(fetcher.requests.last?.etag, "아직 기록을 못 채웠으면 조건부 헤더 없음")
        XCTAssertFalse(store.isHistorySeeded, "304로는 채운 것이 아님")

        clock += 6 * 3600
        fetcher.outcomes = [ok(try fixtureBody(), etag: "\"new\"")]
        await service.trigger(.launch)?.value
        XCTAssertNil(fetcher.requests.last?.etag)
        XCTAssertTrue(store.isHistorySeeded)

        clock += 6 * 3600
        fetcher.outcomes = [.response(status: 304, headers: [:], body: Data())]
        await service.trigger(.launch)?.value
        XCTAssertEqual(fetcher.requests.last?.etag, "\"new\"", "채운 뒤에는 다시 조건부")
    }
}
