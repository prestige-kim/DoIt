import Foundation

/// 동기화 상태 (ARCHITECTURE §3.8 오류 상태 매핑)
enum LmsSyncStatus: String, Codable {
    /// 아직 한 번도 시도하지 않음
    case never
    case ok
    /// 401·403·404·410: 주소가 무효
    case disconnected
    /// 네트워크 오류·5xx
    case offline
    /// 파싱 실패·리디렉트 거부·크기 초과·그 밖의 응답
    case invalidFeed
    /// 429
    case rateLimited
}

/// 동기화 기록. UserDefaults에 JSON으로 저장한다 (피드 주소는 들어 있지 않다).
struct LmsSyncRecord: Codable, Equatable {
    /// 마지막 **시도** 시각 (실패도 포함, 간격 계산 기준)
    var lastAttemptAt: Date?
    /// 마지막 성공 시각 (200·304)
    var lastSuccessAt: Date?
    var status: LmsSyncStatus = .never
    var etag: String?
    var lastModified: String?
    /// 429를 받았을 때 이 시각까지 자동·수동 모두 멈춤
    var rateLimitedUntil: Date?
    /// 연속 429 횟수 (429가 아닌 응답이 오면 0)
    var consecutiveRateLimits = 0

    /// 주소를 바꿀 때: 이전 주소의 기록(ETag·시도 시각·상태)은 지우고, **429 멈춤은 같은 서버라서 유지**한다
    func resetForNewURL() -> LmsSyncRecord {
        var r = LmsSyncRecord()
        r.rateLimitedUntil = rateLimitedUntil
        r.consecutiveRateLimits = consecutiveRateLimits
        return r
    }
}

/// 요청 1번의 결과 (네트워크 계층이 돌려줌, 테스트에서는 가짜로 만든다)
enum FeedFetchOutcome: Equatable {
    /// HTTP 응답을 받음. 헤더 이름은 소문자
    case response(status: Int, headers: [String: String], body: Data)
    /// 연결 실패·타임아웃 등
    case networkError
    /// 다른 호스트(또는 피드가 아닌 주소)로 리디렉트 → 중단
    case redirectRejected
    /// 응답이 5MB를 넘어 중단
    case tooLarge
    /// https가 아님 (저장 전 검증을 통과했으므로 보통 일어나지 않음)
    case notHTTPS
}

/// 동기화 간격·오류 상태 판정 (순수 함수, 테스트로 고정)
enum LmsSyncPolicy {
    /// 자동(앱 실행·잠자기 해제·패널 펼침): 마지막 시도 후 6시간
    static let automaticInterval: TimeInterval = 6 * 3600
    /// 수동(메뉴 "지금 새로고침"): 마지막 시도 후 5분
    static let manualInterval: TimeInterval = 5 * 60
    /// 429인데 `Retry-After`가 없을 때
    static let defaultRateLimitPause: TimeInterval = 24 * 3600
    /// 연속 429로 두 배씩 늘어나는 멈춤 시간의 상한 (7일)
    static let maxRateLimitPause: TimeInterval = 7 * 24 * 3600
    /// 마지막 시도 시각이 이보다 더 미래면(시계를 뒤로 돌림) 기록이 틀린 것으로 보고 무시
    static let clockSkewTolerance: TimeInterval = 60

    enum Decision: Equatable {
        case proceed
        /// 간격 제한 (자동 6시간 / 수동 5분)
        case skipTooSoon(availableAt: Date)
        /// 429 멈춤 중
        case skipRateLimited(until: Date)
    }

    static func decide(manual: Bool, now: Date, record: LmsSyncRecord) -> Decision {
        if let until = record.rateLimitedUntil, now < until {
            return .skipRateLimited(until: until)
        }
        if let last = record.lastAttemptAt, last <= now.addingTimeInterval(clockSkewTolerance) {
            let next = last.addingTimeInterval(manual ? manualInterval : automaticInterval)
            if now < next { return .skipTooSoon(availableAt: next) }
        }
        return .proceed
    }

    /// 요청 결과를 해석한 것
    enum Evaluation: Equatable {
        /// 200: 새 내용 (본문은 파싱 단계로)
        case fresh(body: Data, etag: String?, lastModified: String?)
        /// 304: 바뀐 것 없음, 캐시 유지
        case notModified
        case failed(LmsSyncStatus)
        /// 429. `Retry-After` 초 (없으면 nil)
        case rateLimited(retryAfter: TimeInterval?)
    }

    /// 응답 → 해석. 401·403·404·410 → disconnected, 5xx·네트워크 → offline, 429 → rateLimited,
    /// 리디렉트 거부·크기 초과·https 아님·그 밖의 상태 → invalidFeed
    static func evaluate(_ outcome: FeedFetchOutcome, now: Date) -> Evaluation {
        switch outcome {
        case .networkError:
            return .failed(.offline)
        case .redirectRejected, .tooLarge, .notHTTPS:
            return .failed(.invalidFeed)
        case let .response(status, headers, body):
            switch status {
            case 200:
                return .fresh(body: body, etag: headers["etag"], lastModified: headers["last-modified"])
            case 304:
                return .notModified
            case 401, 403, 404, 410:
                return .failed(.disconnected)
            case 429:
                return .rateLimited(retryAfter: headers["retry-after"].flatMap { parseRetryAfter($0, now: now) })
            case 500...599:
                return .failed(.offline)
            default:
                return .failed(.invalidFeed)
            }
        }
    }

