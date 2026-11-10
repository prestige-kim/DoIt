import Foundation

/// `.ics`(iCalendar) 피드에서 LMS 과제만 뽑는 순수 파서 (외부 패키지 없음, ARCHITECTURE §3.8)
///
/// 보안 규칙 (T-007 규칙 3):
/// - **허용 목록 방식**: `VEVENT` 안의 `UID`, `SUMMARY`, `DTSTART`, `DTEND`만 읽는다.
/// - 그 밖의 속성(`DESCRIPTION`, `X-ALT-DESC`, `URL`, `ATTACH` …)은 **이어지는 줄까지 통째로 건너뛰고**,
///   값을 문자열로 만들지도 않는다. `VEVENT` 안의 `VALARM` 같은 안쪽 묶음도 통째로 건너뛴다.
/// - 결과에는 과제명·과목명·날짜·시각과 개수만 들어 있다.
enum IcsParser {
    struct Result: Equatable {
        /// 과제 항목 (UID가 `event-assignment-`로 시작하는 것). 피드 순서 그대로
        var items: [LmsItem] = []
        /// 과제가 아니라서 버린 일정 수
        var skippedNonAssignment = 0
        /// 깨졌거나 모르는 형식이라 건너뛴 과제 수 (UID 없음, 날짜 해석 불가 등)
        var skippedBroken = 0
    }

    enum ParseError: Error, Equatable {
        /// `BEGIN:VCALENDAR`가 없음 (로그인 화면 HTML 같은 것이 온 경우)
        case notCalendar
    }

    static let assignmentUIDPrefix = "event-assignment-"
    /// 읽는 속성 (이 밖의 것은 건너뜀)
    static let allowedProperties: Set<String> = ["UID", "SUMMARY", "DTSTART", "DTEND"]

    static func parse(data: Data, timeZone: TimeZone = .current) throws -> Result {
        guard let text = String(data: data, encoding: .utf8) else { throw ParseError.notCalendar }
        return try parse(text, timeZone: timeZone)
    }

    /// - Parameter timeZone: 날짜·시각을 정할 로컬 시간대 (테스트에서 서울로 고정)
    static func parse(_ text: String, timeZone: TimeZone = .current) throws -> Result {
        var result = Result()
        var sawCalendar = false
        var seenUIDs = Set<String>()

        var inEvent = false
        var nestedDepth = 0          // VEVENT 안의 VALARM 등
        var event = EventFields()

        for line in logicalLines(text) {
            let name = line.name
            if name == "BEGIN" {
                let value = line.value.uppercased()
                if value == "VCALENDAR" { sawCalendar = true }
                if inEvent {
                    nestedDepth += 1
                } else if value == "VEVENT" {
                    inEvent = true
                    nestedDepth = 0
                    event = EventFields()
                }
                continue
            }
            if name == "END" {
                guard inEvent else { continue }
                if nestedDepth > 0 {
                    nestedDepth -= 1
                } else if line.value.uppercased() == "VEVENT" {
                    inEvent = false
                    finish(event, into: &result, seen: &seenUIDs, timeZone: timeZone)
                }
                continue
            }
            guard inEvent, nestedDepth == 0 else { continue }
            if line.broken {
                event.broken = true
                continue
            }
            switch name {
            case "UID": event.uid = unescape(line.value).trimmingCharacters(in: .whitespaces)
            case "SUMMARY": event.summary = unescape(line.value)
            case "DTSTART": event.dtStart = (line.params, line.value)
            case "DTEND": event.dtEnd = (line.params, line.value)
            default: break
            }
        }
        guard sawCalendar else { throw ParseError.notCalendar }
        return result
    }

    // MARK: 한 일정 마무리

    private struct EventFields {
        var uid: String?
        var summary: String?
        var dtStart: (params: [String: String], value: String)?
        var dtEnd: (params: [String: String], value: String)?
        var broken = false
    }

