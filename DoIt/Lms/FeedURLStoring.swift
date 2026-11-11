import Foundation

/// 피드 주소 검증·저장 오류 (설정 창에 이유 표시)
enum FeedURLError: Error, Equatable {
    case empty
    case notURL
    case notHTTPS
    case notFeed
    /// 저장 방식과 무관한 저장·읽기 실패 (파일이면 errno, 키체인이면 OSStatus) (T-013)
    case storageFailed(Int32)

    var message: String {
        switch self {
        case .empty: return "주소를 넣어 주세요"
        case .notURL: return "주소 형식이 아니에요"
        case .notHTTPS: return "https:// 로 시작하는 주소만 쓸 수 있어요 (webcal:// 주소라면 앞부분을 https:// 로 바꿔 넣어 주세요)"
        case .notFeed: return "캘린더 피드 주소가 아니에요. LMS 캘린더의 '캘린더 피드'에서 받은 주소(…/feeds/calendars/….ics)를 넣어 주세요"
        case .storageFailed(let code): return "피드 주소를 저장하지 못했어요 (오류 \(code))"
        }
    }
}

/// 피드 주소 검증 (ARCHITECTURE §3.8): `https://` + 경로에 `/feeds/calendars/` + `.ics`로 끝남.
/// 일반 LMS 페이지 주소를 넣어 다른 페이지에 접속하는 일을 막는다.
enum FeedURLValidator {
    static let requiredPathPart = "/feeds/calendars/"

    static func validate(_ text: String) -> Result<URL, FeedURLError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard !trimmed.contains(where: { $0.isWhitespace }),
              let comps = URLComponents(string: trimmed), let scheme = comps.scheme else { return .failure(.notURL) }
        guard scheme.lowercased() == "https" else { return .failure(.notHTTPS) }
        guard let host = comps.host, !host.isEmpty, comps.user == nil, comps.password == nil else { return .failure(.notURL) }
        // `.ics`로 끝나야 하므로 쿼리(?…)·조각(#…)은 받지 않는다
        guard comps.query == nil, comps.fragment == nil,
              comps.path.contains(requiredPathPart),
              comps.path.lowercased().hasSuffix(".ics"),
              comps.path.count > requiredPathPart.count + 4 else { return .failure(.notFeed) }
        guard let url = comps.url else { return .failure(.notURL) }
        return .success(url)
    }

    /// 리디렉트를 따라가도 되는지: 같은 호스트 + https + 피드 주소 형식일 때만 (다른 LMS 페이지로 넘어가지 않게)
    static func isAllowedRedirect(from original: URL, to target: URL) -> Bool {
        guard let a = original.host?.lowercased(), let b = target.host?.lowercased(), a == b else { return false }
        guard case .success = validate(target.absoluteString) else { return false }
        return true
    }

    /// 화면용 가린 주소: `https://<호스트>/…/••••.ics`
    static func masked(_ url: URL) -> String {
        "https://\(url.host ?? "?")/…/••••.ics"
    }
}

/// 피드 주소 저장소 (테스트에서는 메모리 가짜로 바꾼다)
protocol FeedURLStoring {
    func save(_ url: URL) throws
    func load() throws -> URL?
    @discardableResult func delete() -> Bool
}
