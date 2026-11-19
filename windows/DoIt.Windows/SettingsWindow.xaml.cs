using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Threading;
using DoIt.Core;
using Microsoft.Win32;

namespace DoIt.Windows;

public partial class SettingsWindow : Window
{
    private readonly LmsService lms;
    private readonly HistoryService history;
    private readonly Action<bool> refreshLms;
    private readonly ReminderController reminders;
    private readonly InstalledStartup startup;
    private readonly UpdateService? updates;
    private const string OpenFailedMessage = "브라우저를 열지 못했습니다. DoIt 홈페이지에서 Windows 설치 안내를 확인해 주세요.";
    private bool refreshing;
    private readonly RadioButton[] retentionButtons;
    private readonly ScrollViewer[] pages;
    private bool resetConfirmed;
    private static readonly HistoryRetention[] Retentions =
        [HistoryRetention.SixMonths, HistoryRetention.OneYear, HistoryRetention.TwoYears, HistoryRetention.Forever];

    internal SettingsWindow(LmsService lms, HistoryService history, Action<bool> refreshLms,
        ReminderController reminders, InstalledStartup startup, UpdateService? updates)
    {
        this.lms = lms;
        this.history = history;
        this.refreshLms = refreshLms;
        this.reminders = reminders;
        this.startup = startup;
        this.updates = updates;
        InitializeComponent();
        retentionButtons = [RetentionSixMonths, RetentionOneYear, RetentionTwoYears, RetentionForever];
        pages = [GeneralPage, LmsPage, ReminderPage, HistoryPage, StoragePage];
        VersionLabel.Text = VersionText(typeof(SettingsWindow).Assembly);
        SourceInitialized += (_, _) => ApplyTitleBarTheme();
        SystemEvents.UserPreferenceChanged += OnPreferenceChanged;
        Closed += (_, _) =>
        {
            SystemEvents.UserPreferenceChanged -= OnPreferenceChanged;
            CloseAddressEditor();
        };
        ShowSection();
        RefreshLmsState();
        RefreshHistorySummary();
        RenderStorage();
        RefreshStartup();
        RefreshReminders();
        RefreshUpdateState();
    }

    internal void RefreshUpdateState()
    {
        if (updates is null)
        {
            AutoUpdateCheck.IsEnabled = CheckUpdateButton.IsEnabled = false;
            DownloadUpdateButton.Visibility = Visibility.Collapsed;
            UpdateStatus.Text = "새 버전 확인을 사용할 수 없습니다.";
            UpdateStatus.SetResourceReference(TextBlock.ForegroundProperty, "DoIt.Muted");
            UpdateDetail.Text = "";
            return;
        }
        var snapshot = updates.Snapshot;
        AutoUpdateCheck.IsChecked = snapshot.AutoCheck;
        AutoUpdateCheck.IsEnabled = !snapshot.IsDevelopmentBuild;
        CheckUpdateButton.IsEnabled = !snapshot.IsDevelopmentBuild && !snapshot.IsChecking;
        DownloadUpdateButton.Visibility = snapshot.DownloadUrl is null ? Visibility.Collapsed : Visibility.Visible;
        if (snapshot.Available is { } available)
        {
            DownloadUpdateButton.Content = $"새 버전 받기 ({available.Version})";
        }
        UpdateStatus.Text = UpdateDisplay.Status(snapshot);
        UpdateStatus.SetResourceReference(TextBlock.ForegroundProperty,
            snapshot.Available is null ? "DoIt.Muted" : "DoIt.Green");
        UpdateDetail.Text = UpdateDisplay.LastChecked(snapshot, TimeZoneInfo.Local);
    }

    private void ToggleAutoUpdate(object sender, RoutedEventArgs e)
    {
        if (updates is null) return;
        bool enable = AutoUpdateCheck.IsChecked == true;
        UpdateError.Text = updates.SetAutoCheck(enable) ? "" : "설정을 저장하지 못했습니다. 다시 시도해 주세요.";
        RefreshUpdateState();
        if (enable)
        {
            RunUpdateCheck(updates, manual: false);
        }
    }

