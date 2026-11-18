using System.Text.Json;
using DoIt.Core;

internal static class TodoStoreTests
{
    private static readonly DateOnly Today = new(2026, 11, 12);
    private static readonly DateTimeOffset UtcToday = new(2026, 11, 11, 15, 30, 0, TimeSpan.Zero);

    internal static IEnumerable<(string Name, Action Run)> Cases =>
    [
        ("Empty or missing stores do not write until the first valid add", IgnoreEmptyTitle),
        ("Local due dates and timestamps round trip in versioned JSON", LocalDueDateAndRoundTrip),
        ("List orders incomplete and completed by due date and creation order", OrdersList),
        ("Past completed todos stay in day history after leaving the active list", CompletionVisibility),
        ("Unknown IDs are ignored and a confirmed deletion removes calendar history", Deletion),
        ("Malformed files are preserved and future writes are blocked", CorruptFile),
        ("Unsupported schema and missing required fields are preserved", UnsupportedSchema),
        ("A write failure preserves the on-disk file and visible state for a retry", WriteFailure),
        ("A stale store cannot overwrite a newer store's changes", StaleStore),
        ("A deleted store file is not silently recreated with stale data", ExternalDelete),
        ("Editing validates the title, preserves identity, and reports durable changes once", Update),
        ("Editor search shares panel visibility and matches normalized title text in both sort orders", SearchVisible),
        ("Batch completion uses one timestamp and preserves already completed items", SetDone),
        ("Batch deletion is published once and persists all deletions", DeleteMany),
        ("Failed editor mutations preserve the entire snapshot and do not notify", FailedBatch),
        ("Quick add applies the editor title rules before saving", QuickAddTitleRules),
    ];

    private static void IgnoreEmptyTitle()
    {
        WithStore((path, _) =>
        {
            var store = new TodoStore(path);
            Equal(null, store.LoadError);
            Equal(0, store.All.Count);
            Equal(false, store.Add("  \t\r\n "));
            Equal(false, File.Exists(path));
            Equal(false, Directory.Exists(Path.GetDirectoryName(path)));
        });
    }

    private static void LocalDueDateAndRoundTrip()
    {
        WithStore((path, clock) =>
        {
            var store = new TodoStore(path, clock);
            Equal(true, store.Add("  가짜 할 일  "));
            var first = store.All.Single();
            Equal("가짜 할 일", first.Title);
            Equal(Today, first.DueDate);
            Equal(clock.GetLocalNow(), first.CreatedAt);
            Equal(first.CreatedAt, first.UpdatedAt);
            Equal("D-Day", first.DayLabel(Today));
            Equal("D-3", first.DayLabel(Today.AddDays(-3)));
            Equal("D+2", first.DayLabel(Today.AddDays(2)));

            using var doc = JsonDocument.Parse(File.ReadAllBytes(path));
            Equal(1, doc.RootElement.GetProperty("schemaVersion").GetInt32());
            Equal("2026-11-12", doc.RootElement.GetProperty("todos")[0].GetProperty("dueDate").GetString());

            clock.UtcNow = UtcToday.AddDays(1);
            var reopened = new TodoStore(path, clock);
            Equal(first, reopened.All.Single());
            Equal(Today, reopened.All.Single().DueDate);
        });
    }

    private static void OrdersList()
    {
        WithStore((path, clock) =>
        {
            var store = new TodoStore(path, clock);
            store.Add("이틀 뒤", Today.AddDays(2));
            store.Add("오늘 먼저", Today);
            store.Add("오늘 나중", Today);
            store.Add("어제 마감", Today.AddDays(-1));
            var done = store.All[3];
            store.ToggleDone(done.Id);
            Equal("오늘 먼저,오늘 나중,이틀 뒤,어제 마감", string.Join(',', store.Visible(Today).Select(todo => todo.Title)));
            Equal("오늘 먼저,오늘 나중", string.Join(',', store.ForDate(Today).Select(todo => todo.Title)));
        });
    }

