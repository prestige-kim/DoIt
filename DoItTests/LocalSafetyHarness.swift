#if LOCAL_SAFETY_HARNESS
import Foundation
import Security

final class MemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func object(forKey name: String) -> Any? { values[name] }
    override func set(_ value: Any?, forKey name: String) { values[name] = value }
    override func removeObject(forKey name: String) { values[name] = nil }
    override func bool(forKey name: String) -> Bool { values[name] as? Bool ?? false }
    override func integer(forKey name: String) -> Int { values[name] as? Int ?? 0 }
    override func string(forKey name: String) -> String? { values[name] as? String }
    override func data(forKey name: String) -> Data? { values[name] as? Data }
}
final class MemoryFeed: FeedURLFileStoring {
    var url: URL? = URL(string: "https://lms.example.invalid/feeds/calendars/fake.ics")!
    var failDelete = false
    func save(_ value: URL) throws { url = value }
    func load() throws -> URL? { url }
    func exists() -> Bool { url != nil }
    func delete() -> Bool { if failDelete { return false }; url = nil; return true }
}
struct FakeLegacyDelete: LegacyFeedURLSource {
    var status: OSStatus
    func presence() -> LegacyFeedURLPresence { .absent }
    func read() throws -> URL? { nil }
    func delete() -> OSStatus { status }
}
@MainActor final class HeldFetcher: FeedFetching {
    var requests: [FeedRequest] = []
    var continuations: [CheckedContinuation<FeedFetchOutcome, Never>] = []
    func fetch(_ request: FeedRequest) async -> FeedFetchOutcome {
        requests.append(request)
        return await withCheckedContinuation { continuations.append($0) }
    }
    func release(_ outcome: FeedFetchOutcome) { continuations.removeFirst().resume(returning: outcome) }
}
actor HeldParser {
    var started = false
    var continuation: CheckedContinuation<IcsParser.Result?, Never>?
    func parse() async -> IcsParser.Result? {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func release(_ result: IcsParser.Result) { continuation?.resume(returning: result); continuation = nil }
}
@main struct LocalSafetyHarness {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DoItSafety-" + UUID().uuidString, isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) {
            guard value() else { fatalError("FAIL: " + label) }
            count += 1
            print("PASS " + label)
        }
        let today = LocalDate(year: 2026, month: 11, day: 11)
        func item(_ uid: String, _ day: Int) -> LmsItem {
            LmsItem(uid: "event-assignment-" + uid, title: "fake " + uid, courseName: nil, dueDate: today.adding(days: day), dueTime: nil)
        }
        func lms(_ name: String) throws -> (LmsStore, MemoryDefaults) {
            let d = root.appendingPathComponent(name)
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            let defaults = MemoryDefaults()
            let store = LmsStore(directory: d, defaults: defaults)
            store.now = { Date(timeIntervalSince1970: 1_800_000_000) }
            store.load(today: today)
            return (store, defaults)
        }
        func cache(_ s: LmsStore) throws -> [LmsItem] {
            try TodoStore.makeDecoder().decode(LmsStore.CacheFile.self, from: Data(contentsOf: s.cacheURL)).items
        }
        let blocked = root.appendingPathComponent("blocker")
        try Data().write(to: blocked)
        let todos = TodoStore(fileURL: blocked.appendingPathComponent("todos.json"))
        todos.add(title: "fake todo", dueDate: today)
        check(!todos.flushPendingSave(), "todo write failure returned")
        check(todos.hasPendingSave && todos.saveError != nil && todos.todos.count == 1, "todo dirty retained")
        try fm.removeItem(at: blocked)
        check(todos.flushPendingSave(), "todo retry after repair")
        let reload = TodoStore(fileURL: todos.fileURL); reload.load()
        check(reload.todos.count == 1 && !todos.hasPendingSave, "todo reload retained")
        let done = todos.todos[0]; todos.toggleDone(id: done.id); check(todos.flushPendingSave(), "todo done saved")
        let persisted = try Data(contentsOf: todos.fileURL)
        try fm.removeItem(at: todos.fileURL); try fm.createDirectory(at: todos.fileURL, withIntermediateDirectories: false)
        check(todos.removeCompleted(ids: [done.id]).isEmpty && todos.todos.count == 1, "cleanup failure keeps todo")
        try fm.removeItem(at: todos.fileURL); try persisted.write(to: todos.fileURL)
        check(todos.flushPendingSave() && todos.saveError == nil, "cleanup error retry resolves")

        let (s, defaults) = try lms("history-failure")
        let old = item("old", -1)
        check(s.replaceItems(with: [old], today: today.adding(days: -2)), "seed cache before deadline")
        // Inject failure only AFTER load. No load/backup helper removes this obstacle.
        try fm.createDirectory(at: s.historyURL, withIntermediateDirectories: false)
        check(!s.archivePastItems(today: today), "history write failure returned")
        let kept = try cache(s)
        check(kept.map(\.uid) == [old.uid] && s.items.count == 1, "history failure leaves original cache")
        check(s.hasPendingSave && s.saveError != nil, "lms failed replacement retained")
        let extraPast = item("past-feed", -3)
        check(!s.replaceItems(with: [extraPast], today: today), "second failure held")
        check(!s.replaceItems(with: [item("new", 2)], today: today), "new response does not forget pending past")
        try fm.removeItem(at: s.historyURL)
        check(s.retryPendingSaves(), "history retry repaired")
        let reloaded = LmsStore(directory: s.cacheURL.deletingLastPathComponent(), defaults: defaults); reloaded.load(today: today)
        check(Set(reloaded.history.map(\.uid)) == [old.uid, extraPast.uid], "history survives reload after retries")

        let (partial, _) = try lms("cache-failure")
        check(partial.replaceItems(with: [old], today: today.adding(days: -2)), "partial seed")
        let cacheData = try Data(contentsOf: partial.cacheURL)
        try fm.removeItem(at: partial.cacheURL); try fm.createDirectory(at: partial.cacheURL, withIntermediateDirectories: false)
        check(!partial.archivePastItems(today: today), "cache failure after history success")
        let historyData = try TodoStore.makeDecoder().decode(LmsStore.HistoryFile.self, from: Data(contentsOf: partial.historyURL))
        check(historyData.items.map(\.uid) == [old.uid], "durable history precedes cache removal")
        try fm.removeItem(at: partial.cacheURL); try cacheData.write(to: partial.cacheURL)
        check(partial.retryPendingSaves(), "cache partial retry succeeds")
        partial.toggleCheck(uid: old.uid)
        let stateData = try Data(contentsOf: partial.stateURL)
        try fm.removeItem(at: partial.stateURL); try fm.createDirectory(at: partial.stateURL, withIntermediateDirectories: false)
        check(!partial.toggleCheck(uid: old.uid) && partial.hasPendingSave, "check failure retains dirty")
        try fm.removeItem(at: partial.stateURL); try stateData.write(to: partial.stateURL)
        check(partial.retryPendingSaves() && !partial.hasPendingSave, "check retry succeeds")

        func connected(_ name: String, parser: (@Sendable (Data, TimeZone) async -> IcsParser.Result?)? = nil) throws -> (LmsStore, MemoryDefaults, MemoryFeed, HeldFetcher, LmsSyncService) {
            let (s,d) = try lms(name); let f = MemoryFeed(); let fetch = HeldFetcher()
            s.isEnabled = true; s.feedURLSaved(masked: FeedURLValidator.masked(f.url!))
            let service: LmsSyncService
            if let parser { service = LmsSyncService(store:s, feedURLStore:f, fetcher:fetch, parse:parser) }
            else { service = LmsSyncService(store:s, feedURLStore:f, fetcher:fetch) }
            service.today = { today }
            return (s,d,f,fetch,service)
        }
        func wait(_ predicate: () -> Bool) async { for _ in 0..<10000 { if predicate() { return }; await Task.yield() }; fatalError("wait exceeded") }
        let body = Data("BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:event-assignment-old-feed\nSUMMARY:fake\nDTSTART;VALUE=DATE:20261112\nEND:VEVENT\nEND:VCALENDAR".utf8)
        let response = FeedFetchOutcome.response(status:200,headers:["etag":"FAKE-OLD"],body:body)
        let (ds,_,_,df,disconnect) = try connected("disconnect")
        let oldTask = disconnect.trigger(.manual)!
        await wait { df.requests.count == 1 }
        check(disconnect.disconnect(), "disconnect returns success")
        df.release(response); await oldTask.value
        check(ds.items.isEmpty && !fm.fileExists(atPath: ds.cacheURL.path) && ds.record.etag == nil, "late response cannot recreate cache")

        let (cs,_,_,cf,change) = try connected("change")
        let changeTask = change.trigger(.manual)!
        await wait { cf.requests.count == 1 }
        check(change.saveFeedURL("https://lms.example.invalid/feeds/calendars/new.ics") == nil, "new URL saved")
        check(cf.requests.count == 1 && cs.isSyncing, "new URL waits for old GET")
        cf.release(response); await changeTask.value
        await wait { cf.requests.count == 2 }
        check(cs.isSyncing && cs.record.etag == nil, "old response does not clear new progress or headers")
        cf.release(.response(status:304,headers:[:],body:Data()))
        await wait { !cs.isSyncing }
        check(cf.requests[1].url.path.hasSuffix("new.ics"), "queued request uses new URL")

        let gate = HeldParser()
        let (ps,_,_,pf,parsing) = try connected("parse", parser: { _,_ in await gate.parse() })
        let parseTask = parsing.trigger(.manual)!
        await wait { pf.requests.count == 1 }
        pf.release(response)
        while !(await gate.started) { await Task.yield() }
        check(parsing.disconnect(), "disconnect during detached parse")
        await gate.release(IcsParser.Result(items:[item("parsed",1)])); await parseTask.value
        check(ps.items.isEmpty && ps.record.etag == nil, "late parse ignored")

        let (fs,fd,feed,ff,failedDelete) = try connected("delete-failure")
        feed.failDelete = true
        check(!failedDelete.disconnect() && fs.isDisconnectPending && fs.hasFeedURL && !fs.isEnabled, "delete failure retained and stopped")
        fs.isEnabled = true
        check(failedDelete.trigger(.manual) == nil && ff.requests.isEmpty, "delete failure blocks every trigger")
        let reopened = LmsStore(directory:fs.cacheURL.deletingLastPathComponent(),defaults:fd)
        check(reopened.isDisconnectPending, "disconnect flag persists across recreation")
        feed.failDelete = false
        check(failedDelete.disconnect() && !fs.isDisconnectPending && !fs.hasFeedURL, "delete retry succeeds")
        // Old errors and rate limits must not overwrite a new connection either.
        for (name, stale) in [("old-error", FeedFetchOutcome.networkError),
                              ("old-429", .response(status:429,headers:["retry-after":"3600"],body:Data()))] {
            let (s,_,_,fetch,service) = try connected(name)
            let task = service.trigger(.manual)!
            await wait { fetch.requests.count == 1 }
            check(service.saveFeedURL("https://lms.example.invalid/feeds/calendars/new.ics") == nil, name + " new URL")
            fetch.release(stale); await task.value
            await wait { fetch.requests.count == 2 }
            check(s.record.rateLimitedUntil == nil && s.record.status == .never && s.isSyncing, name + " ignored")
            fetch.release(.response(status:304,headers:[:],body:Data()))
            await wait { !s.isSyncing }
        }
        let mf = MemoryFeed()
        let migrating = MigratingFeedURLStore(file:mf,legacy:FakeLegacyDelete(status:errSecAuthFailed))
        check(!migrating.delete(), "legacy deletion failure propagated")
        mf.failDelete = true
        check(!MigratingFeedURLStore(file:mf,legacy:FakeLegacyDelete(status:errSecItemNotFound)).delete(), "file deletion failure propagated")
        mf.failDelete = false
        check(MigratingFeedURLStore(file:mf,legacy:FakeLegacyDelete(status:errSecItemNotFound)).delete(), "absent legacy deletion succeeds")
        let actualFile = FeedURLFileStore(directory: root.appendingPathComponent("fake-feed-file"))
        try fm.createDirectory(at: actualFile.fileURL, withIntermediateDirectories: true)
        check(!actualFile.delete(), "unlink directory failure returned")
        try fm.removeItem(at: actualFile.fileURL)
        check(actualFile.delete(), "ENOENT deletion succeeds")
        let stoppedFetcher = HeldFetcher()
        let stopped = LmsSyncService(store:reopened,feedURLStore:feed,fetcher:stoppedFetcher)
        reopened.isEnabled = true
        check(stopped.trigger(.manual) == nil && stoppedFetcher.requests.isEmpty, "recreated pending disconnect cannot fetch")
        let (rateStore,_,_,rateFetch,rateService) = try connected("429-preserve")
        var rateRecord = LmsSyncRecord(); rateRecord.rateLimitedUntil = rateStore.now().addingTimeInterval(3600)
        rateStore.setRecord(rateRecord)
        check(rateService.saveFeedURL("https://lms.example.invalid/feeds/calendars/new.ics") == nil, "URL replacement while rate limited allowed")
        check(rateFetch.requests.isEmpty && rateStore.record.rateLimitedUntil == rateRecord.rateLimitedUntil, "existing 429 pause retained")
        let (cleanupLms, cleanupDefaults) = try lms("cleanup-partial")
        check(cleanupLms.replaceItems(with:[old],today:today), "cleanup history seeded")
        cleanupLms.toggleCheck(uid:old.uid)
        let cleanupTodos = TodoStore(fileURL:root.appendingPathComponent("cleanup-todos/todos.json"))
        let completed = cleanupTodos.add(title:"fake completed",dueDate:today)!
        cleanupTodos.toggleDone(id:completed.id); _ = cleanupTodos.flushPendingSave()
        let unfinished = cleanupTodos.add(title:"fake unfinished",dueDate:today)!
        _ = cleanupTodos.flushPendingSave()
        let historyService = HistoryService(todoStore:cleanupTodos,lmsStore:cleanupLms,
             archiveDirectory:root.appendingPathComponent("cleanup-backup"),defaults:cleanupDefaults)
        let cleanupPlan = HistoryPolicy.resetPlan(todos:cleanupTodos.todos,history:cleanupLms.history,checked:cleanupLms.checked)
        try fm.removeItem(at:cleanupLms.stateURL)
        try fm.createDirectory(at:cleanupLms.stateURL,withIntermediateDirectories:false)
        var partialFailed = false
        do { _ = try historyService.run(cleanupPlan,backup:true) }
        catch HistoryService.CleanupError.saveFailed { partialFailed = true }
        check(partialFailed && cleanupLms.history.isEmpty && cleanupLms.isChecked(old.uid), "partial cleanup reports failure and preserves failed state")
        let backupFiles = try fm.contentsOfDirectory(at:historyService.archiveDirectory,includingPropertiesForKeys:nil)
        check(backupFiles.count == 1, "partial cleanup retains completed backup")
        check(cleanupTodos.todos.map(\.id) == [unfinished.id], "cleanup protects unfinished todos")
        try fm.removeItem(at:cleanupLms.stateURL)
        let retried = try historyService.run(cleanupPlan,backup:false)
        check(retried.removedCount == 0 && !cleanupLms.isChecked(old.uid), "cleanup retry counts actual removals")
        print("T021 PASS total=\(count)")
    }
}

#endif
