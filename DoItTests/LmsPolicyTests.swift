import XCTest
@testable import DoIt

/// T-007: 주소 검증, 동기화 간격, 오류 상태 매핑, 429 처리, 표시 범위·숨김, 과목명 줄이기, 패널 높이
final class LmsPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let today = LocalDate(year: 2026, month: 11, day: 7)

    // MARK: 주소 검증 (가짜 주소만, `.invalid`는 실제로 없는 도메인)

    func testFeedURLAccepted() {
        for ok in ["https://lms.example.invalid/feeds/calendars/user_FAKE123.ics",
                   "  https://lms.example.invalid/feeds/calendars/user_FAKE123.ics\n",
                   "HTTPS://LMS.example.invalid/feeds/calendars/user_FAKE.ICS"] {
            guard case .success = FeedURLValidator.validate(ok) else { return XCTFail("통과해야 함: \(ok)") }
        }
    }

    func testFeedURLRejected() {
        let cases: [(String, FeedURLError)] = [
            ("", .empty),
            ("   ", .empty),
            ("http://lms.example.invalid/feeds/calendars/user_FAKE.ics", .notHTTPS),
            ("webcal://lms.example.invalid/feeds/calendars/user_FAKE.ics", .notHTTPS),
            ("https://lms.example.invalid/courses/123", .notFeed),                       // 일반 LMS 페이지
            ("https://lms.example.invalid/calendar", .notFeed),
            ("https://lms.example.invalid/feeds/calendars/user_FAKE", .notFeed),         // .ics 없음
            ("https://lms.example.invalid/feeds/calendars/user_FAKE.ics?x=1", .notFeed), // 쿼리
            ("https://lms.example.invalid/feeds/calendars/user_FAKE.ics#a", .notFeed),
            ("https://lms.example.invalid/feeds/calendars/.ics", .notFeed),
            ("https://lms.example.invalid/api/v1/feeds/calendar.ics", .notFeed),
            ("https://me:pw@lms.example.invalid/feeds/calendars/user_FAKE.ics", .notURL),
            ("https:///feeds/calendars/user_FAKE.ics", .notURL),
            ("https://lms.example.invalid/feeds/calendars/user FAKE.ics", .notURL),
            ("그냥 글자", .notURL),
        ]
        for (text, expected) in cases {
            guard case .failure(let e) = FeedURLValidator.validate(text) else { XCTFail("거부해야 함: \(text)"); continue }
            XCTAssertEqual(e, expected, text)
        }
    }

    func testMaskedShowsOnlyHost() throws {
        let url = try FeedURLValidator.validate("https://lms.example.invalid/feeds/calendars/user_FAKESECRET.ics").get()
        let masked = FeedURLValidator.masked(url)
        XCTAssertEqual(masked, "https://lms.example.invalid/…/••••.ics")
        XCTAssertFalse(masked.contains("FAKESECRET"))
    }

    func testRedirectOnlyToSameHostFeed() throws {
        let original = try FeedURLValidator.validate("https://lms.example.invalid/feeds/calendars/user_A.ics").get()
        XCTAssertTrue(FeedURLValidator.isAllowedRedirect(from: original, to: URL(string: "https://LMS.example.invalid/feeds/calendars/user_B.ics")!))
        XCTAssertFalse(FeedURLValidator.isAllowedRedirect(from: original, to: URL(string: "https://other.example.invalid/feeds/calendars/user_A.ics")!))
        XCTAssertFalse(FeedURLValidator.isAllowedRedirect(from: original, to: URL(string: "https://lms.example.invalid/login")!), "같은 호스트라도 다른 페이지는 거부")
        XCTAssertFalse(FeedURLValidator.isAllowedRedirect(from: original, to: URL(string: "http://lms.example.invalid/feeds/calendars/user_A.ics")!))
    }

    // MARK: 요청은 읽기 전용 (LMS에 아무것도 보내지 않음)

    func testRequestIsReadOnlyGET() throws {
        let url = try FeedURLValidator.validate("https://lms.example.invalid/feeds/calendars/user_FAKE.ics").get()
        for (etag, lm) in [(nil, nil), ("\"v1\"", "Sat, 07 Nov 2026 00:00:00 GMT")] as [(String?, String?)] {
            let r = URLSessionFeedFetcher.makeURLRequest(FeedRequest(url: url, etag: etag, lastModified: lm))
            XCTAssertEqual(r.httpMethod, "GET")
            XCTAssertNil(r.httpBody, "본문 없음")
            XCTAssertNil(r.httpBodyStream)
            XCTAssertFalse(r.httpShouldHandleCookies, "쿠키 안 보냄")
            XCTAssertEqual(r.url, url, "피드 주소 그대로")
            let headers = Set((r.allHTTPHeaderFields ?? [:]).keys)
            XCTAssertTrue(headers.isSubset(of: ["Accept", "If-None-Match", "If-Modified-Since"]), "\(headers)")
        }
        XCTAssertEqual(URLSessionFeedFetcher.userAgent.hasPrefix("DoIt/"), true)
        XCTAssertTrue(URLSessionFeedFetcher.userAgent.hasSuffix("(personal calendar subscription)"))
    }

    // MARK: 동기화 간격

    func testAutomaticSixHoursManualFiveMinutes() {
        var r = LmsSyncRecord()
        XCTAssertEqual(LmsSyncPolicy.decide(manual: false, now: t0, record: r), .proceed, "처음은 바로")
        r = LmsSyncPolicy.recordingAttempt(r, now: t0)
        XCTAssertEqual(LmsSyncPolicy.decide(manual: false, now: t0 + 6 * 3600 - 1, record: r),
                       .skipTooSoon(availableAt: t0 + 6 * 3600))
        XCTAssertEqual(LmsSyncPolicy.decide(manual: false, now: t0 + 6 * 3600, record: r), .proceed)
        XCTAssertEqual(LmsSyncPolicy.decide(manual: true, now: t0 + 299, record: r), .skipTooSoon(availableAt: t0 + 300))
        XCTAssertEqual(LmsSyncPolicy.decide(manual: true, now: t0 + 300, record: r), .proceed, "수동은 6시간 무시, 5분")
    }

    func testFailureCountsAsAttempt() {
        var r = LmsSyncPolicy.recordingAttempt(LmsSyncRecord(), now: t0)
        r = LmsSyncPolicy.recording(.failed(.offline), parseSucceeded: false, into: r, now: t0 + 5)
        XCTAssertEqual(r.lastAttemptAt, t0)
        XCTAssertNil(r.lastSuccessAt)
        XCTAssertEqual(LmsSyncPolicy.decide(manual: false, now: t0 + 3600, record: r), .skipTooSoon(availableAt: t0 + 6 * 3600),
                       "실패해도 6시간 안에는 자동 재시도 없음")
        XCTAssertEqual(LmsSyncPolicy.decide(manual: true, now: t0 + 60, record: r), .skipTooSoon(availableAt: t0 + 300))
    }

    func testClockMovedBackDoesNotBlockForever() {
        let r = LmsSyncPolicy.recordingAttempt(LmsSyncRecord(), now: t0 + 86400 * 30)  // 미래로 기록됨
        XCTAssertEqual(LmsSyncPolicy.decide(manual: false, now: t0, record: r), .proceed)
    }

    // MARK: 오류 상태 매핑

    private func response(_ status: Int, _ headers: [String: String] = [:], _ body: String = "") -> FeedFetchOutcome {
        .response(status: status, headers: headers, body: Data(body.utf8))
    }

    func testStatusMapping() {
        XCTAssertEqual(LmsSyncPolicy.evaluate(response(200, ["etag": "\"e1\"", "last-modified": "LM"], "x"), now: t0),
                       .fresh(body: Data("x".utf8), etag: "\"e1\"", lastModified: "LM"))
        XCTAssertEqual(LmsSyncPolicy.evaluate(response(304), now: t0), .notModified)
        for s in [401, 403, 404, 410] { XCTAssertEqual(LmsSyncPolicy.evaluate(response(s), now: t0), .failed(.disconnected), "\(s)") }
        for s in [500, 502, 503] { XCTAssertEqual(LmsSyncPolicy.evaluate(response(s), now: t0), .failed(.offline), "\(s)") }
        for s in [301, 400, 418] { XCTAssertEqual(LmsSyncPolicy.evaluate(response(s), now: t0), .failed(.invalidFeed), "\(s)") }
        XCTAssertEqual(LmsSyncPolicy.evaluate(.networkError, now: t0), .failed(.offline))
        XCTAssertEqual(LmsSyncPolicy.evaluate(.redirectRejected, now: t0), .failed(.invalidFeed))
        XCTAssertEqual(LmsSyncPolicy.evaluate(.tooLarge, now: t0), .failed(.invalidFeed))
        XCTAssertEqual(LmsSyncPolicy.evaluate(response(429), now: t0), .rateLimited(retryAfter: nil))
        XCTAssertEqual(LmsSyncPolicy.evaluate(response(429, ["retry-after": "120"]), now: t0), .rateLimited(retryAfter: 120))
    }

    func testParseFailureKeepsOldSuccessInfo() {
        var r = LmsSyncRecord()
        r.lastSuccessAt = t0
        r.etag = "old"
        r = LmsSyncPolicy.recording(.fresh(body: Data(), etag: "new", lastModified: nil), parseSucceeded: false, into: r, now: t0 + 10)
        XCTAssertEqual(r.status, .invalidFeed)
        XCTAssertEqual(r.lastSuccessAt, t0)
        XCTAssertEqual(r.etag, "old", "파싱 실패한 응답의 ETag는 쓰지 않음 (다음에 다시 받도록)")
    }

    // MARK: 429

    func testRateLimitDefault24HoursBlocksAutoAndManual() {
        var r = LmsSyncPolicy.recordingAttempt(LmsSyncRecord(), now: t0)
        r = LmsSyncPolicy.recording(.rateLimited(retryAfter: nil), parseSucceeded: false, into: r, now: t0)
        XCTAssertEqual(r.status, .rateLimited)
        XCTAssertEqual(r.rateLimitedUntil, t0 + 24 * 3600)
        XCTAssertEqual(LmsSyncPolicy.decide(manual: true, now: t0 + 3600, record: r), .skipRateLimited(until: t0 + 24 * 3600))
        XCTAssertEqual(LmsSyncPolicy.decide(manual: false, now: t0 + 23 * 3600, record: r), .skipRateLimited(until: t0 + 24 * 3600))
        XCTAssertEqual(LmsSyncPolicy.decide(manual: true, now: t0 + 24 * 3600, record: r), .proceed)

        let manual = LmsSyncService.manualAvailability(isEnabled: true, hasFeedURL: true, isSyncing: false, record: r, now: t0 + 3600)
        XCTAssertEqual(manual, .init(enabled: false, note: "23시간 뒤 가능"), "그동안 수동 버튼 비활성")
    }

    func testRateLimitRetryAfterAndDoubling() {
        var r = LmsSyncRecord()
        r = LmsSyncPolicy.recording(.rateLimited(retryAfter: 3600), parseSucceeded: false, into: r, now: t0)
        XCTAssertEqual(r.rateLimitedUntil, t0 + 3600, "Retry-After 반영")
        r = LmsSyncPolicy.recording(.rateLimited(retryAfter: 3600), parseSucceeded: false, into: r, now: t0 + 3600)
        XCTAssertEqual(r.rateLimitedUntil, t0 + 3600 + 7200, "연속이면 2배")
        r = LmsSyncPolicy.recording(.rateLimited(retryAfter: nil), parseSucceeded: false, into: r, now: t0)
        XCTAssertEqual(r.consecutiveRateLimits, 3)
        XCTAssertEqual(r.rateLimitedUntil, t0 + 4 * 86400, "24시간 × 4")
        // 429가 아닌 응답이 오면 연속 횟수 초기화
        r = LmsSyncPolicy.recording(.notModified, parseSucceeded: false, into: r, now: t0)
        XCTAssertEqual(r.consecutiveRateLimits, 0)
        XCTAssertNil(r.rateLimitedUntil)
    }

    func testRateLimitPauseCap() {
        XCTAssertEqual(LmsSyncPolicy.rateLimitPause(retryAfter: nil, consecutive: 10), 7 * 86400, "두 배는 7일까지")
        XCTAssertEqual(LmsSyncPolicy.rateLimitPause(retryAfter: 10 * 86400, consecutive: 1), 10 * 86400, "서버가 더 길게 요구하면 따름")
    }

    func testRetryAfterParsing() {
        XCTAssertEqual(LmsSyncPolicy.parseRetryAfter("120", now: t0), 120)
        XCTAssertNil(LmsSyncPolicy.parseRetryAfter("0", now: t0))
        XCTAssertNil(LmsSyncPolicy.parseRetryAfter("이상한 값", now: t0))
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        XCTAssertEqual(LmsSyncPolicy.parseRetryAfter(f.string(from: t0 + 7200), now: t0), 7200)
        XCTAssertNil(LmsSyncPolicy.parseRetryAfter(f.string(from: t0 - 10), now: t0), "지난 날짜")
    }

    func testNewURLResetKeepsRateLimit() {
        var r = LmsSyncRecord()
        r.lastAttemptAt = t0
        r.etag = "e"
        r.status = .rateLimited
        r.rateLimitedUntil = t0 + 100
        r.consecutiveRateLimits = 2
        let reset = r.resetForNewURL()
        XCTAssertNil(reset.lastAttemptAt)
        XCTAssertNil(reset.etag)
        XCTAssertEqual(reset.status, .never)
        XCTAssertEqual(reset.rateLimitedUntil, t0 + 100)
        XCTAssertEqual(reset.consecutiveRateLimits, 2)
    }

    func testManualAvailabilityNotes() {
        let base = LmsSyncPolicy.recordingAttempt(LmsSyncRecord(), now: t0)
        XCTAssertEqual(LmsSyncService.manualAvailability(isEnabled: true, hasFeedURL: true, isSyncing: false, record: base, now: t0 + 61),
                       .init(enabled: false, note: "4분 뒤 가능"))
        XCTAssertEqual(LmsSyncService.manualAvailability(isEnabled: true, hasFeedURL: true, isSyncing: false, record: base, now: t0 + 300),
                       .init(enabled: true, note: nil))
        XCTAssertFalse(LmsSyncService.manualAvailability(isEnabled: true, hasFeedURL: true, isSyncing: true, record: LmsSyncRecord(), now: t0).enabled)
        XCTAssertFalse(LmsSyncService.manualAvailability(isEnabled: false, hasFeedURL: true, isSyncing: false, record: LmsSyncRecord(), now: t0).enabled)
        XCTAssertFalse(LmsSyncService.manualAvailability(isEnabled: true, hasFeedURL: false, isSyncing: false, record: LmsSyncRecord(), now: t0).enabled)
    }

    // MARK: 패널 문구

    func testPanelMessages() {
        var r = LmsSyncRecord()
        XCTAssertNil(LmsDisplay.panelMessage(record: r, now: t0))
        r.status = .disconnected
        XCTAssertEqual(LmsDisplay.panelMessage(record: r, now: t0), "연결이 끊겼어요 · 설정에서 피드 주소 다시 넣기")
        r.status = .offline
        r.lastSuccessAt = t0 - 3 * 3600 - 59
        XCTAssertEqual(LmsDisplay.panelMessage(record: r, now: t0), "마지막 동기화: 3시간 전")
        r.status = .invalidFeed
        XCTAssertNil(LmsDisplay.panelMessage(record: r, now: t0), "형식 오류는 설정 창에만")
        r.status = .rateLimited
        r.rateLimitedUntil = t0 + 5 * 3600 + 1
        XCTAssertEqual(LmsDisplay.panelMessage(record: r, now: t0), "LMS가 잠시 쉬어 달래요 · 6시간 뒤 다시 시도")
        XCTAssertEqual(LmsDisplay.relative(nil, now: t0), "없음")
        XCTAssertEqual(LmsDisplay.relative(t0 - 30, now: t0), "방금 전")
        XCTAssertEqual(LmsDisplay.relative(t0 - 600, now: t0), "10분 전")
        XCTAssertEqual(LmsDisplay.relative(t0 - 2 * 86400, now: t0), "2일 전")
    }

    // MARK: 표시 범위·숨김

    private func lms(_ uid: String, _ due: LocalDate, _ time: LocalTime? = nil, title: String? = nil) -> LmsItem {
        LmsItem(uid: uid, title: title ?? uid, courseName: nil, dueDate: due, dueTime: time)
    }

    func testVisibleRangeAndOverdueRule() {
        let items = [
            lms("past2", today.adding(days: -2)),    // 지난 지 이틀 → 숨김
            lms("past1", today.adding(days: -1)),    // 마감 다음 날 → 빨간색으로 보임
            lms("today", today),
            lms("in2w", today.adding(days: 14)),     // 2주 끝 → 보임
            lms("over2w", today.adding(days: 15)),   // 2주 넘음 → 숨김
        ]
        let shown = LmsDisplay.visible(items, checked: [:], today: today, weeks: 2).map(\.uid)
        XCTAssertEqual(shown, ["past1", "today", "in2w"])
        XCTAssertTrue(LmsDisplay.isOverdue(items[1], isChecked: false, today: today))
        XCTAssertFalse(LmsDisplay.isOverdue(items[2], isChecked: false, today: today))
        XCTAssertEqual(LmsDisplay.visible(items, checked: [:], today: today, weeks: 1).map(\.uid), ["past1", "today"])
        XCTAssertEqual(LmsDisplay.visible(items, checked: [:], today: today, weeks: 99).count, 4, "기간은 1~8주로 제한")
    }

    func testCheckedHiddenNextDay() {
        let a = lms("a", today.adding(days: 3)), b = lms("b", today.adding(days: 3))
        let checked = [a.uid: today.adding(days: -1).noonDate!, b.uid: today.noonDate!]
        let shown = LmsDisplay.visible([a, b], checked: checked, today: today, weeks: 2).map(\.uid)
        XCTAssertEqual(shown, ["b"], "어제 체크 → 숨김, 오늘 체크 → 보임")
        let oldChecked = lms("old", today.adding(days: -5))
        XCTAssertEqual(LmsDisplay.visible([oldChecked], checked: ["old": today.noonDate!], today: today, weeks: 2).count, 1,
                       "오늘 체크한 지난 과제는 오늘은 보임")
    }

    func testSortOrder() {
        let items = [
            lms("checked", today, LocalTime(hour: 9, minute: 0)),
            lms("tomorrow", today.adding(days: 1)),
            lms("todayNoTime", today),
            lms("today2359", today, LocalTime(hour: 23, minute: 59)),
            lms("today0900", today, LocalTime(hour: 9, minute: 0)),
        ]
        let shown = LmsDisplay.visible(items, checked: ["checked": today.noonDate!], today: today, weeks: 2).map(\.uid)
        XCTAssertEqual(shown, ["today0900", "today2359", "todayNoTime", "tomorrow", "checked"])
    }

    func testDueLabel() {
        XCTAssertEqual(LmsDisplay.dueLabel(lms("a", today, LocalTime(hour: 23, minute: 59)), today: today), "D-Day 23:59")
        XCTAssertEqual(LmsDisplay.dueLabel(lms("a", today.adding(days: 3)), today: today), "D-3")
        XCTAssertEqual(LmsDisplay.dueLabel(lms("a", today.adding(days: -1), LocalTime(hour: 9, minute: 5)), today: today), "D+1 09:05")
    }

    // MARK: 과목명 줄이기

    func testShortCourseName() {
        XCTAssertEqual(LmsDisplay.shortCourseName("컴퓨터구조(Computer Architecture) 02분반"), "컴퓨터구조 02분반")
        XCTAssertEqual(LmsDisplay.shortCourseName("가짜과목 (Fake Course) 01분반"), "가짜과목 01분반")
        XCTAssertEqual(LmsDisplay.shortCourseName("자료구조(2학년) 01분반"), "자료구조(2학년) 01분반", "한글 괄호는 유지")
        XCTAssertEqual(LmsDisplay.shortCourseName("선형대수(1) 03분반"), "선형대수(1) 03분반", "숫자만 있는 괄호는 유지")
        XCTAssertEqual(LmsDisplay.shortCourseName("캡스톤（Capstone Design）"), "캡스톤", "전각 괄호")
        XCTAssertEqual(LmsDisplay.shortCourseName("(English Only)"), "(English Only)", "다 지워지면 원문")
        XCTAssertEqual(LmsDisplay.shortCourseName("짝 없는 (Open"), "짝 없는 (Open")
    }

    // MARK: 패널 높이 (T-004 함수에 LMS 칸 추가)

    func testPanelHeightWithoutLmsUnchanged() {
        for n in [0, 1, 5, 50] {
            XCTAssertEqual(PanelLayout.bodyHeight(rowCount: n, datePickerOpen: false, notchHeight: 32, screenHeight: 956),
                           PanelLayout.bodyHeight(rowCount: n, datePickerOpen: false, notchHeight: 32, screenHeight: 956, lms: nil))
            XCTAssertEqual(PanelLayout.scrollContentHeight(rowCount: n, lms: nil), PanelLayout.listHeight(rowCount: n))
        }
    }

    func testPanelHeightWithLms() {
        let block = PanelLayout.LmsBlock(rowCount: 2, collapsed: false, hasMessage: false)
        let lmsH = PanelLayout.lmsHeaderHeight + PanelLayout.lmsRowsTopGap + 2 * PanelLayout.lmsRowHeight + PanelLayout.rowSpacing + PanelLayout.lmsBottomGap
        XCTAssertEqual(PanelLayout.lmsBlockHeight(block), lmsH)
        // 내 할 일 3개 + LMS 2개
        let fixed = PanelLayout.fixedHeight(notchHeight: 32, datePickerOpen: false)
        XCTAssertEqual(PanelLayout.bodyHeight(rowCount: 3, datePickerOpen: false, notchHeight: 32, screenHeight: 956, lms: block),
                       fixed + PanelLayout.listVerticalPadding + lmsH + PanelLayout.rowsHeight(3))
        // 내 할 일 0개면 빈 목록 문구 높이
        XCTAssertEqual(PanelLayout.scrollContentHeight(rowCount: 0, lms: block),
                       PanelLayout.listVerticalPadding + lmsH + PanelLayout.emptyListHeight)
        // 접으면 행이 빠지고, 문구가 있으면 한 줄 추가
        let collapsed = PanelLayout.LmsBlock(rowCount: 2, collapsed: true, hasMessage: true)
        XCTAssertEqual(PanelLayout.lmsBlockHeight(collapsed),
                       PanelLayout.lmsHeaderHeight + PanelLayout.lmsMessageHeight + PanelLayout.lmsBottomGap)
        // 많으면 최대 높이에서 멈춤
        let many = PanelLayout.LmsBlock(rowCount: 30, collapsed: false, hasMessage: true)
        XCTAssertEqual(PanelLayout.bodyHeight(rowCount: 30, datePickerOpen: false, notchHeight: 32, screenHeight: 956, lms: many),
                       PanelLayout.maxHeight(screenHeight: 956))
    }
}
