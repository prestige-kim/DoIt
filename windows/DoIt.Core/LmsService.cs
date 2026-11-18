using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace DoIt.Core;

public interface ILmsFeedAddressStore
{
    bool Exists { get; }
    Uri? Read();
    void Write(Uri address);
    void Delete();
}

public sealed record LmsRow(LmsItem Item, DateTimeOffset? DoneAt)
{
    public bool IsDone => DoneAt.HasValue;
}

public sealed record LmsHistoryEntry(LmsItem Item, DateTimeOffset ArchivedAt);

public sealed record LmsSnapshot(bool Enabled, bool HasFeedAddress, int Weeks, bool IsSyncing,
    bool DisconnectPending, LmsSyncStatus Status, DateTimeOffset? LastSuccessAt, DateTimeOffset? RetryAt);

public sealed class LmsService : IDisposable, ILmsHistoryStore
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    private readonly string directory;
    private readonly ILmsFeedAddressStore addressStore;
    private readonly TimeProvider clock;
    private readonly LmsFeedClient client;
    private readonly object gate = new();
    private readonly SemaphoreSlim requestGate = new(1, 1);
    private readonly CancellationTokenSource shutdown = new();
    private SyncSettings settings = new();
    private LmsItem[] current = [];
    private LmsHistoryEntry[] history = [];
    private Dictionary<string, DateTimeOffset> checks = new(StringComparer.Ordinal);
    private bool hasAddress;
    private bool syncing;
    private bool disposed;
    private bool loadFailed;
    private bool storageError;
    private long connectionGeneration;

    public LmsService(string directory, ILmsFeedAddressStore addressStore, HttpMessageHandler? handler = null,
        TimeProvider? clock = null)
    {
        this.directory = Path.GetFullPath(directory);
        this.addressStore = addressStore;
        this.clock = clock ?? TimeProvider.System;
        client = new LmsFeedClient(handler);

        settings = Load("lms-settings.json", new SyncSettings(), value => value.Weeks is >= 1 and <= 8
            && Enum.IsDefined(value.Status) && value.ConsecutiveRateLimits >= 0);
        current = Load("lms.json", Array.Empty<LmsItem>(), ValidItems);
        history = Load("lms-history.json", Array.Empty<LmsHistoryEntry>(), entries => entries.All(entry => entry is not null)
            && ValidItems(entries.Select(entry => entry.Item)));
        checks = Load("lms-state.json", new Dictionary<string, DateTimeOffset>(StringComparer.Ordinal),
            values => values.Keys.All(IsAssignmentUid));
        try
        {
            hasAddress = addressStore.Exists;
        }
        catch (Exception error) when (IsStorageFailure(error))
        {
            storageError = true;
        }
        if (!loadFailed)
        {
            try
            {
                ArchivePast(Today());
            }
            catch (Exception error) when (IsStorageFailure(error))
            {
                storageError = true;
            }
        }
    }

    public event Action? Changed;

    public LmsSnapshot Snapshot
    {
        get
        {
            lock (gate)
            {
                DateTimeOffset? interval = settings.LastAttemptAt is { } last && last <= clock.GetUtcNow().AddMinutes(1)
                    ? last.AddMinutes(5) : null;
                var retryAt = interval > settings.RateLimitedUntil || settings.RateLimitedUntil is null
                    ? interval : settings.RateLimitedUntil;
                return new(settings.Enabled, hasAddress, settings.Weeks, syncing, settings.DisconnectPending,
                    loadFailed || storageError ? LmsSyncStatus.StorageError : settings.Status,
                    settings.LastSuccessAt, retryAt);
            }
        }
    }

    public IReadOnlyList<LmsRow> All
    {
        get { lock (gate) return AllRows(); }
    }

    public IReadOnlyList<LmsRow> Current
    {
        get
        {
            lock (gate)
            {
                return settings.Enabled && hasAddress && !settings.DisconnectPending
                    ? current.Select(AsRow).ToArray() : [];
            }
        }
    }

    public IReadOnlyList<LmsHistoryEntry> History
    {
        get { lock (gate) return history.ToArray(); }
    }

    public IReadOnlyDictionary<string, DateTimeOffset> Checks
    {
        get { lock (gate) return new Dictionary<string, DateTimeOffset>(checks, StringComparer.Ordinal); }
    }

    public int CurrentCount
    {
        get { lock (gate) return current.Length; }
    }

    public int CheckedCount
    {
        get { lock (gate) return checks.Count; }
    }

    public IReadOnlyList<LmsRow> Visible(DateOnly today)
    {
        lock (gate)
        {
            if (!settings.Enabled || !hasAddress || settings.DisconnectPending)
            {
                return [];
            }
            int yesterday = today.DayNumber - 1;
            int end = today.DayNumber + 7 * settings.Weeks;
            return AllRows().Where(row => row.Item.DueDate.DayNumber <= end && (row.DoneAt is { } doneAt
                ? LocalDate(doneAt) >= today : row.Item.DueDate.DayNumber >= yesterday)).ToArray();
        }
    }

    public IReadOnlyList<LmsRow> ForDate(DateOnly date)
    {
        lock (gate)
        {
            if (!settings.Enabled || !hasAddress || settings.DisconnectPending)
            {
                return [];
            }
            return AllRows().Where(row => row.Item.DueDate == date).ToArray();
        }
    }

    public bool SetEnabled(bool enabled) => Modify(() =>
    {
        if (enabled && (!hasAddress || settings.DisconnectPending))
        {
            return false;
        }
        if (enabled != settings.Enabled)
        {
            WriteSettings(settings with { Enabled = enabled });
            ++connectionGeneration;
        }
        return true;
    });

    public bool SetWeeks(int weeks) => Modify(() =>
    {
        if (weeks is < 1 or > 8)
        {
            return false;
        }
        if (settings.Weeks != weeks)
        {
            WriteSettings(settings with { Weeks = weeks });
        }
        return true;
    });

    public bool SaveAddress(string address)
    {
        if (!LmsFeedAddress.TryValidate(address, out var url))
        {
            return false;
        }
        return Modify(() =>
        {
            bool wasEnabled = settings.Enabled && !settings.DisconnectPending;
            // Persist a disabled state before swapping secrets. An interrupted change cannot send the old validators.
            WriteSettings(ResetConnection(settings) with { Enabled = false });
            ++connectionGeneration;
            addressStore.Write(url);
            hasAddress = true;
            WriteSettings(settings with { Enabled = wasEnabled, DisconnectPending = false });
            return true;
        });
    }

    public bool Disconnect() => Modify(() =>
    {
        ++connectionGeneration;
        settings = settings with { Enabled = false, DisconnectPending = true };
        WriteSettings(settings);
        addressStore.Delete();
        hasAddress = false;
        ArchivePast(Today());
        File.Delete(Path.Combine(directory, "lms.json"));
        current = [];
        WriteSettings(ResetConnection(settings) with { DisconnectPending = false });
        return true;
    });

    public bool ToggleDone(string uid) => Modify(() =>
    {
        if (!settings.Enabled || settings.DisconnectPending || !hasAddress
            || !AllRows().Any(row => row.Item.Uid == uid))
        {
            return false;
        }
        var next = new Dictionary<string, DateTimeOffset>(checks, StringComparer.Ordinal);
        if (!next.Remove(uid))
        {
            next.Add(uid, clock.GetUtcNow());
        }
        WriteChecks(next);
        return true;
    });

    public bool RemoveHistory(IEnumerable<string> uids) => Modify(() =>
    {
        var removed = uids.ToHashSet(StringComparer.Ordinal);
        var toRemove = history.Where(entry => removed.Contains(entry.Item.Uid)).Select(entry => entry.Item.Uid)
            .ToHashSet(StringComparer.Ordinal);
        if (toRemove.Count == 0)
        {
            return true;
        }
        var nextHistory = history.Where(entry => !toRemove.Contains(entry.Item.Uid)).ToArray();
        var stillCurrent = current.Select(item => item.Uid).ToHashSet(StringComparer.Ordinal);
        WriteHistory(nextHistory);
        var nextChecks = checks.Where(pair => !toRemove.Contains(pair.Key) || stillCurrent.Contains(pair.Key))
            .ToDictionary(StringComparer.Ordinal);
        if (nextChecks.Count != checks.Count)
        {
            WriteChecks(nextChecks);
        }
        return true;
    });

    public bool ResetData() => Modify(() =>
    {
        ++connectionGeneration;
        if (history.Length != 0)
        {
            WriteHistory([]);
        }
        if (checks.Count != 0)
        {
            WriteChecks(new Dictionary<string, DateTimeOffset>(StringComparer.Ordinal));
        }
        return true;
    });

    public async Task RefreshAsync(bool manual = false, CancellationToken cancellationToken = default)
    {
        try
        {
            if (!await requestGate.WaitAsync(0, cancellationToken))
            {
                return;
            }
        }
        catch (OperationCanceledException)
        {
            return;
        }

        RefreshRequest? request = null;
        try
        {
            lock (gate)
            {
                if (disposed || loadFailed)
                {
                    return;
                }
                var now = clock.GetUtcNow();
                try
                {
                    ArchivePast(LocalDate(now));
                    if (settings.Enabled && hasAddress && !settings.DisconnectPending && CanRefresh(now, manual))
                    {
                        var address = addressStore.Read();
                        if (address is null)
                        {
                            hasAddress = false;
                        }
                        else if (LmsFeedAddress.IsValid(address))
                        {
                            WriteSettings(settings with { LastAttemptAt = now });
                            syncing = true;
                            storageError = false;
                            request = new(address, settings.LastModified, connectionGeneration, now);
                        }
                    }
                }
                catch (Exception error) when (IsStorageFailure(error))
                {
                    storageError = true;
                }
            }
            Changed?.Invoke();
            if (request is null)
            {
                return;
            }

            using var tokenSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, shutdown.Token);
            var response = await client.FetchAsync(request.Address, request.LastModified, request.Now, tokenSource.Token);
            LmsItem[]? items = null;
            if (response.Body is { } body)
            {
                try
                {
                    var zone = clock.LocalTimeZone;
                    var result = await Task.Run(() => IcsParser.Parse(body, zone));
                    items = result.Items.ToArray();
                }
                catch (FormatException)
                {
                    response = new(LmsSyncStatus.InvalidFeed);
                }
            }

            lock (gate)
            {
                if (disposed || settings.DisconnectPending || request.Generation != connectionGeneration)
                {
                    return;
                }
                try
                {
                    AcceptResponse(response, items, clock.GetUtcNow());
                }
                catch (Exception error) when (IsStorageFailure(error))
                {
                    storageError = true;
                }
            }
        }
        finally
        {
            if (request is not null)
            {
                lock (gate) syncing = false;
            }
            requestGate.Release();
            if (request is not null)
            {
                Changed?.Invoke();
            }
        }
    }

    private bool CanRefresh(DateTimeOffset now, bool manual)
    {
        if (settings.RateLimitedUntil > now)
        {
            return false;
        }
        if (settings.LastAttemptAt is not { } last || last > now.AddMinutes(1))
        {
            return true;
        }
        return now - last >= (manual ? TimeSpan.FromMinutes(5) : TimeSpan.FromHours(6));
    }

    private void AcceptResponse(LmsFeedResponse response, LmsItem[]? items, DateTimeOffset now)
    {
        if (response.Status == LmsSyncStatus.RateLimited)
        {
            int count = Math.Min(20, settings.ConsecutiveRateLimits) + 1;
            double requested = (response.RetryAfter ?? TimeSpan.FromDays(1)).TotalSeconds;
            double seconds = Math.Max(requested, Math.Min(TimeSpan.FromDays(7).TotalSeconds,
                requested * Math.Pow(2, count - 1)));
            WriteSettings(settings with
            {
                Status = response.Status,
                ConsecutiveRateLimits = count,
                RateLimitedUntil = now.AddSeconds(Math.Min(seconds, (DateTimeOffset.MaxValue - now).TotalSeconds - 1))
            });
            return;
        }
        if (items is not null)
        {
            ReplaceItems(items, LocalDate(now), now, pruneUnknownChecks: true);
        }
        var next = settings with { Status = response.Status, ConsecutiveRateLimits = 0, RateLimitedUntil = null };
        if (response.Status == LmsSyncStatus.Ok)
        {
            next = next with { LastSuccessAt = now };
            if (items is not null)
            {
                next = next with { LastModified = response.LastModified };
            }
        }
        WriteSettings(next);
    }

    private void ArchivePast(DateOnly today)
    {
        if (current.Any(item => item.DueDate < today))
        {
            ReplaceItems(current, today, clock.GetUtcNow());
        }
    }

    private void ReplaceItems(IReadOnlyList<LmsItem> items, DateOnly today, DateTimeOffset now, bool pruneUnknownChecks = false)
    {
        var nextHistory = history.ToDictionary(entry => entry.Item.Uid, StringComparer.Ordinal);
        foreach (var item in current.Concat(items).Where(item => item.DueDate < today))
        {
            var archivedAt = nextHistory.TryGetValue(item.Uid, out var saved) ? saved.ArchivedAt : now;
            nextHistory[item.Uid] = new(item, archivedAt);
        }
        var archived = nextHistory.Values.OrderBy(entry => entry.Item.DueDate).ThenBy(entry => entry.Item.Uid,
            StringComparer.Ordinal).ToArray();
        if (!archived.SequenceEqual(history))
        {
            WriteHistory(archived);
        }
        var next = items.Where(item => item.DueDate >= today && item.DueDate.DayNumber <= today.DayNumber + 56)
            .OrderBy(item => item.DueDate).ThenBy(item => item.DueTime).ThenBy(item => item.Uid, StringComparer.Ordinal).ToArray();
        if (!next.SequenceEqual(current))
        {
            Write("lms.json", next);
            current = next;
        }
        if (pruneUnknownChecks && checks.Count != 0)
        {
            var retained = current.Select(item => item.Uid).Concat(history.Select(entry => entry.Item.Uid))
                .ToHashSet(StringComparer.Ordinal);
            var nextChecks = checks.Where(pair => retained.Contains(pair.Key)).ToDictionary(StringComparer.Ordinal);
            if (nextChecks.Count != checks.Count)
            {
                WriteChecks(nextChecks);
            }
        }
    }

    private LmsRow[] AllRows()
    {
        var currentUids = current.Select(item => item.Uid).ToHashSet(StringComparer.Ordinal);
        return current.Concat(history.Where(entry => !currentUids.Contains(entry.Item.Uid)).Select(entry => entry.Item))
            .Select(AsRow)
            .OrderBy(row => row.IsDone).ThenBy(row => row.Item.DueDate)
            .ThenBy(row => row.Item.DueTime ?? TimeOnly.MaxValue).ThenBy(row => row.Item.Title, StringComparer.Ordinal)
            .ThenBy(row => row.Item.Uid, StringComparer.Ordinal)
            .ToArray();
    }

    private LmsRow AsRow(LmsItem item) => new(item, checks.TryGetValue(item.Uid, out var done) ? done : null);

    private DateOnly Today() => LocalDate(clock.GetUtcNow());
    private DateOnly LocalDate(DateTimeOffset instant) => DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(instant, clock.LocalTimeZone).DateTime);

    private static SyncSettings ResetConnection(SyncSettings value) => new()
    {
        Enabled = value.Enabled, Weeks = value.Weeks, DisconnectPending = value.DisconnectPending,
        RateLimitedUntil = value.RateLimitedUntil, ConsecutiveRateLimits = value.ConsecutiveRateLimits
    };

    private bool Modify(Func<bool> action)
    {
        bool success = false;
        lock (gate)
        {
            if (disposed || loadFailed)
            {
                return false;
            }
            try
            {
                success = action();
                if (success) storageError = false;
            }
            catch (Exception error) when (IsStorageFailure(error))
            {
                storageError = true;
            }
        }
        Changed?.Invoke();
        return success;
    }

    private static bool IsStorageFailure(Exception error) => error is IOException or UnauthorizedAccessException
        or CryptographicException or JsonException;

    private static bool ValidItems(IEnumerable<LmsItem> items)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        return items.All(item => item is not null && IsAssignmentUid(item.Uid) && !string.IsNullOrWhiteSpace(item.Title)
            && seen.Add(item.Uid));
    }

    private static bool IsAssignmentUid(string? uid) => uid?.StartsWith("event-assignment-", StringComparison.Ordinal) == true;

    private T Load<T>(string filename, T fallback, Func<T, bool> validate)
    {
        try
        {
            var data = File.ReadAllBytes(Path.Combine(directory, filename));
            var document = JsonSerializer.Deserialize<Document<T>>(data, Json);
            if (document is null || document.SchemaVersion != 1 || document.Value is null || !validate(document.Value))
            {
                throw new JsonException();
            }
            return document.Value;
        }
        catch (Exception error) when (error is FileNotFoundException or DirectoryNotFoundException)
        {
            return fallback;
        }
        catch (Exception error) when (IsStorageFailure(error))
        {
            loadFailed = true;
            return fallback;
        }
    }

    private void Write<T>(string filename, T value) => LmsLocalFile.WriteAtomic(Path.Combine(directory, filename),
        JsonSerializer.SerializeToUtf8Bytes(new Document<T>(1, value), Json));

    private void WriteSettings(SyncSettings value)
    {
        Write("lms-settings.json", value);
        settings = value;
    }

    private void WriteHistory(LmsHistoryEntry[] value)
    {
        Write("lms-history.json", value);
        history = value;
    }

    private void WriteChecks(Dictionary<string, DateTimeOffset> value)
    {
        Write("lms-state.json", value);
        checks = value;
    }

    public void Dispose()
    {
        lock (gate)
        {
            if (disposed) return;
            disposed = true;
            ++connectionGeneration;
        }
        shutdown.Cancel();
        client.Dispose();
    }

    private sealed record Document<T>([property: JsonRequired] int SchemaVersion, [property: JsonRequired] T Value);

    private sealed record SyncSettings
    {
        public bool Enabled { get; init; }
        public int Weeks { get; init; } = 2;
        public bool DisconnectPending { get; init; }
        public LmsSyncStatus Status { get; init; }
        public DateTimeOffset? LastAttemptAt { get; init; }
        public DateTimeOffset? LastSuccessAt { get; init; }
        public DateTimeOffset? RateLimitedUntil { get; init; }
        public int ConsecutiveRateLimits { get; init; }
        public DateTimeOffset? LastModified { get; init; }
    }

    private sealed record RefreshRequest(Uri Address, DateTimeOffset? LastModified, long Generation,
        DateTimeOffset Now);
}

public static class LmsLocalFile
{
    public static void WriteAtomic(string path, ReadOnlySpan<byte> bytes)
    {
        var directory = Path.GetDirectoryName(path) ?? throw new ArgumentException("저장 폴더가 필요합니다.", nameof(path));
        Directory.CreateDirectory(directory);
        var temporary = Path.Combine(directory, $".{Guid.NewGuid():N}.tmp");
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                stream.Write(bytes);
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporary, path, overwrite: true);
        }
        finally
        {
            try { File.Delete(temporary); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
    }
}