    private static func finish(_ e: EventFields, into result: inout Result, seen: inout Set<String>, timeZone: TimeZone) {
        guard let uid = e.uid, !uid.isEmpty else {
            result.skippedBroken += 1  // UID가 없으면 과제인지도 알 수 없다
            return
        }
        guard uid.hasPrefix(assignmentUIDPrefix) else {
            result.skippedNonAssignment += 1
            return
        }
        guard !e.broken, !seen.contains(uid),
              let summary = e.summary,
              let when = e.dtStart ?? e.dtEnd,
              let due = parseDate(params: when.params, value: when.value, timeZone: timeZone) else {
            result.skippedBroken += 1
            return
        }
        let (title, course) = splitSummary(summary)
        guard !title.isEmpty else {
            result.skippedBroken += 1
            return
        }
        seen.insert(uid)
        result.items.append(LmsItem(uid: uid, title: title, courseName: course, dueDate: due.date, dueTime: due.time))
    }

    // MARK: 제목 → 과제명 + 과목명

    /// `SUMMARY`의 **맨 끝 `[...]`** 을 과목명, 그 앞(앞뒤 공백 제거)을 과제명으로 나눈다.
    /// 과목명 안에 대괄호가 또 있어도 짝을 맞춰 찾는다. 대괄호가 없거나 짝이 안 맞으면 과목명 없음.
    /// 과제명 부분이 비면 제목 전체를 과제명으로 쓰고 과목명은 없음.
    static func splitSummary(_ summary: String) -> (title: String, course: String?) {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix("]") else { return (oneLine(trimmed), nil) }
        var depth = 0
        var index = trimmed.endIndex
        while index > trimmed.startIndex {
            index = trimmed.index(before: index)
            let c = trimmed[index]
            if c == "]" { depth += 1 }
            if c == "[" {
                depth -= 1
                if depth == 0 {
                    let course = trimmed[trimmed.index(after: index)..<trimmed.index(before: trimmed.endIndex)]
                        .trimmingCharacters(in: .whitespaces)
                    let title = trimmed[..<index].trimmingCharacters(in: .whitespacesAndNewlines)
                    if title.isEmpty { return (oneLine(trimmed), nil) }
                    return (oneLine(title), course.isEmpty ? nil : oneLine(course))
                }
            }
        }
        return (oneLine(trimmed), nil)
    }

    private static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    // MARK: 날짜

    /// - `VALUE=DATE` → 앞 8자리 날짜, 시각 없음 (`20261009T000000`처럼 꼬리가 붙어 와도)
    /// - 값이 8자리뿐 → 날짜
    /// - DATE-TIME: `...Z`(UTC) 또는 `TZID=` → 로컬 시간대로 바꾼 뒤 날짜·시각. 둘 다 없으면 로컬 시각 그대로(floating)
    static func parseDate(params: [String: String], value raw: String, timeZone: TimeZone) -> (date: LocalDate, time: LocalTime?)? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        let isDateOnly = params["VALUE"]?.uppercased() == "DATE"
        let digits = value.prefix(8)
        guard digits.count == 8, digits.allSatisfy(\.isASCIIDigit),
              let y = Int(digits.prefix(4)), let m = Int(digits.dropFirst(4).prefix(2)), let d = Int(digits.suffix(2)) else { return nil }

        if isDateOnly || value.count == 8 {
            guard let date = validDate(y, m, d) else { return nil }
            return (date, nil)
        }

        // DATE-TIME: yyyyMMddTHHmmss[Z]
        var rest = value.dropFirst(8)
        guard rest.first == "T" || rest.first == "t" else { return nil }
        rest = rest.dropFirst()
        let isUTC = rest.hasSuffix("Z") || rest.hasSuffix("z")
        if isUTC { rest = rest.dropLast() }
        guard rest.count == 6, rest.allSatisfy(\.isASCIIDigit),
              let hh = Int(rest.prefix(2)), let mm = Int(rest.dropFirst(2).prefix(2)), let ss = Int(rest.suffix(2)),
              (0..<24).contains(hh), (0..<60).contains(mm), (0...60).contains(ss) else { return nil }

