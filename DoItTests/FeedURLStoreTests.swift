import XCTest
import Darwin
@testable import DoIt

/// 가짜 예전 키체인 (실제 키체인을 건드리지 않는다). 호출 횟수를 센다
final class FakeLegacyFeedURL: LegacyFeedURLSource {
    var item: URL?
    /// 설정하면 읽기가 이 상태 코드로 실패 (예: 사용자가 암호 창을 취소)
    var readFailure: OSStatus?
    /// 설정하면 삭제가 이 상태 코드로 실패
    var deleteFailure: OSStatus?
    var presenceCalls = 0
    var readCalls = 0
    var deleteCalls = 0
    var totalCalls: Int { presenceCalls + readCalls + deleteCalls }

    func presence() -> LegacyFeedURLPresence {
        presenceCalls += 1
        return item == nil ? .absent : .present
    }

    func read() throws -> URL? {
        readCalls += 1
        if let readFailure { throw FeedURLError.storageFailed(readFailure) }
        return item
    }

    func delete() -> OSStatus {
        deleteCalls += 1
        if let deleteFailure { return deleteFailure }
        let had = item != nil
        item = nil
        return had ? errSecSuccess : errSecItemNotFound
    }
}

/// T-013: 피드 주소 파일 저장소 + 키체인 → 파일 이전 (임시 폴더만 사용)
@MainActor
final class FeedURLStoreTests: XCTestCase {
    private var base: URL!
    /// `…/DoIt` 역할의 폴더 (처음에는 없음)
    private var folder: URL!
    private let fakeFeed = URL(string: "https://lms.example.invalid/feeds/calendars/user_FAKE.ics")!
    private let otherFeed = URL(string: "https://lms.example.invalid/feeds/calendars/user_OTHER.ics")!

    override func setUp() {
        super.setUp()
        base = FileManager.default.temporaryDirectory.appendingPathComponent("DoItFeedTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        folder = base.appendingPathComponent("DoIt", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
        super.tearDown()
    }

    private func makeFileStore() -> FeedURLFileStore { FeedURLFileStore(directory: folder) }

    private func mode(_ url: URL) throws -> mode_t {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return st.st_mode & 0o777
    }

    private func isExcludedFromBackup(_ url: URL) throws -> Bool {
        var fresh = URL(fileURLWithPath: url.path)
        fresh.removeAllCachedResourceValues()
        return try XCTUnwrap(fresh.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup)
    }

    // MARK: 파일 저장소

    func testSaveCreates600File700FolderExcludedFromBackup() throws {
        let store = makeFileStore()
        XCTAssertFalse(store.exists())
        try store.save(fakeFeed)
        XCTAssertTrue(store.exists())
        XCTAssertEqual(try mode(store.fileURL), 0o600)
        XCTAssertEqual(try mode(folder), 0o700)
        XCTAssertTrue(try isExcludedFromBackup(store.fileURL))
        XCTAssertEqual(try store.load(), fakeFeed)
        // 주소 문자열만 들어 있음 (가짜 주소라 내용 비교 가능)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), Data(fakeFeed.absoluteString.utf8))
        // 임시 파일이 남지 않음
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [FeedURLFileStore.fileName])
    }