    private static void CompletionVisibility()
    {
        WithStore((path, clock) =>
        {
            var store = new TodoStore(path, clock);
            store.Add("기록 확인", Today.AddDays(-2));
            var first = store.All.Single();
            clock.UtcNow = UtcToday.AddHours(1);
            Equal(true, store.ToggleDone(first.Id));
            var completed = store.All.Single();
            Equal(true, completed.IsDone);
            Equal<DateTimeOffset?>(clock.GetLocalNow(), completed.DoneAt);
            Equal(clock.GetLocalNow(), completed.UpdatedAt);
            Equal(first.CreatedAt, completed.CreatedAt);
            Equal(1, store.Visible(Today).Count);
            Equal(0, store.Visible(Today.AddDays(1)).Count);
            Equal(completed, new TodoStore(path, clock).ForDate(first.DueDate).Single());

            clock.UtcNow = UtcToday.AddDays(1);
            Equal(true, store.ToggleDone(first.Id));
            Equal(false, store.All.Single().IsDone);
            Equal(null, store.All.Single().DoneAt);
            Equal(1, store.Visible(Today.AddDays(1)).Count);
        });
    }

    private static void Deletion()
    {
        WithStore((path, clock) =>
        {
            var store = new TodoStore(path, clock);
            Equal(false, store.Delete(Guid.NewGuid()));
            Equal(false, store.ToggleDone(Guid.NewGuid()));
            Equal(false, File.Exists(path));
            store.Add("삭제 확인", Today);
            var item = store.All.Single();
            Equal(true, store.Delete(item.Id));
            Equal(0, new TodoStore(path, clock).ForDate(Today).Count);
            Equal(false, store.Delete(item.Id));
        });
    }

    private static void CorruptFile() => CheckUnchangedAfterReadFailure("{ 깨짐");

    private static void UnsupportedSchema()
    {
        CheckUnchangedAfterReadFailure("{\"schemaVersion\":2,\"todos\":[]}");
        CheckUnchangedAfterReadFailure("{\"schemaVersion\":1,\"todos\":[{\"title\":\"제목만 있음\"}]}");
    }