        let sourceZone: TimeZone
        if isUTC {
            sourceZone = TimeZone(identifier: "UTC")!
        } else if let tzid = params["TZID"] {
            guard let zone = TimeZone(identifier: tzid) else { return nil }  // 모르는 시간대 → 그 항목만 건너뜀
            sourceZone = zone
        } else {
            sourceZone = timeZone
        }
        var source = Calendar(identifier: .gregorian)
        source.timeZone = sourceZone
        guard let instant = source.date(from: DateComponents(year: y, month: m, day: d, hour: hh, minute: mm, second: ss)),
              source.component(.day, from: instant) == d else { return nil }

        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        let c = local.dateComponents([.year, .month, .day, .hour, .minute], from: instant)
        guard let ly = c.year, let lm = c.month, let ld = c.day, let lh = c.hour, let lmin = c.minute else { return nil }
        return (LocalDate(year: ly, month: lm, day: ld), LocalTime(hour: lh, minute: lmin))
    }

    private static func validDate(_ y: Int, _ m: Int, _ d: Int) -> LocalDate? {
        guard (1...12).contains(m), (1...31).contains(d) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let date = cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12)),
              cal.component(.day, from: date) == d else { return nil }
        return LocalDate(year: y, month: m, day: d)
    }

    // MARK: 이스케이프

    /// `\,` `\;` `\n`/`\N` `\\` (RFC 5545 TEXT)
    static func unescape(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        var out = ""
        var escaping = false
        for c in s {
            if escaping {
                switch c {
                case "n", "N": out.append("\n")
                case ",", ";", "\\": out.append(c)
                default: out.append("\\"); out.append(c)  // 모르는 이스케이프는 그대로
                }
                escaping = false
            } else if c == "\\" {
                escaping = true
            } else {
                out.append(c)
            }
        }
        if escaping { out.append("\\") }
        return out
    }

    // MARK: 줄 나누기 (접힌 줄 풀기 + 허용 목록)

    struct LogicalLine {
        /// 속성 이름 (대문자)
        let name: String
        let params: [String: String]
        let value: String
        /// 이름·값 구분(`:`)이 없거나 이름이 이상한 줄
        let broken: Bool
    }

    /// 실제 줄 → 논리 줄. 다음 줄이 공백·탭으로 시작하면 앞 줄에 이어 붙인다.
    /// **허용 목록 밖의 속성은 이어지는 줄까지 버리고 문자열로 합치지 않는다.**
    static func logicalLines(_ text: String) -> [LogicalLine] {
        var lines: [LogicalLine] = []
        var current: String?        // 이어 붙이는 중인 (허용) 줄
        var skipping = false        // 허용 목록 밖 속성의 이어지는 줄을 버리는 중

        func flush() {
            if let c = current { lines.append(makeLine(c)) }
            current = nil
        }

        // CRLF·LF 모두 받는다 ("\r\n"은 Swift에서 문자 1개라 따로 나눈다)
        for rawSub in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            let raw = Substring(rawSub)
            if let first = raw.first, first == " " || first == "\t" {
                if skipping { continue }
                if current != nil { current! += raw.dropFirst() }
                continue
            }
            flush()
            skipping = false
            guard !raw.isEmpty else { continue }
            let name = propertyName(of: raw)
            if name == "BEGIN" || name == "END" || allowedProperties.contains(name) {
                current = String(raw)
            } else {
                skipping = true     // 값은 보지도 않는다 (DESCRIPTION 등)
                if !isValidName(name) { lines.append(LogicalLine(name: name, params: [:], value: "", broken: true)) }
            }
        }
        flush()
        return lines
    }

    private static func propertyName(of raw: Substring) -> String {
        let end = raw.firstIndex(where: { $0 == ";" || $0 == ":" }) ?? raw.endIndex
        return raw[..<end].uppercased()
    }

    private static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }
    }

    /// `NAME;P1=v;P2="v":VALUE`
    private static func makeLine(_ line: String) -> LogicalLine {
        var inQuotes = false
        var colon: String.Index?
        for i in line.indices {
            let c = line[i]
            if c == "\"" { inQuotes.toggle() }
            if c == ":" && !inQuotes { colon = i; break }
        }
        guard let colon else {
            return LogicalLine(name: propertyName(of: Substring(line)), params: [:], value: "", broken: true)
        }
        let head = line[..<colon]
        let value = String(line[line.index(after: colon)...])
        let parts = head.split(separator: ";", omittingEmptySubsequences: false)
        let name = parts.first.map { $0.uppercased() } ?? ""
        guard isValidName(name) else { return LogicalLine(name: name, params: [:], value: "", broken: true) }
        var params: [String: String] = [:]
        for p in parts.dropFirst() {
            guard let eq = p.firstIndex(of: "=") else { continue }
            var v = String(p[p.index(after: eq)...])
            if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 { v = String(v.dropFirst().dropLast()) }
            params[p[..<eq].uppercased()] = v
        }
        return LogicalLine(name: name, params: params, value: value, broken: false)
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