    internal void RefreshStartup()
    {
        StartOnLogin.IsEnabled = startup.Executable is not null;
        StartOnLogin.IsChecked = startup.Enabled;
        StartupStatus.Text = startup.Executable is null ? "로그인 시작은 설치한 DoIt에서 설정할 수 있습니다." : "";
    }

    private void ToggleStartup(object sender, RoutedEventArgs e)
    {
        bool changed = startup.SetEnabled(StartOnLogin.IsChecked == true);
        RefreshStartup();
        if (!changed) StartupStatus.Text = "로그인 시작 설정을 바꾸지 못했습니다.";
    }

    internal void RefreshReminders()
    {
        var preferences = reminders.Preferences;
        TodoReminders.IsEnabled = LmsReminders.IsEnabled = PauseReminders.IsEnabled = reminders.CanEdit;
        TodoReminders.IsChecked = preferences.Todos;
        LmsReminders.IsChecked = preferences.Lms;
        PauseReminders.IsChecked = preferences.Paused;
        TestReminderButton.IsEnabled = reminders.CanTest;
        var korean = CultureInfo.GetCultureInfo("ko-KR");
        NextReminder.Text = reminders.Preview() is { } next
            ? $"다음 알림 {next.FireAt.LocalDateTime.ToString("M월 d일 (ddd) 오전 9시", korean)} · 마감 {next.Count}개"
            : "예정된 마감 알림이 없습니다.";
        ReminderStatus.Text = reminders.Status ?? "";
    }

    private void ToggleReminders(object sender, RoutedEventArgs e) => reminders.SetPreferences(
        TodoReminders.IsChecked == true, LmsReminders.IsChecked == true, PauseReminders.IsChecked == true);

    private void TestReminder(object sender, RoutedEventArgs e)
    {
        ReminderStatus.Text = reminders.SendTest() ? "테스트 알림을 보냈습니다. Windows 알림 센터에서 확인해 주세요."
            : reminders.Status ?? "테스트 알림을 보내지 못했습니다.";
    }

    internal void RefreshLmsState()
    {
        var snapshot = lms.Snapshot;
        refreshing = true;
        try
        {
            EnableLms.IsChecked = snapshot.Enabled;
            EnableLms.IsEnabled = snapshot.HasFeedAddress && !snapshot.DisconnectPending;
            WeeksValue.Text = $"{snapshot.Weeks}주";
            FewerWeeksButton.IsEnabled = snapshot.Weeks > 1;
            MoreWeeksButton.IsEnabled = snapshot.Weeks < LmsDisplay.MaxWeeks;
            FeedLabel.Text = snapshot.HasFeedAddress ? "주소 자체가 비밀번호와 같아요. 다시 보여 주지 않아요."
                : "LMS 달력에서 발급받은 개인 캘린더 피드 주소를 입력해 주세요.";
            FeedSaved.Visibility = snapshot.HasFeedAddress ? Visibility.Visible : Visibility.Collapsed;
            EditAddressButton.Content = snapshot.HasFeedAddress ? "변경…" : "피드 주소 입력";
            AutomationProperties.SetName(EditAddressButton, snapshot.HasFeedAddress ? "피드 주소 변경" : "피드 주소 입력");
            EditAddressButton.IsEnabled = !snapshot.DisconnectPending;
            DisconnectButton.IsEnabled = snapshot.HasFeedAddress || snapshot.DisconnectPending;
            RefreshButton.IsEnabled = snapshot is { Enabled: true, HasFeedAddress: true, IsSyncing: false, DisconnectPending: false };
            LmsStatus.Text = LmsSection.StatusLabel(snapshot);
            var korean = CultureInfo.GetCultureInfo("ko-KR");
            LastRefresh.Text = snapshot.LastSuccessAt is { } updated
                ? $"마지막 동기화 {updated.LocalDateTime.ToString("g", korean)}"
                : "마지막 동기화 없음";
            if (snapshot.Status == LmsSyncStatus.RateLimited && snapshot.RetryAt is { } retry)
            {
                LastRefresh.Text += $" · {retry.LocalDateTime.ToString("g", korean)} 이후 새로고침 가능";
            }
        }
        finally
        {
            refreshing = false;
        }
    }

