using System.IO;
using System.Text.Json;
using System.Windows.Threading;
using DoIt.Core;

namespace DoIt.Windows;

internal sealed record ReminderPreferences(bool Todos = true, bool Lms = true, bool Paused = false, DateOnly? LastShown = null);

internal sealed class ReminderController : IDisposable
{
    private readonly string settingsPath;
    private readonly TodoStore todos;
    private readonly LmsService lms;
    private readonly NotificationCenter notificationCenter;
    private readonly ClosedReminderTask? closedTask;
    private readonly DispatcherTimer nextTimer;
    private ReminderPreferences preferences = new();
    private bool cannotReadSettings;
    private bool saveFailed;
    private bool closedTaskFailed;
    private bool disposed;

    internal ReminderController(string dataDirectory, TodoStore todos, LmsService lms, NotificationCenter notificationCenter,
        string? executable, Dispatcher dispatcher)
    {
        this.todos = todos;
        this.lms = lms;
        this.notificationCenter = notificationCenter;
        settingsPath = Path.Combine(dataDirectory, "reminder-settings.json");
        if (executable is not null) closedTask = new ClosedReminderTask(executable);
        nextTimer = new DispatcherTimer(DispatcherPriority.Background, dispatcher);
        nextTimer.Tick += OnTimer;

        try
        {
            preferences = JsonSerializer.Deserialize<ReminderPreferences>(File.ReadAllBytes(settingsPath))
                ?? throw new JsonException();
        }
        catch (Exception error) when (error is FileNotFoundException or DirectoryNotFoundException) { }
        catch (Exception error) when (IsSettingsError(error)) { cannotReadSettings = true; }
    }

    internal ReminderPreferences Preferences => preferences;
    internal string? Status => cannotReadSettings ? "알림 설정 파일을 읽지 못했습니다."
        : saveFailed ? "알림 설정을 저장하지 못했습니다."
        : notificationCenter.UnavailableReason
        ?? (closedTaskFailed ? "앱을 닫았을 때 사용할 Windows 예약을 변경하지 못했습니다." : null);
    internal bool CanEdit => !cannotReadSettings;
    internal bool CanTest => notificationCenter.UnavailableReason is null;
    internal event Action? Changed;

    internal bool SetPreferences(bool personal, bool lmsAssignments, bool paused)
    {
        if (cannotReadSettings || !Save(preferences with { Todos = personal, Lms = lmsAssignments, Paused = paused }))
        {
            Changed?.Invoke();
            return false;
        }
        Recalculate();
        return true;
    }

    internal void Start(bool background)
    {
        if (closedTask is not null) closedTaskFailed = !closedTask.Replace(null);
        Recalculate(background);
    }

    internal DayReminder? Preview() => Available ? Next(DateTimeOffset.UtcNow) : null;

    internal bool SendTest() => notificationCenter.Show(1, test: true);

    internal void Recalculate(bool background = false)
    {
        nextTimer.Stop();
        if (disposed || !Available)
        {
            Changed?.Invoke();
            return;
        }
        var now = DateTimeOffset.UtcNow;
        var kinds = new ReminderKinds(preferences.Todos, preferences.Lms);
        if (notificationCenter.UnavailableReason is null
            && ReminderPlanner.DueNow(now, TimeZoneInfo.Local, todos.All, lms.Current, kinds, preferences.LastShown) is { } due)
        {
            var previous = preferences;
            // Reserve the day before external delivery so an abrupt exit cannot duplicate it.
            if (Save(previous with { LastShown = due.Day }) && !notificationCenter.Show(due.Count))
            {
                Save(previous);
            }
        }
        if (!background && Next(now) is { } next)
        {
            // An early wake only recalculates; DueNow shows nothing before the planned day's nine.
            nextTimer.Interval = ReminderPlanner.TimerWait(DateTimeOffset.UtcNow, next.FireAt);
            nextTimer.Start();
        }
        Changed?.Invoke();
    }

    private bool Available => !cannotReadSettings && !preferences.Paused && (preferences.Todos || preferences.Lms);

    private DayReminder? Next(DateTimeOffset now) => ReminderPlanner.Next(now, TimeZoneInfo.Local, todos.All,
        lms.Current, new ReminderKinds(preferences.Todos, preferences.Lms), preferences.LastShown);

    private void OnTimer(object? sender, EventArgs e)
    {
        nextTimer.Stop();
        Recalculate();
    }

    private bool Save(ReminderPreferences value)
    {
        try
        {
            LmsLocalFile.WriteAtomic(settingsPath, JsonSerializer.SerializeToUtf8Bytes(value));
            preferences = value;
            saveFailed = false;
            return true;
        }
        catch (Exception error) when (IsSettingsError(error))
        {
            saveFailed = true;
            return false;
        }
    }

    private static bool IsSettingsError(Exception error) => error is JsonException or IOException or UnauthorizedAccessException;

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        nextTimer.Stop();
        nextTimer.Tick -= OnTimer;
        if (closedTask is not null)
        {
            closedTask.Replace(Available ? Next(DateTimeOffset.UtcNow) : null);
        }
    }
}
