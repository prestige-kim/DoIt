namespace DoIt.Core;

// Startup stages in the order the app runs them. The number is shown to the user and used in exit codes.
public enum StartupStage
{
    Instance = 1,
    DataFolder = 2,
    TodoStore = 3,
    Lms = 4,
    Notifications = 5,
    Reminders = 6,
    History = 7,
    Tray = 8,
    Start = 9,
}

[Flags]
public enum CleanupFailure
{
    None = 0,
    ReminderTask = 1,
    NotificationRegistration = 2,
    Unexpected = 4,
}

public static class StartupDiagnostics
{
    // 10 + stage for an ordinary or reminder-only start; 30 + flags for --uninstall-cleanup.
    public const int StageExitBase = 10;
    public const int CleanupExitBase = 30;

    public static string StageName(StartupStage stage) => stage switch
    {
        StartupStage.Instance => "인스턴스 확인",
        StartupStage.DataFolder => "데이터 폴더",
        StartupStage.TodoStore => "할 일 저장소",
        StartupStage.Lms => "LMS",
        StartupStage.Notifications => "알림",
        StartupStage.Reminders => "알림 예약",
        StartupStage.History => "기록",
        StartupStage.Tray => "트레이 아이콘",
        StartupStage.Start => "시작",
        _ => "알 수 없음",
    };

    public static int ExitCode(StartupStage stage) => StageExitBase + (int)stage;

    public static int CleanupExitCode(CleanupFailure failure) =>
        failure == CleanupFailure.None ? 0 : CleanupExitBase + (int)failure;

    // Only the stage, exception type names and HRESULT. Exception messages can contain paths or user data.
    public static string Describe(StartupStage stage, Exception error)
    {
        string type = error.GetType().Name;
        if (error.InnerException is { } inner)
        {
            type += ">" + inner.GetType().Name;
        }
        return $"{(int)stage}단계 {StageName(stage)} · {type} · 0x{error.HResult:X8}";
    }
}
