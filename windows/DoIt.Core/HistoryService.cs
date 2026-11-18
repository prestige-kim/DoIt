using System.Globalization;
using System.Text.Json;

namespace DoIt.Core;

public enum HistoryRetention { SixMonths, OneYear, TwoYears, Forever }

public sealed record HistorySummary(int TodoCount, int LmsCount)
{
    public int TotalCount => TodoCount + LmsCount;
}

public sealed record HistoryCleanupResult(int RemovedTodos, int RemovedLms, bool Succeeded);
public sealed record StorageEntry(string Name, int ItemCount, long Bytes);

public interface ILmsHistoryStore
{
    IReadOnlyList<LmsHistoryEntry> History { get; }
    IReadOnlyDictionary<string, DateTimeOffset> Checks { get; }
    int CurrentCount { get; }
    bool RemoveHistory(IEnumerable<string> uids);
    bool ResetData();
}

public sealed class HistoryService
{
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true };
    private readonly TodoStore todos;
    private readonly ILmsHistoryStore lms;
    private readonly TimeProvider clock;
    private readonly string dataDirectory;
    private readonly string archiveDirectory;
    private readonly string settingsPath;
    private readonly bool settingsUnreadable;

    public HistoryService(TodoStore todos, ILmsHistoryStore lms, string dataDirectory, TimeProvider? clock = null)
    {
        this.todos = todos;
        this.lms = lms;
        this.clock = clock ?? TimeProvider.System;
        this.dataDirectory = Path.GetFullPath(dataDirectory);
        archiveDirectory = Path.Combine(this.dataDirectory, "archive");
        settingsPath = Path.Combine(this.dataDirectory, "history-settings.json");

        try
        {
            var value = JsonSerializer.Deserialize<HistoryRetention>(File.ReadAllBytes(settingsPath));
            if (Enum.IsDefined(value))
            {
                Retention = value;
            }
            else
            {
                settingsUnreadable = true;
            }
        }
        catch (Exception error) when (error is FileNotFoundException or DirectoryNotFoundException)
        {
            // Fresh installs use the default without writing a settings file.
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException)
        {
            settingsUnreadable = true;
        }
    }

    public HistoryRetention Retention { get; private set; } = HistoryRetention.OneYear;

    /// <summary>Folder that receives cleanup and reset backups. It may not exist until the first backup.</summary>
    public string ArchiveDirectory => archiveDirectory;

    /// <summary>The backup file written by the most recent backed-up cleanup or reset in this session.</summary>
    public string? LastArchivePath { get; private set; }
    public long MemoryBytes => Environment.WorkingSet;

    public void SetRetention(HistoryRetention value)
    {
        if (!Enum.IsDefined(value))
        {
            throw new ArgumentOutOfRangeException(nameof(value));
        }
        if (value == Retention)
        {
            return;
        }
        if (settingsUnreadable)
        {
            throw new IOException("기존 기록 설정 파일을 보존했습니다.");
        }
        WriteAtomic(dataDirectory, JsonSerializer.SerializeToUtf8Bytes(value), path => File.Move(path, settingsPath, overwrite: true));
        Retention = value;
    }

    public HistorySummary Preview() => Plan(reset: false).Summary;
    public HistorySummary PreviewReset() => Plan(reset: true).Summary;
    public HistoryCleanupResult Clean(bool backup) => Run(Plan(reset: false), backup, reset: false);
    public HistoryCleanupResult Reset() => Run(Plan(reset: true), backup: true, reset: true);

    public IReadOnlyList<StorageEntry> Storage()
    {
        return
        [
            FileEntry("todos.json", todos.All.Count),
            FileEntry("lms.json", lms.CurrentCount),
            FileEntry("lms-history.json", lms.History.Count),
            FileEntry("lms-state.json", lms.Checks.Count),
            ArchiveEntry(),
        ];
    }

    private StorageEntry FileEntry(string name, int count) => new(name, count, FileSize(Path.Combine(dataDirectory, name)));

    private StorageEntry ArchiveEntry()
    {
        try
        {
            var files = Directory.GetFiles(archiveDirectory, "기록-*.json");
            return new StorageEntry("archive/", files.Length, files.Sum(FileSize));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return new StorageEntry("archive/", 0, 0);
        }
    }

    private static long FileSize(string path)
    {
        try
        {
            return new FileInfo(path).Length;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return 0;
        }
    }

    private CleanupPlan Plan(bool reset)
    {
        var now = clock.GetLocalNow();
        var today = DateOnly.FromDateTime(now.DateTime);
        var cutoff = Cutoff(today);
        if (!reset && cutoff is null)
        {
            return new CleanupPlan(now, [], [], []);
        }

        var zone = clock.LocalTimeZone;
        var completed = todos.All.Where(todo => todo.IsDone && (reset || todo.DoneAt is { } at
            && DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(at, zone).DateTime) < cutoff)).ToArray();
        var history = lms.History.Where(entry => reset || entry.Item.DueDate < cutoff).ToArray();
        var selected = history.Select(entry => entry.Item.Uid).ToHashSet(StringComparer.Ordinal);
        var checks = lms.Checks.Where(check => reset || selected.Contains(check.Key)).ToDictionary();
        return new CleanupPlan(now, completed, history, checks);
    }

    private DateOnly? Cutoff(DateOnly today)
    {
        int months = Retention switch
        {
            HistoryRetention.SixMonths => 6,
            HistoryRetention.OneYear => 12,
            HistoryRetention.TwoYears => 24,
            _ => 0,
        };
        if (months == 0)
        {
            return null;
        }
        int monthsSinceBeginning = (today.Year - 1) * 12 + today.Month - 1;
        return monthsSinceBeginning < months ? DateOnly.MinValue : today.AddMonths(-months);
    }

    private HistoryCleanupResult Run(CleanupPlan plan, bool backup, bool reset)
    {
        if (plan.Summary.TotalCount == 0 && plan.Checks.Count == 0)
        {
            return new HistoryCleanupResult(0, 0, true);
        }

        if (backup)
        {
            try
            {
                WriteArchive(plan, reset);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                return new HistoryCleanupResult(0, 0, false);
            }
        }

        int removedTodos;
        try
        {
            removedTodos = todos.RemoveCompleted(plan.Todos.Select(todo => todo.Id).ToArray());
        }
        catch (TodoStorageException)
        {
            return new HistoryCleanupResult(0, 0, false);
        }

        int previousHistoryCount = lms.History.Count;
        bool succeeded = reset ? lms.ResetData() : lms.RemoveHistory(plan.History.Select(entry => entry.Item.Uid));
        return new HistoryCleanupResult(removedTodos, Math.Max(0, previousHistoryCount - lms.History.Count), succeeded);
    }

    private void WriteArchive(CleanupPlan plan, bool reset)
    {
        var content = new ArchiveFile(1, reset ? "reset" : "cleanup", plan.Now, plan.Todos, plan.History, plan.Checks);
        byte[] bytes = JsonSerializer.SerializeToUtf8Bytes(content, JsonOptions);
        var name = $"기록-{plan.Now.ToString("yyyyMMdd", CultureInfo.InvariantCulture)}";
        WriteAtomic(archiveDirectory, bytes, path => MoveArchive(path, name));
    }

    private void MoveArchive(string temporaryPath, string name)
    {
        for (int suffix = 1; ; suffix++)
        {
            string filename = suffix == 1 ? $"{name}.json" : $"{name}-{suffix}.json";
            string destination = Path.Combine(archiveDirectory, filename);
            try
            {
                File.Move(temporaryPath, destination);
                LastArchivePath = destination;
                return;
            }
            catch (IOException) when (File.Exists(destination))
            {
                // A prior backup used this date. Keep it and try the next suffix.
            }
        }
    }

    private static void WriteAtomic(string directory, byte[] bytes, Action<string> move)
    {
        Directory.CreateDirectory(directory);
        string temporaryPath = Path.Combine(directory, $".doit-history-{Guid.NewGuid():N}.tmp");
        bool created = false;
        try
        {
            using (var stream = new FileStream(temporaryPath, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                created = true;
                stream.Write(bytes);
                stream.Flush(flushToDisk: true);
            }
            move(temporaryPath);
            created = false;
        }
        finally
        {
            if (created)
            {
                try
                {
                    File.Delete(temporaryPath);
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException)
                {
                    // Do not hide the original write failure if cleanup also fails.
                }
            }
        }
    }

    private sealed record CleanupPlan(DateTimeOffset Now, TodoItem[] Todos, LmsHistoryEntry[] History, Dictionary<string, DateTimeOffset> Checks)
    {
        public HistorySummary Summary => new(Todos.Length, History.Length);
    }

    private sealed record ArchiveFile(int SchemaVersion, string Kind, DateTimeOffset CreatedAt, TodoItem[] Todos,
        LmsHistoryEntry[] LmsHistory, Dictionary<string, DateTimeOffset> LmsChecks);
}
