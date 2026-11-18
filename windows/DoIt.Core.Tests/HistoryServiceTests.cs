using System.Text.Json;
using DoIt.Core;

internal static class HistoryServiceTests
{
    private static readonly DateTimeOffset Now = new(2026, 11, 12, 9, 0, 0, TimeSpan.Zero);
    private static readonly DateOnly Today = DateOnly.FromDateTime(Now.DateTime);

    internal static (string Name, Action Run)[] Cases =>
    [
        ("History retention selects strictly older completed todos and LMS due dates only", Retention),
        ("History backup failure does not delete any selected item", BackupFailure),
        ("History reset backs up completed todos, LMS history and checks while retaining live records", Reset),
        ("History partial failure reports committed deletions and preserves backup", PartialFailure),
        ("History settings and size reports only use their expected local files", SettingsAndStorage),
    ];

    private static void Retention()
    {
        WithHistory((_, clock, todos, lms, history) =>
        {
            clock.UtcNow = Now.AddYears(-1).AddDays(-1);
            todos.Add("오래된 완료");
            todos.ToggleDone(todos.All[0].Id);
            todos.Add("오래된 미완료");
            clock.UtcNow = Now.AddYears(-1);
            todos.Add("기간 경계에 완료");
            todos.ToggleDone(todos.All[^1].Id);
            lms.Entries.Add(Entry("old", Today.AddYears(-1).AddDays(-1)));
            lms.Entries.Add(Entry("boundary", Today.AddYears(-1)));
            lms.MutableChecks["old"] = clock.UtcNow;
            lms.MutableChecks["boundary"] = clock.UtcNow;
            clock.UtcNow = Now;

            Equal(new HistorySummary(1, 1), history.Preview());
            Equal(3, todos.All.Count);
            history.SetRetention(HistoryRetention.Forever);
            Equal(0, history.Preview().TotalCount);
            Equal(new HistoryCleanupResult(0, 0, true), history.Clean(backup: false));
            history.SetRetention(HistoryRetention.OneYear);
            Equal(new HistoryCleanupResult(1, 1, true), history.Clean(backup: false));
            Equal("오래된 미완료", todos.All[0].Title);
            Equal("boundary", lms.History.Single().Item.Uid);
            Equal("boundary", lms.Checks.Keys.Single());
        });
    }

    private static void BackupFailure()
    {
        WithHistory((directory, clock, todos, lms, history) =>
        {
            PrepareOldRecords(clock, todos, lms);
            File.WriteAllText(Path.Combine(directory, "archive"), "가짜 백업 쓰기 실패");
            Equal(new HistoryCleanupResult(0, 0, false), history.Clean(backup: true));
            Equal(null, history.LastArchivePath);
            Equal(1, todos.All.Count);
            Equal(1, lms.History.Count);
            Equal(1, lms.Checks.Count);
        });
    }

