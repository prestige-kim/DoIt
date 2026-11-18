using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.Unicode;

namespace DoIt.Core;

public sealed class TodoStorageException(string message) : Exception(message);

public enum TodoSortOrder
{
    DueDate,
    Added,
}

public sealed class TodoStore
{
    private const int SchemaVersion = 1;
    private const string LoadFailure = "할 일을 읽지 못했습니다. 기존 파일을 보존했습니다. 문제가 해결되면 DoIt을 다시 실행해 주세요.";
    private const string SaveFailure = "할 일을 저장하지 못했습니다. 이전 목록은 그대로입니다. 다시 시도해 주세요.";
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        Encoder = JavaScriptEncoder.Create(UnicodeRanges.All),
        WriteIndented = true,
    };

    private readonly string filePath;
    private readonly string directory;
    private readonly TimeProvider clock;
    private readonly object gate = new();
    private volatile IReadOnlyList<TodoItem> items = Array.Empty<TodoItem>();
    private byte[]? savedFingerprint;

    public TodoStore(string filePath, TimeProvider? clock = null)
    {
        this.filePath = Path.GetFullPath(filePath);
        directory = Path.GetDirectoryName(this.filePath)
            ?? throw new ArgumentException("A storage file path is required.", nameof(filePath));
        this.clock = clock ?? TimeProvider.System;

        try
        {
            var bytes = ReadFile();
            if (bytes is null)
            {
                return;
            }

            var file = JsonSerializer.Deserialize<TodoFile>(bytes, JsonOptions);
            if (file is null || file.SchemaVersion != SchemaVersion || file.Todos is null
                || file.Todos.Any(todo => todo is null || todo.Id == Guid.Empty || string.IsNullOrWhiteSpace(todo.Title))
                || file.Todos.Select(todo => todo.Id).Distinct().Count() != file.Todos.Length)
            {
                LoadError = LoadFailure;
                return;
            }

            items = Array.AsReadOnly(file.Todos);
            savedFingerprint = SHA256.HashData(bytes);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException)
        {
            LoadError = LoadFailure;
        }
    }

    public string? LoadError { get; }
    public IReadOnlyList<TodoItem> All => items;
    public event Action? Changed;

    public IReadOnlyList<TodoItem> Visible(DateOnly today) => Ordered(VisibleItems(today));

    public IReadOnlyList<TodoItem> SearchVisible(DateOnly today, string query, TodoSortOrder order)
    {
        string term = query.Trim().Normalize();
        var visible = VisibleItems(today);
        if (term.Length > 0)
        {
            visible = visible.Where(todo => todo.Title.Normalize().Contains(term, StringComparison.OrdinalIgnoreCase));
        }

        return order == TodoSortOrder.Added
            ? visible.OrderBy(todo => todo.IsDone).ThenBy(todo => todo.CreatedAt).ToArray()
            : Ordered(visible);
    }

    private IEnumerable<TodoItem> VisibleItems(DateOnly today)
    {
        var localTimeZone = clock.LocalTimeZone;
        return items.Where(todo => !todo.IsDone || todo.DoneAt is not { } doneAt
            || DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(doneAt, localTimeZone).DateTime) >= today);
    }

    public IReadOnlyList<TodoItem> ForDate(DateOnly date) => Ordered(items.Where(todo => todo.DueDate == date));

    public bool Add(string title, DateOnly? dueDate = null)
    {
        var trimmed = title.Trim();
        if (!IsValidEditorTitle(trimmed))
        {
            return false;
        }

        lock (gate)
        {
            var now = clock.GetLocalNow();
            var day = dueDate ?? DateOnly.FromDateTime(now.DateTime);
            Save([.. items, new TodoItem(Guid.NewGuid(), trimmed, day, now, now, false, null)]);
        }

        Changed?.Invoke();
        return true;
    }

    public bool ToggleDone(Guid id)
    {
        lock (gate)
        {
            var next = items.ToArray();
            int index = Array.FindIndex(next, todo => todo.Id == id);
            if (index < 0)
            {
                return false;
            }

            var todo = next[index];
            next[index] = WithDoneState(todo, !todo.IsDone, clock.GetLocalNow());
            Save(next);
        }

        Changed?.Invoke();
        return true;
    }

    public bool Delete(Guid id) => DeleteMany([id]);

    public bool Update(Guid id, string title, DateOnly dueDate)
    {
        string trimmed = title.Trim();
        if (!IsValidEditorTitle(trimmed))
        {
            return false;
        }

        lock (gate)
        {
            var next = items.ToArray();
            int index = Array.FindIndex(next, todo => todo.Id == id);
            if (index < 0)
            {
                return false;
            }

            var item = next[index];
            if (item.Title == trimmed && item.DueDate == dueDate)
            {
                return true;
            }

            next[index] = item with { Title = trimmed, DueDate = dueDate, UpdatedAt = clock.GetLocalNow() };
            Save(next);
        }

        Changed?.Invoke();
        return true;
    }

    public static bool IsValidEditorTitle(string title)
    {
        string trimmed = title.Trim();
        if (trimmed.Length == 0 || new StringInfo(trimmed).LengthInTextElements > 200)
        {
            return false;
        }

        foreach (var rune in trimmed.EnumerateRunes())
        {
            if (Rune.GetUnicodeCategory(rune) is UnicodeCategory.Control or UnicodeCategory.Format
                or UnicodeCategory.LineSeparator or UnicodeCategory.ParagraphSeparator)
            {
                return false;
            }
        }

        return true;
    }

    public bool SetDone(IReadOnlyCollection<Guid> ids, bool isDone)
    {
        var selected = ids.ToHashSet();
        lock (gate)
        {
            var next = items.ToArray();
            var now = clock.GetLocalNow();
            bool changed = false;
            for (int index = 0; index < next.Length; index++)
            {
                var item = next[index];
                if (item.IsDone != isDone && selected.Contains(item.Id))
                {
                    next[index] = WithDoneState(item, isDone, now);
                    changed = true;
                }
            }

            if (!changed)
            {
                return false;
            }

            Save(next);
        }

        Changed?.Invoke();
        return true;
    }

    public bool DeleteMany(IReadOnlyCollection<Guid> ids)
    {
        var selected = ids.ToHashSet();
        lock (gate)
        {
            var next = items.Where(todo => !selected.Contains(todo.Id)).ToArray();
            if (next.Length == items.Count)
            {
                return false;
            }

            Save(next);
        }

        Changed?.Invoke();
        return true;
    }

    internal int RemoveCompleted(IReadOnlyCollection<Guid> ids)
    {
        var selected = ids.ToHashSet();
        int removed;
        lock (gate)
        {
            var next = items.Where(item => !item.IsDone || !selected.Contains(item.Id)).ToArray();
            removed = items.Count - next.Length;
            if (removed == 0)
            {
                return 0;
            }
            Save(next);
        }

        Changed?.Invoke();
        return removed;
    }

    private static TodoItem WithDoneState(TodoItem item, bool isDone, DateTimeOffset now) =>
        item with { IsDone = isDone, DoneAt = isDone ? now : null, UpdatedAt = now };

    private static TodoItem[] Ordered(IEnumerable<TodoItem> source) => source
        .OrderBy(todo => todo.IsDone)
        .ThenBy(todo => todo.DueDate)
        .ThenBy(todo => todo.CreatedAt)
        .ToArray();

    private byte[]? ReadFile()
    {
        try
        {
            return File.ReadAllBytes(filePath);
        }
        catch (Exception error) when (error is FileNotFoundException or DirectoryNotFoundException)
        {
            return null;
        }
    }

    private void Save(TodoItem[] next)
    {
        if (LoadError is { } loadError)
        {
            throw new TodoStorageException(loadError);
        }

        var bytes = JsonSerializer.SerializeToUtf8Bytes(new TodoFile(SchemaVersion, next), JsonOptions);
        var fingerprint = SHA256.HashData(bytes);
        var snapshot = Array.AsReadOnly(next);
        string temporaryPath = Path.Combine(directory, $".doit-todo-{Guid.NewGuid():N}.tmp");
        bool createdTemporaryFile = false;

        try
        {
            Directory.CreateDirectory(directory);
            // Keep the lock file in place so separate running instances always lock the same file.
            using var writeLock = new FileStream(filePath + ".lock", FileMode.OpenOrCreate, FileAccess.Write, FileShare.None);
            var currentBytes = ReadFile();
            var currentFingerprint = currentBytes is null ? null : SHA256.HashData(currentBytes);
            if (savedFingerprint is null ? currentFingerprint is not null
                : currentFingerprint is null || !savedFingerprint.AsSpan().SequenceEqual(currentFingerprint))
            {
                throw new TodoStorageException("다른 창이나 앱에서 할 일 파일이 바뀌었습니다. DoIt을 다시 실행한 뒤 시도해 주세요.");
            }

            using (var stream = new FileStream(temporaryPath, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                createdTemporaryFile = true;
                stream.Write(bytes);
                stream.Flush(flushToDisk: true);
            }

            File.Move(temporaryPath, filePath, overwrite: true);
            createdTemporaryFile = false;
            savedFingerprint = fingerprint;
            items = snapshot;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            throw new TodoStorageException(SaveFailure);
        }
        finally
        {
            if (createdTemporaryFile)
            {
                try
                {
                    File.Delete(temporaryPath);
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException)
                {
                    // The original file remains the source of truth if cleanup fails.
                }
            }
        }
    }

    private sealed record TodoFile([property: JsonRequired] int SchemaVersion, [property: JsonRequired] TodoItem[] Todos);
}
