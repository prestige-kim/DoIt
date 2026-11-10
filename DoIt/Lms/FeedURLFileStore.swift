import Foundation
import Darwin
import os

private let fileStoreLogger = Logger(subsystem: "com.personal.doit", category: "lms")

/// 이전기(`MigratingFeedURLStore`)가 쓰는 파일 저장소 기능
protocol FeedURLFileStoring: FeedURLStoring {
    /// 그 자리에 무언가 있는지 (내용은 읽지 않음). 있으면 키체인을 건드리지 않는다
    func exists() -> Bool
}

/// 피드 주소를 본인만 읽을 수 있는 파일 1개에 저장한다 (ARCHITECTURE §3.8, D-009·D-018, T-013)
/// - 위치: `~/Library/Application Support/DoIt/lms-feed-url` (주소 문자열 UTF-8만)
/// - 파일 600, 폴더 700. 쓰기는 처음부터 600으로 만든 임시 파일 → rename (권한이 넓은 순간이 없게)
/// - Time Machine 백업 제외 표시를 쓸 때마다 단다
/// - 읽을 때 심볼릭 링크·일반 파일이 아닌 것·다른 소유자는 거부, 600보다 넓으면 600으로 고친다
/// - 로그에는 단계 이름과 errno만 (주소·경로는 남기지 않음)
struct FeedURLFileStore: FeedURLFileStoring {
    static let fileName = "lms-feed-url"
    /// 피드 주소로는 넉넉한 크기. 이보다 크면 주소 파일이 아니라고 보고 읽지 않는다
    static let maxBytes = 8 * 1024

    /// `~/Library/Application Support/DoIt` (todos.json과 같은 폴더)
    static var defaultDirectory: URL { TodoStore.defaultFileURL.deletingLastPathComponent() }

    let directory: URL
    var fileURL: URL { directory.appendingPathComponent(Self.fileName, isDirectory: false) }

    init(directory: URL = FeedURLFileStore.defaultDirectory) {
        self.directory = directory
    }

    // MARK: 확인

    func exists() -> Bool {
        var st = stat()
        return lstat(fileURL.path, &st) == 0
    }

    // MARK: 쓰기