    private static void Reset()
    {
        WithHistory((directory, clock, todos, lms, history) =>
        {
            PrepareOldRecords(clock, todos, lms);
            todos.Add("남겨 둘 미완료");
            lms.CurrentCount = 2;
            lms.MutableChecks["live"] = Now;
            lms.MutableChecks["orphan"] = Now;
            var archive = Directory.CreateDirectory(Path.Combine(directory, "archive"));
            string first = Path.Combine(archive.FullName, "기록-20261112.json");
            File.WriteAllText(first, "이전 백업");

            Equal(new HistorySummary(1, 1), history.PreviewReset());
            Equal(null, history.LastArchivePath);
            Equal(new HistoryCleanupResult(1, 1, true), history.Reset());
            Equal(archive.FullName, history.ArchiveDirectory);
            Equal(Path.Combine(archive.FullName, "기록-20261112-2.json"), history.LastArchivePath);
            Equal("남겨 둘 미완료", todos.All.Single().Title);
            Equal(0, lms.History.Count);
            Equal(0, lms.Checks.Count);
            Equal(2, lms.CurrentCount);
            Equal("이전 백업", File.ReadAllText(first));
            using var backup = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(archive.FullName, "기록-20261112-2.json")));
            Equal("reset", backup.RootElement.GetProperty("kind").GetString());
            Equal(1, backup.RootElement.GetProperty("todos").GetArrayLength());
            Equal(1, backup.RootElement.GetProperty("lmsHistory").GetArrayLength());
            Equal(3, backup.RootElement.GetProperty("lmsChecks").EnumerateObject().Count());
        });
    }

    private static void PartialFailure()
    {
        WithHistory((directory, clock, todos, lms, history) =>
        {
            PrepareOldRecords(clock, todos, lms);
            lms.FailWrite = true;
            Equal(new HistoryCleanupResult(1, 0, false), history.Clean(backup: true));
            Equal(0, todos.All.Count);
            Equal(1, lms.History.Count);
            using var backup = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(directory, "archive", "기록-20261112.json")));
            Equal("cleanup", backup.RootElement.GetProperty("kind").GetString());
            Equal(1, backup.RootElement.GetProperty("todos").GetArrayLength());
            Equal(1, backup.RootElement.GetProperty("lmsHistory").GetArrayLength());
        });
    }

    private static void SettingsAndStorage()
    {
        WithHistory((directory, clock, todos, lms, history) =>
        {
            Equal(HistoryRetention.OneYear, history.Retention);
            history.SetRetention(HistoryRetention.SixMonths);
            var reopened = new HistoryService(todos, lms, directory, clock);
            Equal(HistoryRetention.SixMonths, reopened.Retention);
            todos.Add("가짜 할 일");
            File.WriteAllText(Path.Combine(directory, "synthetic-excluded-data"), "크기 계산 대상 아님");
            var report = history.Storage();
            Equal("todos.json,lms.json,lms-history.json,lms-state.json,archive/", string.Join(',', report.Select(entry => entry.Name)));
            Equal(new FileInfo(Path.Combine(directory, "todos.json")).Length, report.Sum(entry => entry.Bytes));
            Equal(1, report[0].ItemCount);
        });
    }

    private static void PrepareOldRecords(LocalClock clock, TodoStore todos, TestHistoryStore lms)
    {
        clock.UtcNow = Now.AddYears(-2);
        todos.Add("오래된 완료");
        todos.ToggleDone(todos.All[0].Id);
        lms.Entries.Add(Entry("old", Today.AddYears(-2)));
        lms.MutableChecks["old"] = clock.UtcNow;
        clock.UtcNow = Now;
    }

    private static LmsHistoryEntry Entry(string uid, DateOnly dueDate) => new(new LmsItem(uid, "가짜 과제", null, dueDate, null), Now);

    private static void WithHistory(Action<string, LocalClock, TodoStore, TestHistoryStore, HistoryService> run)
    {
        var root = Directory.CreateTempSubdirectory("doit-history-");
        try
        {
            var clock = new LocalClock();
            var todos = new TodoStore(Path.Combine(root.FullName, "todos.json"), clock);
            var lms = new TestHistoryStore();
            run(root.FullName, clock, todos, lms, new HistoryService(todos, lms, root.FullName, clock));
        }
        finally
        {
            root.Delete(recursive: true);
        }
    }

    private static void Equal<T>(T expected, T actual)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
        {
            throw new InvalidOperationException($"Expected {expected}, got {actual}.");
        }
    }

    private sealed class LocalClock : TimeProvider
    {
        internal DateTimeOffset UtcNow { get; set; } = Now;
        public override TimeZoneInfo LocalTimeZone => TimeZoneInfo.Utc;
        public override DateTimeOffset GetUtcNow() => UtcNow;
    }

    private sealed class TestHistoryStore : ILmsHistoryStore
    {
        internal List<LmsHistoryEntry> Entries { get; } = [];
        internal Dictionary<string, DateTimeOffset> MutableChecks { get; } = [];
        internal bool FailWrite { get; set; }
        public IReadOnlyList<LmsHistoryEntry> History => Entries;
        public IReadOnlyDictionary<string, DateTimeOffset> Checks => MutableChecks;
        public int CurrentCount { get; set; }

        public bool RemoveHistory(IEnumerable<string> uids)
        {
            if (FailWrite)
            {
                return false;
            }
            var selected = uids.ToHashSet(StringComparer.Ordinal);
            Entries.RemoveAll(entry => selected.Contains(entry.Item.Uid));
            foreach (string uid in selected)
            {
                MutableChecks.Remove(uid);
            }
            return true;
        }

        public bool ResetData()
        {
            if (FailWrite)
            {
                return false;
            }
            Entries.Clear();
            MutableChecks.Clear();
            return true;
        }
    }
}
