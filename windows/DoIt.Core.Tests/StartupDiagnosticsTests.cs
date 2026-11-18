using System.ComponentModel;
using DoIt.Core;

internal static class StartupDiagnosticsTests
{
    internal static (string Name, Action Run)[] Cases =>
    [
        ("Startup diagnostics show stage, type names and HRESULT without the exception message", DescribeOnlySafeParts),
        ("Startup stages keep the run order and map to distinct exit codes", StageOrderAndExitCodes),
        ("Uninstall cleanup exit codes separate reminder, registration and unexpected failures", CleanupExitCodes),
    ];

    private static void DescribeOnlySafeParts()
    {
        var error = new UnauthorizedAccessException(@"C:\Users\synthetic-user\AppData\Local\DoIt synthetic-title");
        var text = StartupDiagnostics.Describe(StartupStage.Instance, error);
        Equal("1단계 인스턴스 확인 · UnauthorizedAccessException · 0x80070005", text);
        Equal(false, text.Contains("synthetic", StringComparison.Ordinal));
        Equal(false, text.Contains(@"C:\", StringComparison.Ordinal));

        var wrapped = new TypeInitializationException("Synthetic.Type", new Win32Exception(5, "synthetic message"));
        var nested = StartupDiagnostics.Describe(StartupStage.Tray, wrapped);
        Equal(true, nested.StartsWith("8단계 트레이 아이콘 · TypeInitializationException>Win32Exception · 0x", StringComparison.Ordinal));
        Equal(false, nested.Contains("synthetic", StringComparison.OrdinalIgnoreCase));
    }

    private static void StageOrderAndExitCodes()
    {
        var stages = Enum.GetValues<StartupStage>();
        Equal(9, stages.Length);
        string[] names = ["인스턴스 확인", "데이터 폴더", "할 일 저장소", "LMS", "알림", "알림 예약", "기록", "트레이 아이콘", "시작"];
        for (int index = 0; index < stages.Length; index++)
        {
            Equal(index + 1, (int)stages[index]);
            Equal(names[index], StartupDiagnostics.StageName(stages[index]));
            Equal(11 + index, StartupDiagnostics.ExitCode(stages[index]));
        }
        Equal(stages.Length, stages.Select(StartupDiagnostics.ExitCode).Distinct().Count());
    }

    private static void CleanupExitCodes()
    {
        Equal(0, StartupDiagnostics.CleanupExitCode(CleanupFailure.None));
        Equal(31, StartupDiagnostics.CleanupExitCode(CleanupFailure.ReminderTask));
        Equal(32, StartupDiagnostics.CleanupExitCode(CleanupFailure.NotificationRegistration));
        Equal(33, StartupDiagnostics.CleanupExitCode(CleanupFailure.ReminderTask | CleanupFailure.NotificationRegistration));
        Equal(34, StartupDiagnostics.CleanupExitCode(CleanupFailure.Unexpected));
        // Cleanup codes never collide with startup stage codes (11~19).
        Equal(false, Enum.GetValues<StartupStage>().Select(StartupDiagnostics.ExitCode).Contains(31));
    }

    private static void Equal<T>(T expected, T actual)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
        {
            throw new InvalidOperationException($"Expected {expected}, got {actual}.");
        }
    }
}
