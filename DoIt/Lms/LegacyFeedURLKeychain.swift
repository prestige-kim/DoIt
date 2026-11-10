import Foundation
import Security
import os

private let migrationLogger = Logger(subsystem: "com.personal.doit", category: "lms")

/// 예전 키체인 항목이 있는지 (데이터 없이 속성만 확인한 결과)
enum LegacyFeedURLPresence: Equatable {
    case absent
    case present
    case failed(OSStatus)
}

/// T-010까지 키체인에 저장했던 피드 주소 (이전용 읽기·삭제만. 저장 기능 없음)
protocol LegacyFeedURLSource {
    /// 항목이 있는지만 확인 (주소 데이터는 요청하지 않음)
    func presence() -> LegacyFeedURLPresence
    /// 주소를 1번 읽는다. 항목이 없거나 내용이 피드 주소가 아니면 nil, 읽기 실패·취소는 오류
    func read() throws -> URL?
    /// 항목 삭제. 상태 코드를 돌려준다 (없으면 errSecItemNotFound)
    @discardableResult func delete() -> OSStatus
}

/// 예전 키체인 항목 (`kSecClassGenericPassword`, service `com.personal.doit.lms-feed`) — D-018 이전용
/// 주소는 로그에 남기지 않는다 (OSStatus 숫자만)
struct LegacyFeedURLKeychain: LegacyFeedURLSource {
    static let service = "com.personal.doit.lms-feed"
    static let account = "calendar-feed"

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: Self.account]
    }

    func presence() -> LegacyFeedURLPresence {
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return .present
        case errSecItemNotFound: return .absent
        default:
            migrationLogger.error("legacy keychain check failed: \(status, privacy: .public)")
            return .failed(status)
        }
    }

    func read() throws -> URL? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let text = String(data: data, encoding: .utf8) else {
            migrationLogger.error("legacy keychain read failed: \(status, privacy: .public)")
            throw FeedURLError.storageFailed(status)
        }
        guard case .success(let url) = FeedURLValidator.validate(text) else {
            migrationLogger.error("legacy keychain item is not a valid feed URL")
            return nil
        }
        return url
    }

    @discardableResult
    func delete() -> OSStatus {
        let status = SecItemDelete(baseQuery as CFDictionary)
        migrationLogger.info("legacy keychain delete: \(status, privacy: .public)")
        return status
    }
}

/// 앱이 쓰는 피드 주소 저장소: 파일 저장소 + 예전 키체인 이전 (ARCHITECTURE §3.8, D-018)
/// - `load()`: 파일이 있으면 파일만 읽는다(키체인을 건드리지 않음 → 업데이트 후 암호 창 0번).
///   파일이 없을 때만 키체인 항목 존재를 속성만으로 확인하고, 있으면 1번 읽어 파일에 쓴 뒤 **파일 쓰기가 성공했을 때만** 키체인 항목을 지운다
/// - `save()`: 파일에만. `delete()`(연결 해제): 파일 + 남아 있을지 모르는 키체인 항목 둘 다
struct MigratingFeedURLStore: FeedURLStoring {
    let file: FeedURLFileStoring
    let legacy: LegacyFeedURLSource

    init(file: FeedURLFileStoring = FeedURLFileStore(), legacy: LegacyFeedURLSource = LegacyFeedURLKeychain()) {
        self.file = file
        self.legacy = legacy
    }

    func save(_ url: URL) throws {
        try file.save(url)
    }

    func load() throws -> URL? {
        if file.exists() {
            return try file.load()
        }
        switch legacy.presence() {
        case .absent:
            return nil
        case .failed(let status):
            throw FeedURLError.storageFailed(status)
        case .present:
            break
        }
        // 읽기 실패·취소는 오류로 올라가고 파일도 만들지 않는다 → 키체인 그대로, 다음 동기화 때 다시 시도
        guard let url = try legacy.read() else {
            migrationLogger.error("feed url migration: legacy item unusable, left as is")
            return nil
        }
        do {
            try file.save(url)
        } catch {
            migrationLogger.error("feed url migration: file write failed, keychain kept")
            throw error
        }
        let status = legacy.delete()
        if status == errSecSuccess {
            migrationLogger.notice("feed url migrated from keychain to file")
        } else {
            migrationLogger.error("feed url migrated to file, but keychain delete failed: \(status, privacy: .public)")
        }
        return url
    }

    func delete() {
        file.delete()
        legacy.delete()
    }
}