    func testOverwriteKeeps600AndBackupExclusion() throws {
        let store = makeFileStore()
        try store.save(fakeFeed)
        try store.save(otherFeed)
        XCTAssertEqual(try store.load(), otherFeed)
        XCTAssertEqual(try mode(store.fileURL), 0o600)
        XCTAssertTrue(try isExcludedFromBackup(store.fileURL), "rename으로 새 파일이 돼도 제외 유지")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [FeedURLFileStore.fileName])
    }

    func testWideFolderTightenedTo700WithoutTouchingOtherFiles() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        chmod(folder.path, 0o755)
        let other = folder.appendingPathComponent("todos.json")
        try Data("[]".utf8).write(to: other)
        chmod(other.path, 0o644)
        try makeFileStore().save(fakeFeed)
        XCTAssertEqual(try mode(folder), 0o700)
        XCTAssertEqual(try mode(other), 0o644, "다른 데이터 파일은 그대로")
        XCTAssertEqual(try Data(contentsOf: other), Data("[]".utf8))
    }

    func testWideFileTightenedTo600OnLoad() throws {
        let store = makeFileStore()
        try store.save(fakeFeed)
        XCTAssertEqual(chmod(store.fileURL.path, 0o644), 0)
        XCTAssertEqual(try store.load(), fakeFeed)
        XCTAssertEqual(try mode(store.fileURL), 0o600)
    }

    func testSymlinkRejected() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        chmod(folder.path, 0o700)
        let target = base.appendingPathComponent("elsewhere")
        try Data(fakeFeed.absoluteString.utf8).write(to: target)
        let store = makeFileStore()
        try FileManager.default.createSymbolicLink(at: store.fileURL, withDestinationURL: target)
        XCTAssertTrue(store.exists())
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? FeedURLError, .storageFailed(ELOOP))
        }
        // 저장하면 링크 자체가 일반 파일로 바뀌고, 링크 대상은 건드리지 않는다
        try store.save(otherFeed)
        XCTAssertEqual(try store.load(), otherFeed)
        XCTAssertEqual(try Data(contentsOf: target), Data(fakeFeed.absoluteString.utf8))
    }

    func testDirectoryInPlaceOfFileRejected() throws {
        let store = makeFileStore()
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.load())
    }

    func testInvalidContentReturnsNil() throws {
        let store = makeFileStore()
        try store.save(fakeFeed)
        for text in ["not a url", "https://lms.example.invalid/courses/1", "", "http://lms.example.invalid/feeds/calendars/x.ics"] {
            try Data(text.utf8).write(to: store.fileURL)
            chmod(store.fileURL.path, 0o600)
            XCTAssertNil(try store.load(), text)
        }
        try Data([0xFF, 0xFE, 0x00]).write(to: store.fileURL)
        XCTAssertNil(try store.load(), "UTF-8 아님")
    }

    func testLoadMissingFileIsNil() throws {
        XCTAssertNil(try makeFileStore().load())
    }

    func testDeleteRemovesFileAndMissingIsQuiet() throws {
        let store = makeFileStore()
        try store.save(fakeFeed)
        store.delete()
        XCTAssertFalse(store.exists())
        store.delete()  // 없어도 조용히
        XCTAssertNil(try store.load())
    }

    func testSaveFailureLeavesNoFile() throws {
        // 폴더 자리에 일반 파일 → 폴더를 만들 수 없음
        try Data("x".utf8).write(to: folder)
        let store = makeFileStore()
        XCTAssertThrowsError(try store.save(fakeFeed)) { error in
            guard case .storageFailed = error as? FeedURLError else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(store.exists())
    }

    // MARK: 키체인 → 파일 이전

    private func makeMigrating(_ legacy: FakeLegacyFeedURL) -> MigratingFeedURLStore {
        MigratingFeedURLStore(file: makeFileStore(), legacy: legacy)
    }

    func testFileExistsDoesNotTouchKeychain() throws {
        try makeFileStore().save(fakeFeed)
        let legacy = FakeLegacyFeedURL()
        legacy.item = otherFeed
        let store = makeMigrating(legacy)
        XCTAssertEqual(try store.load(), fakeFeed)
        XCTAssertEqual(legacy.totalCalls, 0, "파일이 있으면 키체인 호출 0번")
        XCTAssertEqual(legacy.item, otherFeed)
    }

    func testInvalidFileStillDoesNotTouchKeychain() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: makeFileStore().fileURL)
        let legacy = FakeLegacyFeedURL()
        legacy.item = otherFeed
        XCTAssertNil(try makeMigrating(legacy).load())
        XCTAssertEqual(legacy.totalCalls, 0)
    }

    func testNoFileNoKeychainReturnsNilWithoutRead() throws {
        let legacy = FakeLegacyFeedURL()
        XCTAssertNil(try makeMigrating(legacy).load())
        XCTAssertEqual(legacy.presenceCalls, 1)
        XCTAssertEqual(legacy.readCalls, 0, "학생: 데이터 읽기 없음")
        XCTAssertEqual(legacy.deleteCalls, 0)
        XCTAssertFalse(makeFileStore().exists())
    }

    func testMigratesKeychainToFileThenDeletesKeychain() throws {
        let legacy = FakeLegacyFeedURL()
        legacy.item = fakeFeed
        let store = makeMigrating(legacy)
        XCTAssertEqual(try store.load(), fakeFeed)
        XCTAssertEqual(legacy.readCalls, 1)
        XCTAssertEqual(legacy.deleteCalls, 1)
        XCTAssertNil(legacy.item)
        XCTAssertEqual(try makeFileStore().load(), fakeFeed)
        XCTAssertEqual(try mode(makeFileStore().fileURL), 0o600)

        // 다음부터는 파일만
        XCTAssertEqual(try store.load(), fakeFeed)
        XCTAssertEqual(legacy.totalCalls, 3, "이전 이후 키체인 호출 없음")
    }

    func testKeychainReadFailureKeepsKeychainAndCreatesNoFile() throws {
        let legacy = FakeLegacyFeedURL()
        legacy.item = fakeFeed
        legacy.readFailure = errSecUserCanceled
        let store = makeMigrating(legacy)
        XCTAssertThrowsError(try store.load())
        XCTAssertFalse(makeFileStore().exists())
        XCTAssertEqual(legacy.deleteCalls, 0)
        XCTAssertEqual(legacy.item, fakeFeed)

        // 다음 동기화 때 다시 시도
        legacy.readFailure = nil
        XCTAssertEqual(try store.load(), fakeFeed)
        XCTAssertNil(legacy.item)
    }

    func testFileWriteFailureDoesNotDeleteKeychain() throws {
        try Data("x".utf8).write(to: folder)  // 폴더를 만들 수 없게
        let legacy = FakeLegacyFeedURL()
        legacy.item = fakeFeed
        XCTAssertThrowsError(try makeMigrating(legacy).load())
        XCTAssertEqual(legacy.readCalls, 1)
        XCTAssertEqual(legacy.deleteCalls, 0, "파일 저장이 실패하면 키체인 삭제 안 함")
        XCTAssertEqual(legacy.item, fakeFeed)
    }

    func testKeychainDeleteFailureStillWorksFromFile() throws {
        let legacy = FakeLegacyFeedURL()
        legacy.item = fakeFeed
        legacy.deleteFailure = errSecAuthFailed
        let store = makeMigrating(legacy)
        XCTAssertEqual(try store.load(), fakeFeed)
        XCTAssertEqual(legacy.deleteCalls, 1)
        XCTAssertTrue(makeFileStore().exists())
        let before = legacy.totalCalls
        XCTAssertEqual(try store.load(), fakeFeed)
        XCTAssertEqual(legacy.totalCalls, before, "파일로 정상 동작, 키체인 다시 안 건드림")
    }

    func testSaveWritesFileOnly() throws {
        let legacy = FakeLegacyFeedURL()
        try makeMigrating(legacy).save(fakeFeed)
        XCTAssertEqual(legacy.totalCalls, 0)
        XCTAssertEqual(try makeFileStore().load(), fakeFeed)
    }

    func testDeleteRemovesFileAndKeychain() throws {
        let legacy = FakeLegacyFeedURL()
        legacy.item = otherFeed
        let store = makeMigrating(legacy)
        try store.save(fakeFeed)
        store.delete()
        XCTAssertFalse(makeFileStore().exists())
        XCTAssertEqual(legacy.deleteCalls, 1, "남아 있을지 모르는 키체인 항목도 삭제 요청")
        XCTAssertNil(legacy.item)
    }

    func testServiceDisconnectDeletesFileAndKeychain() throws {
        let suite = "DoItFeedTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = FakeLegacyFeedURL()
        let lmsStore = LmsStore(directory: base.appendingPathComponent("lms"), defaults: defaults)
        let service = LmsSyncService(store: lmsStore, feedURLStore: makeMigrating(legacy), fetcher: FakeFetcher())
        XCTAssertNil(service.saveFeedURL(fakeFeed.absoluteString))  // 연동이 꺼져 있어 동기화는 하지 않음
        XCTAssertTrue(makeFileStore().exists())
        service.disconnect()
        XCTAssertFalse(makeFileStore().exists())
        XCTAssertEqual(legacy.deleteCalls, 1)
        XCTAssertNil(lmsStore.maskedFeedURL)
    }

    // MARK: 다루지 않음 보장

    func testStorageReportIgnoresFeedFile() throws {
        try makeFileStore().save(fakeFeed)
        try Data(repeating: 0x20, count: 100).write(to: folder.appendingPathComponent("todos.json"))
        let report = StorageReport.make(directory: folder, archiveDirectory: folder.appendingPathComponent("archive"),
                                        counts: .init(todos: 1), memory: 1)
        XCTAssertEqual(report.files.map(\.name), ["todos.json", "lms.json", "lms-history.json", "lms-state.json"])
        XCTAssertFalse(report.files.contains { $0.name == FeedURLFileStore.fileName })
        XCTAssertEqual(report.totalBytes, 100, "주소 파일 크기는 합계에 들어가지 않음")
    }

    func testErrorMessageIsStorageNeutral() {
        XCTAssertEqual(FeedURLError.storageFailed(13).message, "피드 주소를 저장하지 못했어요 (오류 13)")
    }
}
