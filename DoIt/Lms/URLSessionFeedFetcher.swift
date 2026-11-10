import Foundation

/// 실제 네트워크로 피드 1개를 GET 한다. **앱에서 `URLSession`을 만드는 곳은 여기 한 곳뿐이다.** (ARCHITECTURE §3.8)
/// - `URLSessionConfiguration.ephemeral`: 쿠키 저장소·디스크 캐시·자격 증명 저장 없음
/// - HTTPS만, 리디렉트는 같은 호스트의 피드 주소 형식일 때만 따라감
/// - 응답 5MB 상한 (넘으면 중단), 타임아웃 15초
/// - 요청은 1개씩 (서비스가 진행 중이면 새로 부르지 않음)
final class URLSessionFeedFetcher: NSObject, FeedFetching, URLSessionDataDelegate, @unchecked Sendable {
    static let maxBytes = 5 * 1024 * 1024
    static let timeout: TimeInterval = 15

    /// 델리게이트 콜백과 상태 접근을 이 직렬 큐에서만 한다
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "com.personal.doit.lms-fetch"
        return q
    }()

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = Self.timeout
        config.timeoutIntervalForResource = Self.timeout * 2
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 1
        config.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        return URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }()

    /// `DoIt/<버전> (personal calendar subscription)` — 개인정보 없음
    static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return "DoIt/\(version) (personal calendar subscription)"
    }

    // MARK: 진행 중인 요청 (queue에서만 접근)

    private final class InFlight {
        let original: URL
        let continuation: CheckedContinuation<FeedFetchOutcome, Never>
        var data = Data()
        var response: HTTPURLResponse?
        var redirectRejected = false
        var tooLarge = false
        init(original: URL, continuation: CheckedContinuation<FeedFetchOutcome, Never>) {
            self.original = original
            self.continuation = continuation
        }
    }
    private var inFlight: [Int: InFlight] = [:]

    /// 실제로 보내는 요청. **항상 GET, 본문 없음, 쿠키 없음** — LMS에 무엇도 보내거나 바꾸지 않는다 (테스트로 고정)
    static func makeURLRequest(_ request: FeedRequest) -> URLRequest {
        var r = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        r.httpMethod = "GET"
        r.httpBody = nil
        r.httpShouldHandleCookies = false
        r.setValue("text/calendar", forHTTPHeaderField: "Accept")
        if let etag = request.etag { r.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lm = request.lastModified { r.setValue(lm, forHTTPHeaderField: "If-Modified-Since") }
        return r
    }

    func fetch(_ request: FeedRequest) async -> FeedFetchOutcome {
        guard request.url.scheme?.lowercased() == "https", request.url.host != nil else { return .notHTTPS }
        let urlRequest = Self.makeURLRequest(request)

        return await withCheckedContinuation { continuation in
            queue.addOperation { [self] in
                let task = session.dataTask(with: urlRequest)
                inFlight[task.taskIdentifier] = InFlight(original: request.url, continuation: continuation)
                task.resume()
            }
        }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let state = inFlight[task.taskIdentifier] else { return completionHandler(nil) }
        if let target = request.url, FeedURLValidator.isAllowedRedirect(from: state.original, to: target) {
            var next = request
            next.httpShouldHandleCookies = false
            completionHandler(next)
        } else {
            state.redirectRejected = true   // 다른 호스트·다른 페이지로는 가지 않는다
            completionHandler(nil)
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let state = inFlight[dataTask.taskIdentifier] else { return completionHandler(.cancel) }
        state.response = response as? HTTPURLResponse
        if response.expectedContentLength > Int64(Self.maxBytes) {
            state.tooLarge = true
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let state = inFlight[dataTask.taskIdentifier], !state.tooLarge else { return }
        if state.data.count + data.count > Self.maxBytes {
            state.tooLarge = true
            state.data = Data()
            dataTask.cancel()
            return
        }
        state.data.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let state = inFlight.removeValue(forKey: task.taskIdentifier) else { return }
        let outcome: FeedFetchOutcome
        if state.redirectRejected {
            outcome = .redirectRejected
        } else if state.tooLarge {
            outcome = .tooLarge
        } else if let response = state.response, error == nil {
            var headers: [String: String] = [:]
            for (k, v) in response.allHeaderFields {
                if let k = k as? String, let v = v as? String { headers[k.lowercased()] = v }
            }
            outcome = .response(status: response.statusCode, headers: headers, body: state.data)
        } else {
            outcome = .networkError
        }
        state.data = Data()
        state.continuation.resume(returning: outcome)
    }
}