    private static void CheckUnchangedAfterReadFailure(string content)
    {
        WithStore((path, clock) =>
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, content);
            var store = new TodoStore(path, clock);
            Equal(true, store.LoadError is not null);
            Rejects(() => store.Add("덮어쓰기 금지"));
            Equal(content, File.ReadAllText(path));
            Equal(0, store.All.Count);
        });
    }

    private static void WriteFailure()
    {
        WithStore((path, clock) =>
        {
            var store = new TodoStore(path, clock);
            store.Add("저장된 할 일");
            var before = File.ReadAllText(path);
            using (File.Open(path + ".lock", FileMode.Open, FileAccess.Write, FileShare.None))
            {
                Rejects(() => store.Add("저장 실패"));
                Rejects(() => store.ToggleDone(store.All.Single().Id));
                Rejects(() => store.Delete(store.All.Single().Id));
            }

            Equal(before, File.ReadAllText(path));
            Equal(false, store.All.Single().IsDone);
            Equal(true, store.Add("재시도 성공"));
            Equal(2, new TodoStore(path, clock).All.Count);
            Equal(0, Directory.GetFiles(Path.GetDirectoryName(path)!, "*.tmp").Length);
        });
    }

    private static void StaleStore()
    {
        WithStore((path, clock) =>
        {
            var first = new TodoStore(path, clock);
            var second = new TodoStore(path, clock);
            first.Add("먼저 저장");
            Rejects(() => second.Add("뒤늦게 덮어쓰기"));
            Equal(0, second.All.Count);
            Equal("먼저 저장", new TodoStore(path, clock).All.Single().Title);
        });
    }

    private static void ExternalDelete()
    {
        WithStore((path, clock) =>
        {
            var store = new TodoStore(path, clock);
            store.Add("기존 기록");
            File.Delete(path);
            Rejects(() => store.Add("예전 파일 재생성 금지"));
            Equal(false, File.Exists(path));
            Equal(1, store.All.Count);
        });
    }

    private static void Update()
    {
        WithStore((path, clock) =>
        {
            var store = new TodoStore(path, clock);
            store.Add("수정 전", Today);
            var before = store.All.Single();
            int changes = 0;
            store.Changed += () =>
            {
                changes++;
                Equal(store.All.Single(), new TodoStore(path, clock).All.Single());
            };

            Equal(false, store.Update(before.Id, "  ", Today));
            Equal(false, store.Update(before.Id, new string('가', 201), Today));
            Equal(false, store.Update(before.Id, "첫 줄\n둘째 줄", Today));
            Equal(true, TodoStore.IsValidEditorTitle($"  {new string('가', 200)}  "));
            Equal(false, store.Update(Guid.NewGuid(), "없는 항목", Today));
            Equal(true, store.Update(before.Id, "  수정 전  ", Today));
            Equal(0, changes);
            clock.UtcNow = UtcToday.AddHours(1);
            Equal(true, store.Update(before.Id, "  수정 후  ", Today.AddDays(2)));
            Equal(1, changes);
            Equal(before with { Title = "수정 후", DueDate = Today.AddDays(2), UpdatedAt = clock.GetLocalNow() }, store.All.Single());
            Equal(0, store.ForDate(Today).Count);
        });
    }

    private static void SearchVisible()
    {
        WithStore((path, clock) =>
        {
            var store = new TodoStore(path, clock);
            store.Add("CAFE\u0301 나중 마감", Today.AddDays(5));
            clock.UtcNow = UtcToday.AddMinutes(1);
            store.Add("café 먼저 마감", Today);
            store.Add("다른 제목", Today);
            store.Add("Café 완료", Today.AddDays(-1));
            store.ToggleDone(store.All[^1].Id);
            Equal("café 먼저 마감,CAFE\u0301 나중 마감,Café 완료",
                string.Join(',', store.SearchVisible(Today, "  CAFÉ  ", TodoSortOrder.DueDate).Select(item => item.Title)));
            Equal("CAFE\u0301 나중 마감,café 먼저 마감,Café 완료",
                string.Join(',', store.SearchVisible(Today, "  CAFÉ  ", TodoSortOrder.Added).Select(item => item.Title)));
            Equal(2, store.SearchVisible(Today.AddDays(1), "café", TodoSortOrder.DueDate).Count);
            Equal(0, store.SearchVisible(Today, "일치하지 않음", TodoSortOrder.DueDate).Count);
        });
    }

    private static void SetDone()
    {
        WithStore((path, clock) =>
        {
            var store = new TodoStore(path, clock);
            store.Add("이미 완료", Today);
            store.Add("첫 번째 선택", Today);
            store.Add("두 번째 선택", Today);
            store.Add("선택 안 함", Today);
            store.ToggleDone(store.All[0].Id);
            var before = store.All[0];
            var ids = store.All.Take(3).Select(item => item.Id).ToArray();
            int changes = 0;
            store.Changed += () => changes++;

            clock.UtcNow = UtcToday.AddMinutes(5);
            Equal(true, store.SetDone(ids, true));
            Equal(1, changes);
            Equal(before, store.All[0]);
            Equal<DateTimeOffset?>(clock.GetLocalNow(), store.All[1].DoneAt);
            Equal(store.All[1].DoneAt, store.All[2].DoneAt);
            Equal(false, store.All[3].IsDone);
            Equal(false, store.SetDone(ids, true));
            Equal(1, changes);
            Equal(3, new TodoStore(path, clock).All.Count(item => item.IsDone));

            clock.UtcNow = UtcToday.AddMinutes(10);
            Equal(true, store.SetDone(ids, false));
            Equal(2, changes);
            Equal(true, store.All.All(item => !item.IsDone && item.DoneAt is null));
        });
    }

    private static void DeleteMany()
    {
        WithStore((path, clock) =>
        {
            var store = new TodoStore(path, clock);
            store.Add("지울 항목 1");
            store.Add("남길 항목");
            store.Add("지울 항목 2");
            Guid[] ids = [store.All[0].Id, store.All[2].Id, Guid.NewGuid()];
            int changes = 0;
            store.Changed += () => changes++;

            Equal(true, store.DeleteMany(ids));
            Equal(false, store.DeleteMany(ids));
            Equal(1, changes);
            Equal("남길 항목", new TodoStore(path, clock).All.Single().Title);
        });
    }

    private static void FailedBatch()
    {
        WithStore((path, clock) =>
        {
            var store = new TodoStore(path, clock);
            store.Add("편집 전");
            store.Add("다른 항목");
            var before = store.All;
            var fileBefore = File.ReadAllText(path);
            var ids = before.Select(item => item.Id).ToArray();
            int changes = 0;
            store.Changed += () => changes++;

            using (File.Open(path + ".lock", FileMode.Open, FileAccess.Write, FileShare.None))
            {
                Rejects(() => store.Update(ids[0], "편집 실패", Today));
                Rejects(() => store.SetDone(ids, true));
                Rejects(() => store.DeleteMany(ids));
            }

            Equal(before, store.All);
            Equal(fileBefore, File.ReadAllText(path));
            Equal(0, changes);
        });
    }

    private static void QuickAddTitleRules()
    {
        WithStore((path, clock) =>
        {
            var store = new TodoStore(path, clock);
            int changes = 0;
            store.Changed += () => changes++;

            Equal(false, store.Add(new string('가', 201)));
            Equal(false, store.Add("탭\t포함"));
            Equal(false, store.Add("첫 줄\n둘째 줄"));
            Equal(false, store.Add("첫 줄\r\n둘째 줄"));
            Equal(false, store.Add("줄\u2028구분"));
            Equal(false, store.Add("보이지\u200B않는 문자"));
            const string decomposed = "\u1100\u1161";
            Equal(false, store.Add(string.Concat(Enumerable.Repeat(decomposed, 201))));
            Equal(0, changes);
            Equal(false, File.Exists(path));

            Equal(true, store.Add($"  {new string('가', 200)}  "));
            Equal(new string('가', 200), store.All[^1].Title);
            Equal(true, store.Add(" \t 앞뒤 공백 정리\r\n "));
            Equal("앞뒤 공백 정리", store.All[^1].Title);
            string combined = string.Concat(Enumerable.Repeat(decomposed, 200));
            Equal(400, combined.Length);
            Equal(true, store.Add(combined));
            Equal(combined, store.All[^1].Title);
            Equal(3, changes);
            Equal(3, new TodoStore(path, clock).All.Count);
        });
    }

    private static void WithStore(Action<string, LocalClock> run)
    {
        var root = Directory.CreateTempSubdirectory("doit-todos-");
        try
        {
            run(Path.Combine(root.FullName, "data", "todos.json"), new LocalClock());
        }
        finally
        {
            root.Delete(recursive: true);
        }
    }

    private static void Rejects(Action operation)
    {
        try
        {
            operation();
        }
        catch (TodoStorageException)
        {
            return;
        }

        throw new InvalidOperationException("Expected a storage error.");
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
        public DateTimeOffset UtcNow { get; set; } = UtcToday;
        public override TimeZoneInfo LocalTimeZone { get; } = TimeZoneInfo.CreateCustomTimeZone(
            "DoIt synthetic time zone", TimeSpan.FromHours(9), "DoIt synthetic time zone", "DoIt synthetic time zone");
        public override DateTimeOffset GetUtcNow() => UtcNow;
    }
}