    func save(_ url: URL) throws {
        try checkDirectory(create: true)
        let data = Data(url.absoluteString.utf8)
        let tmp = directory.appendingPathComponent(".\(Self.fileName).tmp-\(UUID().uuidString)", isDirectory: false)

        // 처음부터 600으로 만든다 (umask는 좁히기만 하므로 이후 fchmod로 정확히 600)
        let fd = open(tmp.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw fail("create temp", errno) }
        var renamed = false
        defer { if !renamed { unlink(tmp.path) } }

        let writeError: Int32 = {
            if fchmod(fd, 0o600) != 0 { return errno }
            let e: Int32 = data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return 0 }
                var offset = 0
                while offset < raw.count {
                    let n = write(fd, base + offset, raw.count - offset)
                    if n < 0 {
                        if errno == EINTR { continue }
                        return errno
                    }
                    offset += n
                }
                return 0
            }
            if e != 0 { return e }
            return fsync(fd) == 0 ? 0 : errno
        }()
        let closeError: Int32 = close(fd) == 0 ? 0 : errno
        if writeError != 0 { throw fail("write temp", writeError) }
        if closeError != 0 { throw fail("close temp", closeError) }

        // rename 전에 임시 파일에 백업 제외 표시 → 최종 파일이 표시 없이 존재하는 순간이 없게
        try excludeFromBackup(tmp)
        guard rename(tmp.path, fileURL.path) == 0 else { throw fail("rename", errno) }
        renamed = true

        // rename으로 새 파일이 됐으므로 최종 파일의 표시를 매번 확인하고, 없으면 다시 단다
        var final = fileURL
        final.removeAllCachedResourceValues()
        if (try? final.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) != true {
            do {
                try excludeFromBackup(fileURL)
            } catch {
                // 파일은 이미 저장됨. 다음 저장 때 다시 시도
                fileStoreLogger.error("feed url file: backup exclusion not set after rename")
            }
        }
        fileStoreLogger.info("feed url file saved (host: \(url.host ?? "?", privacy: .public))")
    }

    // MARK: 읽기

    func load() throws -> URL? {
        let path = fileURL.path
        var st = stat()
        if lstat(path, &st) != 0 {
            let e = errno
            if e == ENOENT { return nil }
            throw fail("lstat", e)
        }
        let type = st.st_mode & S_IFMT
        guard type != S_IFLNK else { throw fail("symlink rejected", ELOOP) }
        guard type == S_IFREG else { throw fail("not a regular file", EFTYPE) }
        guard st.st_uid == getuid() else { throw fail("owner is not current user", EPERM) }
        try checkDirectory(create: false)

        // O_NOFOLLOW: lstat 뒤에 링크로 바뀌어도 따라가지 않음. O_NONBLOCK: 혹시 FIFO여도 멈추지 않음
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw fail("open", errno) }
        defer { close(fd) }
        var fst = stat()
        guard fstat(fd, &fst) == 0 else { throw fail("fstat", errno) }
        guard fst.st_mode & S_IFMT == S_IFREG, fst.st_uid == getuid(),
              fst.st_dev == st.st_dev, fst.st_ino == st.st_ino else { throw fail("file changed while opening", EAGAIN) }
        if fst.st_mode & 0o777 & ~0o600 != 0 {
            guard fchmod(fd, 0o600) == 0 else { throw fail("tighten file mode", errno) }
            fileStoreLogger.notice("feed url file: permissions tightened to 600")
        }
        guard fst.st_size > 0, fst.st_size <= Self.maxBytes else {
            fileStoreLogger.error("feed url file: unexpected size, ignored")
            return nil
        }

        var buffer = [UInt8](repeating: 0, count: Int(fst.st_size))
        var offset = 0
        while offset < buffer.count {
            let n = buffer.withUnsafeMutableBytes { raw in read(fd, raw.baseAddress! + offset, raw.count - offset) }
            if n < 0 {
                if errno == EINTR { continue }
                throw fail("read", errno)
            }
            if n == 0 { break }
            offset += n
        }
        guard let text = String(bytes: buffer[0..<offset], encoding: .utf8) else {
            fileStoreLogger.error("feed url file: not UTF-8, ignored")
            return nil
        }
        // 저장 후 손으로 바뀐 경우까지 대비해 읽을 때도 다시 검증
        guard case .success(let url) = FeedURLValidator.validate(text) else {
            fileStoreLogger.error("feed url file: not a valid feed URL, ignored")
            return nil
        }
        return url
    }

    // MARK: 삭제

    func delete() {
        if unlink(fileURL.path) == 0 {
            fileStoreLogger.info("feed url file deleted")
        } else if errno == ENOENT {
            fileStoreLogger.info("feed url file delete: nothing to delete")
        } else {
            fileStoreLogger.error("feed url file delete failed: errno \(errno, privacy: .public)")
        }
    }

    // MARK: 내부

    /// 폴더 `DoIt/`: 없으면(create일 때) 700으로 만들고, 넓으면 700으로 고친다. 폴더 안의 다른 파일은 건드리지 않는다
    private func checkDirectory(create: Bool) throws {
        let path = directory.path
        var st = stat()
        if lstat(path, &st) != 0 {
            let e = errno
            guard e == ENOENT, create else { throw fail("lstat dir", e) }
            try? FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
            if mkdir(path, 0o700) != 0, errno != EEXIST { throw fail("mkdir", errno) }
            guard lstat(path, &st) == 0 else { throw fail("lstat dir", errno) }
        }
        guard st.st_mode & S_IFMT == S_IFDIR else { throw fail("folder is not a directory", ENOTDIR) }
        guard st.st_uid == getuid() else { throw fail("folder owner is not current user", EPERM) }
        if st.st_mode & 0o077 != 0 {
            guard chmod(path, 0o700) == 0 else { throw fail("tighten folder mode", errno) }
            fileStoreLogger.notice("feed url folder: permissions tightened to 700")
        }
    }

    private func excludeFromBackup(_ url: URL) throws {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try target.setResourceValues(values)
        } catch {
            throw fail("exclude from backup", Int32(truncatingIfNeeded: (error as NSError).code))
        }
    }

    private func fail(_ step: StaticString, _ code: Int32) -> FeedURLError {
        fileStoreLogger.error("feed url file \(String(describing: step), privacy: .public) failed: \(code, privacy: .public)")
        return .storageFailed(code)
    }
}
