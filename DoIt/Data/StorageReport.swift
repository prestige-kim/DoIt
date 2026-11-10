import Foundation
import Darwin

/// 저장 공간 표시 (PRD F14, ARCHITECTURE §3.9). 설정 창을 열 때·`새로 계산`을 누를 때만 만든다
struct StorageReport: Equatable {
    struct FileEntry: Equatable, Identifiable {
        let name: String
        /// 파일이 없으면 nil
        let bytes: Int64?
        /// 항목 수 (archive는 파일 수)
        let count: Int
        let countUnit: String
        var id: String { name }
    }

    let files: [FileEntry]
    let archive: FileEntry
    let totalBytes: Int64
    let cleanupCount: Int
    /// DoIt 메모리 사용량 (phys_footprint, 활동 모니터의 "메모리"와 같은 기준). 읽지 못하면 nil
    let memoryBytes: UInt64?

    struct Counts {
        var todos = 0
        var lmsItems = 0
        var lmsHistory = 0
        var lmsChecks = 0
        var cleanup = 0
    }

    static func make(directory: URL, archiveDirectory: URL, counts: Counts,
                     memory: UInt64? = StorageReport.memoryFootprint()) -> StorageReport {
        func size(_ name: String) -> Int64? {
            let attrs = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
            return (attrs?[.size] as? NSNumber)?.int64Value
        }
        let files = [
            FileEntry(name: "todos.json", bytes: size("todos.json"), count: counts.todos, countUnit: "개"),
            FileEntry(name: "lms.json", bytes: size("lms.json"), count: counts.lmsItems, countUnit: "개"),
            FileEntry(name: "lms-history.json", bytes: size("lms-history.json"), count: counts.lmsHistory, countUnit: "개"),
            FileEntry(name: "lms-state.json", bytes: size("lms-state.json"), count: counts.lmsChecks, countUnit: "개"),
        ]
        let (archiveBytes, archiveFiles) = folderSize(archiveDirectory)
        let archive = FileEntry(name: "archive/", bytes: archiveFiles > 0 ? archiveBytes : nil, count: archiveFiles, countUnit: "파일")
        let total = files.compactMap(\.bytes).reduce(0, +) + archiveBytes
        return StorageReport(files: files, archive: archive, totalBytes: total, cleanupCount: counts.cleanup, memoryBytes: memory)
    }

    /// 폴더 안 파일 크기 합과 파일 수 (하위 폴더 포함)
    static func folderSize(_ url: URL) -> (Int64, Int) {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return (0, 0) }
        var bytes: Int64 = 0
        var files = 0
        for case let file as URL in e {
            let v = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard v?.isRegularFile == true else { continue }
            bytes += Int64(v?.fileSize ?? 0)
            files += 1
        }
        return (bytes, files)
    }

    /// `task_info(TASK_VM_INFO)`의 phys_footprint
    static func memoryFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : nil
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
