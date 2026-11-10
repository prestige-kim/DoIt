import XCTest
@testable import DoIt

/// T-007: `.ics` 파서. 직접 만든 가짜 fixture(`Fixtures/fake-feed.ics`)와 코드 안 문자열만 쓴다 (실제 피드 없음)
final class IcsParserTests: XCTestCase {
    private let seoul = TimeZone(identifier: "Asia/Seoul")!

    private func fixture() throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fake-feed", withExtension: "ics"),
                                "fixture가 테스트 번들에 있어야 함")
        return try Data(contentsOf: url)
    }

    private func parseFixture() throws -> IcsParser.Result {
        try IcsParser.parse(data: fixture(), timeZone: seoul)
    }

    private func item(_ uid: String, _ r: IcsParser.Result) throws -> LmsItem {
        try XCTUnwrap(r.items.first { $0.uid == uid }, uid)
    }

    private func calendar(_ body: String) -> String {
        "BEGIN:VCALENDAR\nVERSION:2.0\n\(body)\nEND:VCALENDAR\n"
    }

    // MARK: 개수·과제 판별

    func testOnlyAssignmentsKeptAndCountsReported() throws {
        let r = try parseFixture()
        XCTAssertEqual(r.items.map(\.uid), ["event-assignment-1001", "event-assignment-1002", "event-assignment-1003",
                                            "event-assignment-1005", "event-assignment-1007"])
        XCTAssertEqual(r.skippedNonAssignment, 1, "event-calendar-event-77")
        XCTAssertEqual(r.skippedBroken, 2, "깨진 날짜 1 + 중복 UID 1")
    }

    // MARK: 날짜

    func testUTCConvertsToSeoulDateBoundary() throws {
        // 20261009T150000Z = 서울 10/10 00:00 (UTC 날짜를 그대로 쓰면 10/9로 하루 어긋남)
        let a = try item("event-assignment-1001", parseFixture())
        XCTAssertEqual(a.dueDate, LocalDate(year: 2026, month: 10, day: 10))
        XCTAssertEqual(a.dueTime, LocalTime(hour: 0, minute: 0))
    }

    func testValueDateWithTrailingTimeIsDateOnly() throws {
        let a = try item("event-assignment-1002", parseFixture())
        XCTAssertEqual(a.dueDate, LocalDate(year: 2026, month: 10, day: 12))
        XCTAssertNil(a.dueTime, "VALUE=DATE면 뒤에 T000000이 붙어도 시각 없음")
        let plain = try item("event-assignment-1007", parseFixture())
        XCTAssertEqual(plain.dueDate, LocalDate(year: 2026, month: 10, day: 13))
        XCTAssertNil(plain.dueTime)
    }

    func testTZIDConvertsToLocal() throws {
        // 뉴욕 10/10 10:00 (EDT, UTC-4) = 서울 10/10 23:00
        let a = try item("event-assignment-1003", parseFixture())
        XCTAssertEqual(a.dueDate, LocalDate(year: 2026, month: 10, day: 10))
        XCTAssertEqual(a.dueTime, LocalTime(hour: 23, minute: 0))
    }

    func testDTENDUsedWhenNoDTSTART() throws {
        // 20261011T145900Z = 서울 10/11 23:59
        let a = try item("event-assignment-1005", parseFixture())
        XCTAssertEqual(a.dueDate, LocalDate(year: 2026, month: 10, day: 11))
        XCTAssertEqual(a.dueTime, LocalTime(hour: 23, minute: 59))
    }

    func testUTCLateEveningCrossesToNextDayAndSameZoneDoesNot() {
        let lateUTC = IcsParser.parseDate(params: [:], value: "20261231T235900Z", timeZone: seoul)
        XCTAssertEqual(lateUTC?.date, LocalDate(year: 2027, month: 1, day: 1))
        XCTAssertEqual(lateUTC?.time, LocalTime(hour: 8, minute: 59))
        let utcZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(IcsParser.parseDate(params: [:], value: "20261231T235900Z", timeZone: utcZone)?.date,
                       LocalDate(year: 2026, month: 12, day: 31))
        // 시간대 표시가 없는 시각(floating)은 로컬 시각 그대로
        let floating = IcsParser.parseDate(params: [:], value: "20261009T235900", timeZone: seoul)
        XCTAssertEqual(floating?.date, LocalDate(year: 2026, month: 10, day: 9))
        XCTAssertEqual(floating?.time, LocalTime(hour: 23, minute: 59))
    }

    func testBadDatesRejected() {
        XCTAssertNil(IcsParser.parseDate(params: [:], value: "2026BROKEN", timeZone: seoul))
        XCTAssertNil(IcsParser.parseDate(params: ["VALUE": "DATE"], value: "20260230", timeZone: seoul), "2월 30일")
        XCTAssertNil(IcsParser.parseDate(params: [:], value: "20261009T256000Z", timeZone: seoul))
        XCTAssertNil(IcsParser.parseDate(params: ["TZID": "Nowhere/Unknown"], value: "20261009T100000", timeZone: seoul),
                     "모르는 시간대는 그 항목만 건너뜀")
    }

    // MARK: 제목

    func testCourseNameWithParenthesesAndTitleSplit() throws {
        let a = try item("event-assignment-1001", parseFixture())
        XCTAssertEqual(a.title, "가짜 과제 1")
        XCTAssertEqual(a.courseName, "가짜과목(Fake Course) 01분반", "저장은 원문 그대로")
    }

    func testEscapesAndNestedBracketsInCourse() throws {
        let a = try item("event-assignment-1002", parseFixture())
        XCTAssertEqual(a.title, "보고서, 초안; 최종 \\ 제출")
        XCTAssertEqual(a.courseName, "테스트과목 [실습] 02분반", "맨 끝 [...]은 짝을 맞춰 찾음")
    }

    func testNoBracketsMeansNoCourse() throws {
        let a = try item("event-assignment-1005", parseFixture())
        XCTAssertEqual(a.title, "대괄호 없는 과제")
        XCTAssertNil(a.courseName)
    }

    func testSplitSummaryEdgeCases() {
        XCTAssertEqual(IcsParser.splitSummary("과제 [과목] 뒤에 글자").course, nil, "맨 끝이 ]가 아니면 과목명 없음")
        XCTAssertEqual(IcsParser.splitSummary("과제 [과목] 뒤에 글자").title, "과제 [과목] 뒤에 글자")
        XCTAssertEqual(IcsParser.splitSummary("  과제명   [ 과목 ]  ").title, "과제명")
        XCTAssertEqual(IcsParser.splitSummary("  과제명   [ 과목 ]  ").course, "과목")
        XCTAssertEqual(IcsParser.splitSummary("[과목만]").title, "[과목만]", "과제명이 비면 제목 전체")
        XCTAssertNil(IcsParser.splitSummary("[과목만]").course)
        XCTAssertNil(IcsParser.splitSummary("짝이 안 맞음]").course)
        XCTAssertEqual(IcsParser.splitSummary("두 줄\n제목 [과목]").title, "두 줄 제목")
    }

    func testUnescape() {
        XCTAssertEqual(IcsParser.unescape(#"a\,b\;c\nd\Ne\\f"#), "a,b;c\nd\ne\\f")
        XCTAssertEqual(IcsParser.unescape(#"모름\x"#), #"모름\x"#)
        XCTAssertEqual(IcsParser.unescape("끝\\"), "끝\\")
    }

    // MARK: 줄 접기

    func testUnfoldingSpaceAndTab() throws {
        let a = try item("event-assignment-1007", parseFixture())
        // 이어지는 줄의 맨 앞 공백·탭 1개만 지우고 붙인다
        XCTAssertEqual(a.title, "접힌 제목이 길어서 이어집니다")
        XCTAssertEqual(a.courseName, "접힌과목 04분반")
    }

    func testLFOnlyLineEndingsAlsoWork() throws {
        let text = calendar("BEGIN:VEVENT\nUID:event-assignment-1\nDTSTART;VALUE=DATE:20261101\nSUMMARY:LF 과제 [과\n 목]\nEND:VEVENT")
        let r = try IcsParser.parse(text, timeZone: seoul)
        XCTAssertEqual(r.items.first?.title, "LF 과제")
        XCTAssertEqual(r.items.first?.courseName, "과목")
    }

    func testLowercasePropertyNamesAndQuotedParams() throws {
        let text = calendar("begin:vevent\nuid:event-assignment-9\ndtstart;tzid=\"Asia/Seoul\":20261101T235900\nsummary:소문자 [과목]\nend:vevent")
        let r = try IcsParser.parse(text, timeZone: seoul)
        XCTAssertEqual(r.items.first?.dueTime, LocalTime(hour: 23, minute: 59))
    }

    // MARK: 깨진 입력

    func testBrokenLineSkipsOnlyThatEvent() throws {
        let text = calendar("""
        BEGIN:VEVENT
        UID:event-assignment-1
        이상한 줄입니다
        DTSTART;VALUE=DATE:20261101
        SUMMARY:깨진 줄이 있는 과제
        END:VEVENT
        BEGIN:VEVENT
        UID:event-assignment-2
        DTSTART;VALUE=DATE:20261102
        SUMMARY:멀쩡한 과제
        END:VEVENT
        BEGIN:VEVENT
        DTSTART;VALUE=DATE:20261103
        SUMMARY:UID 없음
        END:VEVENT
        BEGIN:VEVENT
        UID:event-assignment-4
        SUMMARY:날짜 없음
        END:VEVENT
        """)
        let r = try IcsParser.parse(text, timeZone: seoul)
        XCTAssertEqual(r.items.map(\.title), ["멀쩡한 과제"])
        XCTAssertEqual(r.skippedBroken, 3)
    }

    func testNonCalendarIsRejected() {
        XCTAssertThrowsError(try IcsParser.parse("<html><body>로그인이 필요합니다</body></html>", timeZone: seoul)) { e in
            XCTAssertEqual(e as? IcsParser.ParseError, .notCalendar)
        }
        XCTAssertThrowsError(try IcsParser.parse(data: Data([0xFF, 0xFE, 0x00]), timeZone: seoul))
    }

    func testEmptyCalendarIsValidWithNoItems() throws {
        let r = try IcsParser.parse("BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n", timeZone: seoul)
        XCTAssertEqual(r, IcsParser.Result())
    }

    // MARK: 보안 규칙 3 — 허용 목록 밖 내용이 결과 어디에도 없음

    static let forbiddenMarkers = ["SECRET-DESC-MARKER", "SECRET-VERIFIER-MARKER", "ALT-HTML-MARKER", "URL-MARKER",
                                   "ATTACH-MARKER", "LOCATION-MARKER", "VALARM-MARKER", "VALARM-DESC-MARKER",
                                   "NONASSIGN-MARKER", "DUPLICATE-MARKER", "example.invalid", "files/", "https://",
                                   "download", ".pdf", "<html", "강의자료"]

    func testForbiddenContentNeverReachesResult() throws {
        let r = try parseFixture()
        let dump = String(describing: r)
        let json = String(decoding: try TodoStore.makeEncoder().encode(r.items), as: UTF8.self)
        for marker in Self.forbiddenMarkers {
            XCTAssertFalse(dump.contains(marker), "결과에 \(marker)가 있으면 안 됨")
            XCTAssertFalse(json.contains(marker), "JSON에 \(marker)가 있으면 안 됨")
        }
    }

    func testSkippedPropertiesAreNotEvenJoinedIntoLines() throws {
        let text = String(decoding: try fixture(), as: UTF8.self)
        let lines = IcsParser.logicalLines(text)
        let names = Set(lines.map(\.name))
        XCTAssertTrue(names.isSubset(of: ["BEGIN", "END", "UID", "SUMMARY", "DTSTART", "DTEND"]), "\(names)")
        for line in lines {
            for marker in ["SECRET", "ALT-HTML", "ATTACH-MARKER", "example.invalid"] {
                XCTAssertFalse(line.value.contains(marker))
            }
        }
    }
}
