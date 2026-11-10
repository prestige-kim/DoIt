import Foundation
import CoreFoundation

/// 번들 설정만 읽는다. 정식 빌드는 실행 인자·환경·defaults로 로컬 시험을 켤 수 없다.
struct UpdateConfiguration {
    let feedURL: URL?
    let isValidation: Bool
    let isReady: Bool

    static var current: Self {
        #if UPDATE_VALIDATION
        return Self(info: Bundle.main.infoDictionary ?? [:], permitsLocal: true)
        #else
        return Self(info: Bundle.main.infoDictionary ?? [:], permitsLocal: false)
        #endif
    }

    init(info: [String: Any], permitsLocal: Bool = false) {
        let validationFlag = Self.bundleBool(info["DoItUpdateValidation"])
        let validation = validationFlag == true
        isValidation = validation
        let text = info["SUFeedURL"] as? String ?? ""
        let key = info["SUPublicEDKey"] as? String ?? ""
        let validKey = Data(base64Encoded: key).map {
            $0.count == 32 && $0.contains(where: { $0 != 0 }) && $0.base64EncodedString() == key
        } ?? false
        let url = URL(string: text)
        feedURL = url
        let common = !text.isEmpty && !text.contains(where: { $0.isWhitespace }) &&
            !text.contains("$(") && url?.user == nil && url?.password == nil &&
            url?.query == nil && url?.fragment == nil && url?.path.hasSuffix(".xml") == true
        let transport: Bool
        if validation {
            transport = permitsLocal && url?.scheme == "http" && url?.host == "127.0.0.1" && url?.port == 8765
        } else {
            let host = url?.host?.lowercased() ?? ""
            transport = url?.scheme == "https" && !host.isEmpty && host.contains(".") &&
                !host.hasSuffix(".invalid") && !host.hasSuffix(".localhost") && !host.hasSuffix(".local") &&
                host != "localhost" && !host.contains(":") &&
                host.range(of: #"^[0-9.]+$"#, options: .regularExpression) == nil &&
                (url?.port == nil || url?.port == 443)
        }
        let enabled = validation ? permitsLocal : Self.bundleBool(info["DoItDistributionEnabled"]) == true
        isReady = validationFlag != nil && enabled && validKey && common && transport
    }

    // NSNumber의 1이나 문자열 true는 plist bool로 인정하지 않는다.
    private static func bundleBool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    func allowsDownload(_ url: URL?) -> Bool {
        guard isReady, let url, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return false }
        if isValidation {
            return url.scheme == "http" && url.host == "127.0.0.1" && url.port == 8765 && url.path.hasSuffix(".zip")
        }
        // Pages의 소유자·저장소와 같은 GitHub Releases만 허용한다.
        guard let feedURL, let host = feedURL.host, host.hasSuffix(".github.io"),
              url.scheme == "https", url.host == "github.com", url.port == nil,
              let repository = feedURL.path.split(separator: "/").first else { return false }
        let owner = String(host.dropLast(".github.io".count))
        return url.path.hasPrefix("/\(owner)/\(repository)/releases/download/") && url.path.hasSuffix(".zip")
    }
}
