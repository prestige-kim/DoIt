namespace DoIt.Core;

public sealed record ReminderKinds(bool Todos = true, bool Lms = true);
public sealed record DayReminder(DateOnly Day, DateTimeOffset FireAt, int Count);

public static class ReminderPlanner
{
    public const int HorizonDays = 30;
    // One-shot UI timers accept at most about 24.8 days (Int32 milliseconds).
    // Wake at most once a day and recalculate, so a reminder up to 30 days ahead never overflows.
    public static readonly TimeSpan MaxTimerWait = TimeSpan.FromDays(1);
    private static readonly TimeOnly ReminderTime = new(9, 0);

    public static TimeSpan TimerWait(DateTimeOffset now, DateTimeOffset fireAt)
    {
        var delay = fireAt - now;
        if (delay <= TimeSpan.Zero)
        {
            return TimeSpan.FromMilliseconds(1);
        }
        return delay > MaxTimerWait ? MaxTimerWait : delay;
    }

    public static DayReminder? Next(DateTimeOffset now, TimeZoneInfo localZone,
        IReadOnlyList<TodoItem> todos, IReadOnlyList<LmsRow> currentLms, ReminderKinds kinds, DateOnly? lastShownDay = null)
    {
        var today = LocalDay(now, localZone);
        int days = Math.Min(HorizonDays, DateOnly.MaxValue.DayNumber - today.DayNumber + 1);
        for (int offset = 0; offset < days; offset++)
        {
            var day = today.AddDays(offset);
            if (day == lastShownDay || FireAt(day, localZone) is not { } fireAt || fireAt <= now)
            {
                continue;
            }
            int count = Count(day, fireAt, todos, currentLms, kinds);
            if (count > 0)
            {
                return new DayReminder(day, fireAt, count);
            }
        }
        return null;
    }

    public static DayReminder? DueNow(DateTimeOffset now, TimeZoneInfo localZone,
        IReadOnlyList<TodoItem> todos, IReadOnlyList<LmsRow> currentLms, ReminderKinds kinds, DateOnly? lastShownDay = null)
    {
        var today = LocalDay(now, localZone);
        if (today == lastShownDay || FireAt(today, localZone) is not { } fireAt || now < fireAt)
        {
            return null;
        }
        int count = Count(today, fireAt, todos, currentLms, kinds);
        return count > 0 ? new DayReminder(today, fireAt, count) : null;
    }

    private static int Count(DateOnly day, DateTimeOffset fireAt, IReadOnlyList<TodoItem> todos,
        IReadOnlyList<LmsRow> currentLms, ReminderKinds kinds)
    {
        int personal = kinds.Todos ? todos.Count(item => !item.IsDone && item.DueDate == day && item.CreatedAt < fireAt) : 0;
        int assignments = kinds.Lms ? currentLms.Count(row => row.DoneAt is null && row.Item.DueDate == day) : 0;
        return personal + assignments;
    }

    private static DateOnly LocalDay(DateTimeOffset instant, TimeZoneInfo zone) =>
        DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(instant, zone).DateTime);

    private static DateTimeOffset? FireAt(DateOnly day, TimeZoneInfo zone)
    {
        var wallTime = day.ToDateTime(ReminderTime);
        return zone.IsInvalidTime(wallTime) ? null : new DateTimeOffset(wallTime, zone.GetUtcOffset(wallTime));
    }
}