    internal void ShowHistory() => Sections.SelectedItem = HistoryTab;

    private void ChangeSection(object sender, SelectionChangedEventArgs e) => ShowSection();

    // The sidebar replaces the old tabs: only the selected page is shown.
    private void ShowSection()
    {
        if (pages is null)
        {
            return; // InitializeComponent selects the first item before the pages exist.
        }
        if (Sections.SelectedIndex < 0)
        {
            Sections.SelectedIndex = 0;
            return;
        }
        for (int index = 0; index < pages.Length; index++)
        {
            pages[index].Visibility = index == Sections.SelectedIndex ? Visibility.Visible : Visibility.Collapsed;
        }
    }

    internal void RefreshHistorySummary()
    {
        var summary = history.Preview();
        refreshing = true;
        try
        {
            int selected = Array.IndexOf(Retentions, history.Retention);
            for (int index = 0; index < retentionButtons.Length; index++)
            {
                retentionButtons[index].IsChecked = index == selected;
            }
            CleanupCount.Text = $"정리 대상 {summary.TotalCount}개";
            CleanupDetail.Text = $"내 할 일 {summary.TodoCount}개, LMS {summary.LmsCount}개";
            CleanupButton.IsEnabled = summary.TotalCount > 0;
            RefreshArchiveButton();
            if (summary.TotalCount == 0)
            {
                CleanupEditor.Visibility = Visibility.Collapsed;
            }
        }
        finally
        {
            refreshing = false;
        }
    }

    private void ToggleLms(object sender, RoutedEventArgs e)
    {
        bool enable = EnableLms.IsChecked == true;
        var saved = lms.SetEnabled(enable);
        LmsError.Text = saved ? "" : "연동 상태를 바꾸지 못했습니다. 다시 시도해 주세요.";
        RefreshLmsState();
        if (enable && saved)
        {
            refreshLms(false);
        }
    }

    private void FewerWeeks(object sender, RoutedEventArgs e) => ChangeWeeks(-1);

    private void MoreWeeks(object sender, RoutedEventArgs e) => ChangeWeeks(1);

    private void ChangeWeeks(int step)
    {
        int weeks = lms.Snapshot.Weeks + step;
        if (refreshing || weeks < 1 || weeks > LmsDisplay.MaxWeeks)
        {
            return;
        }
        var saved = lms.SetWeeks(weeks);
        LmsError.Text = saved ? "" : "가져올 기간을 저장하지 못했습니다. 다시 시도해 주세요.";
        RefreshLmsState();
    }

    private void EditAddress(object sender, RoutedEventArgs e)
    {
        DisconnectEditor.Visibility = Visibility.Collapsed;
        LmsError.Text = "";
        FeedAddressBox.Clear();
        AddressEditor.Visibility = Visibility.Visible;
        FeedAddressBox.Focus();
    }

    private void SaveAddress(object sender, RoutedEventArgs e)
    {
        bool saved;
        try
        {
            saved = lms.SaveAddress(FeedAddressBox.Password);
        }
        finally
        {
            FeedAddressBox.Clear();
        }
        LmsError.Text = saved ? "" : "피드 주소를 저장하지 못했습니다. LMS에서 발급한 개인 HTTPS 캘린더 주소인지 확인해 주세요.";
        if (saved)
        {
            CloseAddressEditor();
            if (lms.Snapshot.Enabled)
            {
                refreshLms(false);
            }
        }
        else
        {
            FeedAddressBox.Focus();
        }
        RefreshLmsState();
    }

    private void CancelAddress(object sender, RoutedEventArgs e) => CloseAddressEditor();

    private void CloseAddressEditor()
    {
        FeedAddressBox.Clear();
        AddressEditor.Visibility = Visibility.Collapsed;
    }

    private void ConfirmDisconnect(object sender, RoutedEventArgs e)
    {
        CloseAddressEditor();
        DisconnectEditor.Visibility = Visibility.Visible;
    }

