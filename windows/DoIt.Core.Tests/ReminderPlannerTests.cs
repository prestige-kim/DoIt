using System.Text.Json;
using DoIt.Core;

internal static class ReminderPlannerTests
{
    private static readonly TimeSpan SeoulOffset = TimeSpan.FromHours(9);
    private static readonly TimeZoneInfo Zone = TimeZoneInfo.CreateCustomTimeZone("Test Seoul", SeoulOffset, "Test Seoul", "Test Seoul");
    private static readonly DateOnly Today = new(2026, 12, 31);
    private static readonly DateTimeOffset Nine = At(Today, 9, 0);

    internal static (string Name, Action Run)[] Cases =>
    [
        ("Reminders aggregate counts and carry no personal or LMS title metadata", CountOnly),
        ("Reminder kinds enable personal and LMS counts independently", KindSettings),
        ("Reminder catches up at or after nine only for today", WakeCatchUp),
        ("Reminder omits personal work added at or after today's nine", CreatedBeforeNine),
        ("Reminder does not plan or show again on the recorded day", DuplicateSuppression),
        ("Next reminder follows the local day across a year boundary and stays within 30 days", Horizon),
        ("Timer wait stays within one day for reminders up to 30 days ahead", TimerWaitLimit),
    ];

    private static void TimerWaitLimit()
    {
        var kinds = new ReminderKinds();
        var lastDay = Today.AddDays(29);
        var now = Nine.AddMinutes(1);
        var next = ReminderPlanner.Next(now, Zone, [Todo(lastDay)], [], kinds)
            ?? throw new InvalidOperationException("Expected a reminder 29 days ahead.");
        Equal(true, next.FireAt - now > TimeSpan.FromMilliseconds(int.MaxValue));
        Equal(TimeSpan.FromDays(1), ReminderPlanner.TimerWait(now, next.FireAt));
        Equal(true, ReminderPlanner.TimerWait(now, next.FireAt).TotalMilliseconds <= int.MaxValue);
        Equal(TimeSpan.FromHours(3), ReminderPlanner.TimerWait(now, now.AddHours(3)));
        Equal(TimeSpan.FromMilliseconds(1), ReminderPlanner.TimerWait(now, now));
        Equal(TimeSpan.FromMilliseconds(1), ReminderPlanner.TimerWait(now, now.AddMinutes(-5)));
        // An early wake before the planned nine must not show anything.
        Equal<DayReminder?>(null, ReminderPlanner.DueNow(now.AddDays(1), Zone, [Todo(lastDay)], [], kinds));
    }

    private static void CountOnly()
    {
        var todos = new[] { Todo(Today), Todo(Today, done: true), Todo(Today.AddDays(1)) };
        var lms = new[] { Lms(Today), Lms(Today, done: true), Lms(Today.AddDays(1)) };
        var reminder = ReminderPlanner.Next(Nine.AddMinutes(-1), Zone, todos, lms, new ReminderKinds());
        Equal(new DayReminder(Today, Nine, 2), reminder);
        var serialized = JsonSerializer.Serialize(reminder);
        Equal(false, serialized.Contains("synthetic-title", StringComparison.Ordinal));
        Equal(false, serialized.Contains("synthetic-course", StringComparison.Ordinal));
        Equal(false, serialized.Contains("event-assignment", StringComparison.Ordinal));
    }

    private static void KindSettings()
    {
        var todos = new[] { Todo(Today), Todo(Today) };
        var lms = new[] { Lms(Today) };
        var now = Nine.AddHours(2);
        Equal(2, ReminderPlanner.DueNow(now, Zone, todos, lms, new ReminderKinds(Lms: false))?.Count);
        Equal(1, ReminderPlanner.DueNow(now, Zone, todos, lms, new ReminderKinds(Todos: false))?.Count);
        Equal<DayReminder?>(null, ReminderPlanner.DueNow(now, Zone, todos, lms, new ReminderKinds(Todos: false, Lms: false)));
    }

    private static void WakeCatchUp()
    {
        var todos = new[] { Todo(Today) };
        var kinds = new ReminderKinds();
        Equal<DayReminder?>(null, ReminderPlanner.DueNow(Nine.AddTicks(-1), Zone, todos, [], kinds));
        Equal(new DayReminder(Today, Nine, 1), ReminderPlanner.DueNow(Nine, Zone, todos, [], kinds));
        Equal(new DayReminder(Today, Nine, 1), ReminderPlanner.DueNow(Nine.AddHours(5).ToUniversalTime(), Zone, todos, [], kinds));
        Equal<DayReminder?>(null, ReminderPlanner.DueNow(Nine.AddDays(1), Zone, todos, [], kinds));
    }

    private static void CreatedBeforeNine()
    {
        var todos = new[] { Todo(Today, createdAt: Nine.AddTicks(-1)), Todo(Today, createdAt: Nine), Todo(Today, createdAt: Nine.AddMinutes(1)) };
        var next = ReminderPlanner.DueNow(Nine.AddHours(2), Zone, todos, [], new ReminderKinds());
        Equal(1, next?.Count);
    }

    private static void DuplicateSuppression()
    {
        var kinds = new ReminderKinds();
        var todos = new[] { Todo(Today), Todo(Today.AddDays(1)) };
        Equal<DayReminder?>(null, ReminderPlanner.DueNow(Nine.AddHours(3), Zone, todos, [], kinds, lastShownDay: Today));
        Equal(Today.AddDays(1), ReminderPlanner.Next(Nine.AddHours(-1), Zone, todos, [], kinds, lastShownDay: Today)?.Day);
    }

    private static void Horizon()
    {
        var kinds = new ReminderKinds();
        var nextDay = Today.AddDays(1);
        Equal(new DayReminder(nextDay, At(nextDay, 9, 0), 1), ReminderPlanner.Next(Nine, Zone, [Todo(nextDay)], [], kinds));
        var lastDay = Today.AddDays(29);
        Equal(lastDay, ReminderPlanner.Next(Nine, Zone, [Todo(lastDay)], [], kinds)?.Day);
        Equal<DayReminder?>(null, ReminderPlanner.Next(Nine, Zone, [Todo(Today.AddDays(30))], [], kinds));
    }

    private static TodoItem Todo(DateOnly date, bool done = false, DateTimeOffset? createdAt = null)
    {
        var created = createdAt ?? Nine.AddDays(-1);
        return new TodoItem(Guid.NewGuid(), "synthetic-title", date, created, created, done, done ? created : null);
    }

    private static LmsRow Lms(DateOnly date, bool done = false) =>
        new(new LmsItem("event-assignment-1", "synthetic-title", "synthetic-course", date, null), done ? Nine.AddDays(-1) : null);

    private static DateTimeOffset At(DateOnly day, int hour, int minute) => new(day.ToDateTime(new TimeOnly(hour, minute)), SeoulOffset);

    private static void Equal<T>(T expected, T actual)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
        {
            throw new InvalidOperationException($"Expected {expected}, got {actual}.");
        }
    }
}