    /// `Retry-After`: 초(정수) 또는 HTTP 날짜. 이미 지난 날짜·음수는 nil(→ 기본 24시간)
    static func parseRetryAfter(_ value: String, now: Date) -> TimeInterval? {
        let v = value.trimmingCharacters(in: .whitespaces)
        if let seconds = Int(v) { return seconds > 0 ? TimeInterval(seconds) : nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = f.date(from: v) else { return nil }
        let delta = date.timeIntervalSince(now)
        return delta > 0 ? delta : nil
    }

    /// 429 멈춤 시간: 기본(`Retry-After` 또는 24시간) × 2^(연속 횟수 − 1).
    /// 두 배로 늘리는 것은 7일까지만. 단 서버가 `Retry-After`로 그보다 길게 요구하면 그 값을 따른다
    static func rateLimitPause(retryAfter: TimeInterval?, consecutive: Int) -> TimeInterval {
        let base = retryAfter ?? defaultRateLimitPause
        let exponent = max(0, min(consecutive - 1, 16))
        return max(base, min(maxRateLimitPause, base * pow(2, Double(exponent))))
    }

    /// 시도 시작 시 기록 (실패해도 시도로 계산)
    static func recordingAttempt(_ record: LmsSyncRecord, now: Date) -> LmsSyncRecord {
        var r = record
        r.lastAttemptAt = now
        return r
    }

    /// 결과를 기록에 반영. `parseSucceeded`는 `.fresh`일 때 파싱 성공 여부
    static func recording(_ evaluation: Evaluation, parseSucceeded: Bool, into record: LmsSyncRecord, now: Date) -> LmsSyncRecord {
        var r = record
        switch evaluation {
        case let .fresh(_, etag, lastModified):
            r.consecutiveRateLimits = 0
            r.rateLimitedUntil = nil
            if parseSucceeded {
                r.status = .ok
                r.lastSuccessAt = now
                r.etag = etag
                r.lastModified = lastModified
            } else {
                r.status = .invalidFeed
            }
        case .notModified:
            r.consecutiveRateLimits = 0
            r.rateLimitedUntil = nil
            r.status = .ok
            r.lastSuccessAt = now
        case .failed(let status):
            r.consecutiveRateLimits = 0
            r.rateLimitedUntil = nil
            r.status = status
        case .rateLimited(let retryAfter):
            r.consecutiveRateLimits += 1
            r.status = .rateLimited
            r.rateLimitedUntil = now.addingTimeInterval(rateLimitPause(retryAfter: retryAfter, consecutive: r.consecutiveRateLimits))
        }
        return r
    }
}

// MARK: - 화면 문구

extension LmsDisplay {
    /// 패널 LMS 칸의 오류 문구 (PRD F11). 형식 오류(invalidFeed)는 설정 창에만 표시하므로 nil
    static func panelMessage(record: LmsSyncRecord, now: Date) -> String? {
        switch record.status {
        case .disconnected:
            return "연결이 끊겼어요 · 설정에서 피드 주소 다시 넣기"
        case .offline:
            return "마지막 동기화: \(relative(record.lastSuccessAt, now: now))"
        case .rateLimited:
            guard let until = record.rateLimitedUntil, until > now else { return nil }
            return "LMS가 잠시 쉬어 달래요 · \(hoursLeft(until, now: now))시간 뒤 다시 시도"
        case .never, .ok, .invalidFeed:
            return nil
        }
    }

    /// 남은 시간 (시간 단위, 올림, 최소 1)
    static func hoursLeft(_ until: Date, now: Date) -> Int {
        max(1, Int((until.timeIntervalSince(now) / 3600).rounded(.up)))
    }

    /// `방금 전` / `n분 전` / `n시간 전` / `n일 전` / `없음`
    static func relative(_ date: Date?, now: Date) -> String {
        guard let date else { return "없음" }
        let s = max(0, now.timeIntervalSince(date))
        if s < 60 { return "방금 전" }
        if s < 3600 { return "\(Int(s / 60))분 전" }
        if s < 86400 { return "\(Int(s / 3600))시간 전" }
        return "\(Int(s / 86400))일 전"
    }

    /// 설정 창 상태 문구
    static func settingsStatus(record: LmsSyncRecord, now: Date) -> String {
        switch record.status {
        case .never: return "아직 동기화하지 않았어요"
        case .ok: return "정상"
        case .disconnected: return "연결이 끊겼어요 (주소가 무효예요). 피드 주소를 다시 넣어 주세요"
        case .offline: return "접속하지 못했어요 (네트워크 또는 LMS 서버 오류). 마지막으로 받은 목록을 보여 줘요"
        case .invalidFeed: return "피드 형식 오류 (캘린더 파일이 아니거나, 너무 크거나, 다른 주소로 넘어가려 했어요). 기존 목록은 그대로예요"
        case .rateLimited:
            if let until = record.rateLimitedUntil, until > now {
                return "LMS가 잠시 쉬어 달래요 · \(hoursLeft(until, now: now))시간 뒤 다시 시도"
            }
            return "LMS가 잠시 쉬어 달라고 했어요 (멈춤 시간이 지나 다시 시도할 수 있어요)"
        }
    }
}