    private void CancelDisconnect(object sender, RoutedEventArgs e) => DisconnectEditor.Visibility = Visibility.Collapsed;

    private void Disconnect(object sender, RoutedEventArgs e)
    {
        bool removed = lms.Disconnect();
        LmsError.Text = removed ? "" : "연결 해제를 끝내지 못했습니다. 다시 시도해 주세요.";
        DisconnectEditor.Visibility = Visibility.Collapsed;
        RefreshLmsState();
    }

    private void RefreshLms(object sender, RoutedEventArgs e)
    {
        LmsError.Text = "";
        refreshLms(true);
    }

    private void ChangeRetention(object sender, RoutedEventArgs e)
    {
        int selected = retentionButtons is null ? -1 : Array.IndexOf(retentionButtons, sender);
        if (refreshing || selected < 0)
        {
            return;
        }
        try
        {
            history.SetRetention(Retentions[selected]);
            HistoryStatus.Text = "";
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            HistoryStatus.Text = "보관 기간을 저장하지 못했습니다. 이전 설정은 그대로입니다.";
        }
        RefreshHistorySummary();
    }

    private void ConfirmCleanup(object sender, RoutedEventArgs e)
    {
        ResetEditor.Visibility = Visibility.Collapsed;
        CleanupEditor.Visibility = Visibility.Visible;
    }

    private void ConfirmReset(object sender, RoutedEventArgs e)
    {
        CleanupEditor.Visibility = Visibility.Collapsed;
        resetConfirmed = false;
        var summary = history.PreviewReset();
        ResetPrompt.Text = $"완료한 할 일 {summary.TodoCount}개와 LMS 기록 {summary.LmsCount}개를 초기화할까요? 초기화 전 백업을 만듭니다.";
        ResetButton.Content = "계속";
        ResetEditor.Visibility = Visibility.Visible;
    }

    private void CancelCleanup(object sender, RoutedEventArgs e) => CloseHistoryEditors();

    private void CleanupWithBackup(object sender, RoutedEventArgs e) => ShowCleanupResult(() => history.Clean(backup: true));

    private void CleanupWithoutBackup(object sender, RoutedEventArgs e) => ShowCleanupResult(() => history.Clean(backup: false));

    private void ResetHistory(object sender, RoutedEventArgs e)
    {
        if (!resetConfirmed)
        {
            resetConfirmed = true;
            ResetPrompt.Text = "기록을 초기화합니다. 미완료 할 일과 LMS 연결은 유지됩니다. 진행할까요?";
            ResetButton.Content = "초기화 확인";
            return;
        }
        ShowCleanupResult(history.Reset);
    }

    private void ShowCleanupResult(Func<HistoryCleanupResult> run)
    {
        CloseHistoryEditors();
        string? archiveBefore = history.LastArchivePath;
        var result = run();
        bool backedUp = history.LastArchivePath is { } archive && archive != archiveBefore;
        HistoryStatus.Text = result.Succeeded
            ? $"내 할 일 {result.RemovedTodos}개와 LMS 기록 {result.RemovedLms}개를 정리했습니다."
            : $"정리를 끝내지 못했습니다. 지금까지 내 할 일 {result.RemovedTodos}개, LMS 기록 {result.RemovedLms}개를 정리했습니다.";
        if (backedUp)
        {
            HistoryStatus.Text += " 백업은 DoIt 데이터 폴더의 archive 폴더에 저장했습니다.";
        }
        RefreshHistorySummary();
        RenderStorage();
    }

    private void RefreshArchiveButton() => OpenArchiveButton.IsEnabled = Directory.Exists(history.ArchiveDirectory);

    private void OpenArchive(object sender, RoutedEventArgs e)
    {
        RefreshArchiveButton();
        if (OpenArchiveButton.IsEnabled && !ShellOpen(history.ArchiveDirectory))
        {
            HistoryStatus.Text = "백업 폴더를 열지 못했습니다.";
        }
    }

    private void CheckForUpdate(object sender, RoutedEventArgs e)
    {
        UpdateError.Text = "";
        if (updates is not null)
        {
            RunUpdateCheck(updates, manual: true);
        }
    }

    private void DownloadUpdate(object sender, RoutedEventArgs e)
    {
        UpdateError.Text = updates?.Snapshot.DownloadUrl is { } url && ShellOpen(url.AbsoluteUri) ? "" : OpenFailedMessage;
    }

    internal void ShowUpdateError() => UpdateError.Text = OpenFailedMessage;

    // The service raises Changed with the result. Failures become a short status, never an exception.
    internal static async void RunUpdateCheck(UpdateService service, bool manual)
    {
        try
        {
            await service.CheckAsync(manual);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException
            or ObjectDisposedException or OperationCanceledException or InvalidOperationException)
        {
            // An update check never interrupts the app.
        }
    }

    internal static bool ShellOpen(string target)
    {
        try
        {
            using var process = Process.Start(new ProcessStartInfo { FileName = target, UseShellExecute = true });
            return true;
        }
        catch (Exception exception) when (exception is Win32Exception or InvalidOperationException
            or FileNotFoundException or PlatformNotSupportedException or ObjectDisposedException)
        {
            return false;
        }
    }

    // The packaging script sets Version and FileVersion=<version>.<build>. A local build has build 0.
    internal static (string Version, int Build) ReadVersion(Assembly assembly)
    {
        string? informational = assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
        string version = informational?.Split('+', 2)[0] is { Length: > 0 } trimmed
            ? trimmed
            : assembly.GetName().Version?.ToString(3) ?? "";
        int build = Version.TryParse(assembly.GetCustomAttribute<AssemblyFileVersionAttribute>()?.Version, out var fileVersion)
            ? fileVersion.Revision
            : 0;
        return (version, Math.Max(build, 0));
    }

    internal static string VersionText(Assembly assembly)
    {
        var (version, build) = ReadVersion(assembly);
        string detail = build > 0 ? $"빌드 {build}" : "개발 빌드";
        return version.Length > 0 ? $"DoIt 버전 {version} ({detail})" : $"DoIt ({detail})";
    }

    private void CloseHistoryEditors()
    {
        CleanupEditor.Visibility = Visibility.Collapsed;
        ResetEditor.Visibility = Visibility.Collapsed;
        resetConfirmed = false;
    }

    private void RefreshStorage(object sender, RoutedEventArgs e) => RenderStorage();

    private void RenderStorage()
    {
        var entries = history.Storage();
        StorageRows.ItemsSource = entries
            .Select(entry => new StorageRow(entry.Name, $"{entry.ItemCount:N0}개", $"{entry.Bytes:N0}바이트"))
            .ToArray();
        StorageTotal.Text = $"{entries.Sum(entry => entry.Bytes):N0}바이트";
        StorageCleanup.Text = $"{history.Preview().TotalCount}개";
        StorageMemory.Text = $"{history.MemoryBytes / (1024 * 1024):N0}MB";
    }

    // One row of the storage table. Public so WPF binding can read it.
    public sealed record StorageRow(string Name, string Count, string Size);

    // Windows draws the title bar. Match it to DoIt's light or dark colors (DWMWA_USE_IMMERSIVE_DARK_MODE).
    private void ApplyTitleBarTheme()
    {
        nint handle = new WindowInteropHelper(this).Handle;
        if (handle == 0)
        {
            return;
        }
        int dark = AppTheme.IsLight ? 0 : 1;
        try
        {
            _ = DwmSetWindowAttribute(handle, ImmersiveDarkMode, ref dark, sizeof(int));
        }
        catch (Exception exception) when (exception is DllNotFoundException or EntryPointNotFoundException)
        {
            // Older Windows keeps its default title bar.
        }
    }

    // AppTheme swaps the colors on the same event; run after it so IsLight is current.
    private void OnPreferenceChanged(object sender, UserPreferenceChangedEventArgs e)
    {
        if (!Dispatcher.HasShutdownStarted)
        {
            Dispatcher.BeginInvoke(DispatcherPriority.Background, ApplyTitleBarTheme);
        }
    }

    private const int ImmersiveDarkMode = 20;

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(nint window, int attribute, ref int value, int size);
}
