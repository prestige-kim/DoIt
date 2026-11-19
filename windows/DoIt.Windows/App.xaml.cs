using System.ComponentModel;
using System.IO;
using System.Security.Principal;
using System.Threading;
using System.Windows;
using System.Windows.Threading;
using DoIt.Core;

namespace DoIt.Windows;

public partial class App : Application
{
    private const string CleanupArgument = "--uninstall-cleanup";
    private readonly PanelState panelState = new(Today());
    private TrayIconService? tray;
    private PanelWindow? panel;
    private EditorWindow? editor;
    private SettingsWindow? settings;
    private TrayAnchor? anchor;
    private DispatcherOperation? pendingPlacement;
    private DispatcherOperation? pendingDismissal;
    private bool activateAfterPlacement;
    private Mutex? instanceMutex;
    private bool ownsInstance;
    private TodoStore? todos;
    private LmsService? lms;
    private HistoryService? history;
    private InstalledStartup? startup;
    private NotificationCenter? notificationCenter;
    private ReminderController? reminders;
    private UpdateService? updates;

    private const string UnexpectedErrorMessage = "예상하지 못한 문제로 DoIt을 종료합니다. 다시 실행해 주세요.";
    private bool silentFailures;
    private int unexpectedFailure;

    protected override void OnStartup(StartupEventArgs e)
    {
        bool reminderOnly = e.Args is [ClosedReminderTask.Argument];
        bool cleanupOnly = e.Args is [CleanupArgument];
        silentFailures = reminderOnly || cleanupOnly;
        DispatcherUnhandledException += OnDispatcherUnhandledException;
        AppDomain.CurrentDomain.UnhandledException += OnDomainUnhandledException;
        TaskScheduler.UnobservedTaskException += OnUnobservedTaskException;
        base.OnStartup(e);
        if (!silentFailures)
        {
            AppTheme.Start(this);
        }

        if (cleanupOnly)
        {
            // The uninstaller runs this only after checking that DoIt is closed, so it needs no instance check,
            // data folder or tray. It removes the per-user registrations and reports failures by exit code.
            RunUninstallCleanup();
            return;
        }

        var stage = StartupStage.Instance;
        try
        {
            if (!ClaimInstance())
            {
                Shutdown(0);
                return;
            }

            stage = StartupStage.DataFolder;
            var localData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            if (string.IsNullOrEmpty(localData))
            {
                throw new DirectoryNotFoundException();
            }
            var dataDirectory = Path.Combine(localData, "DoIt");
            startup = InstalledStartup.ForProcess(localData);
            if (reminderOnly && startup.Executable is null)
            {
                Shutdown(StartupDiagnostics.ExitCode(stage));
                return;
            }

            stage = StartupStage.TodoStore;
            todos = new TodoStore(Path.Combine(dataDirectory, "todos.json"));

            stage = StartupStage.Lms;
            lms = new LmsService(dataDirectory, new DpapiFeedAddressStore(Path.Combine(dataDirectory, "lms-feed-url")));

            stage = StartupStage.Notifications;
            notificationCenter = new NotificationCenter(startup.Executable is not null, OnNotificationInvoked);

            stage = StartupStage.Reminders;
            reminders = new ReminderController(dataDirectory, todos, lms, notificationCenter, startup.Executable, Dispatcher);
            if (reminderOnly)
            {
                reminders.Start(background: true);
                Shutdown();
                return;
            }

            stage = StartupStage.History;
            history = new HistoryService(todos, lms, dataDirectory);

            stage = StartupStage.Tray;
            tray = new TrayIconService(TogglePanel, ShowEditor, ShowSettings, Shutdown);

            stage = StartupStage.Start;
            todos.Changed += RefreshTodoViews;
            lms.Changed += RefreshLmsViews;
            tray.DesktopGeometryChanged += OnDesktopGeometryChanged;
            tray.LocalDateMayHaveChanged += RefreshLocalDate;
            tray.Resumed += () =>
            {
                RefreshLms();
                CheckForUpdates();
            };
            tray.LmsRefreshRequested += () => RefreshLms(manual: true);
            tray.HistoryRequested += ShowHistory;
            tray.CanRefreshLms = () => lms.Snapshot is { Enabled: true, HasFeedAddress: true, IsSyncing: false, DisconnectPending: false };
            tray.HistoryCount = () => history.Preview().TotalCount;
            reminders.Changed += RefreshReminderSettings;
            reminders.Start(background: false);
            RefreshLms();
            StartUpdateChecks(dataDirectory);
        }
        catch (Exception exception)
        {
            // Startup failures are fatal either way. Show only the stage and exception type, never its message.
            if (!silentFailures && ClaimUnexpectedFailure())
            {
                try
                {
                    MessageBox.Show("DoIt을 시작할 수 없습니다. Windows에서 앱을 다시 열어 주세요.\n\n진단: "
                        + StartupDiagnostics.Describe(stage, exception), "DoIt", MessageBoxButton.OK, MessageBoxImage.Error);
                }
                catch (Exception)
                {
                    // The exit code below still identifies the stage.
                }
            }
            Shutdown(StartupDiagnostics.ExitCode(stage));
        }
    }

    private async void RunUninstallCleanup()
    {
        var failure = CleanupFailure.None;
        try
        {
            string executable = Environment.ProcessPath ?? Path.Combine(AppContext.BaseDirectory, "DoIt.Windows.exe");
            try
            {
                if (!new ClosedReminderTask(executable).Replace(null))
                {
                    failure |= CleanupFailure.ReminderTask;
                }
            }
            catch (Exception)
            {
                failure |= CleanupFailure.ReminderTask;
            }
            if (NotificationRegistration.Exists())
            {
                try
                {
                    await NotificationCenter.UnregisterAllWithSdkAsync();
                }
                catch (Exception)
                {
                    // Includes Windows App SDK load failures. The registry entries are removed directly below.
                }
            }
            if (!NotificationRegistration.RemoveRemaining())
            {
                failure |= CleanupFailure.NotificationRegistration;
            }
        }
        catch (Exception)
        {
            failure |= CleanupFailure.Unexpected;
        }
        Shutdown(StartupDiagnostics.CleanupExitCode(failure));
    }

    private void OnDispatcherUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        // The exception text can contain paths or todo titles, so it is never shown or logged.
        e.Handled = true;
        if (!ClaimUnexpectedFailure())
        {
            // Already reporting a failure (for example, while the notice is open). Let that path finish.
            return;
        }

        ShowUnexpectedFailureNotice();
        try
        {
            Shutdown(1);
        }
        catch (InvalidOperationException)
        {
            // Shutdown was already in progress.
        }
    }

    private void OnDomainUnhandledException(object sender, UnhandledExceptionEventArgs e)
    {
        // Non-UI thread failures terminate the process after this handler; only tell the user once.
        if (e.IsTerminating && ClaimUnexpectedFailure())
        {
            ShowUnexpectedFailureNotice();
        }
    }

    private static void OnUnobservedTaskException(object? sender, UnobservedTaskExceptionEventArgs e) => e.SetObserved();

    private bool ClaimUnexpectedFailure() => Interlocked.Exchange(ref unexpectedFailure, 1) == 0;

    private void ShowUnexpectedFailureNotice()
    {
        if (silentFailures)
        {
            return;
        }
        try
        {
            MessageBox.Show(UnexpectedErrorMessage, "DoIt", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        catch (Exception)
        {
            // The notice is best effort. The app still exits.
        }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        AppTheme.Stop();
        pendingPlacement?.Abort();
        pendingDismissal?.Abort();
        if (reminders is not null)
        {
            reminders.Changed -= RefreshReminderSettings;
            reminders.Dispose();
        }
        notificationCenter?.Dispose();
        if (todos is not null)
        {
            todos.Changed -= RefreshTodoViews;
        }
        if (lms is not null)
        {
            lms.Changed -= RefreshLmsViews;
            lms.Dispose();
        }
        if (updates is not null)
        {
            updates.Changed -= RefreshUpdateViews;
            updates.Dispose();
        }
        try
        {
            tray?.Dispose();
        }
        finally
        {
            if (ownsInstance)
            {
                instanceMutex?.ReleaseMutex();
            }
            instanceMutex?.Dispose();
            base.OnExit(e);
        }
    }

    private bool ClaimInstance()
    {
        using var identity = WindowsIdentity.GetCurrent();
        var sid = identity.User?.Value ?? throw new InvalidOperationException("Windows 사용자 정보가 없습니다.");
        instanceMutex = new Mutex($"DoIt.Windows.{sid}", new NamedWaitHandleOptions
        {
            CurrentUserOnly = true,
            CurrentSessionOnly = false
        });
        try
        {
            ownsInstance = instanceMutex.WaitOne(0);
        }
        catch (AbandonedMutexException)
        {
            ownsInstance = true;
        }
        return ownsInstance;
    }

    private static DateOnly Today() => DateOnly.FromDateTime(DateTime.Now);

    private void TogglePanel(TrayInvocation invocation)
    {
        pendingDismissal?.Abort();
        if (panelState.IsVisible)
        {
            HidePanel();
            if (invocation.IsKeyboard)
            {
                tray?.RestoreKeyboardFocus();
            }
            return;
        }

        ShowPanel(invocation);
    }

    private void ShowPanel(TrayInvocation invocation)
    {
        anchor ??= NativeDesktop.ResolveAnchor(invocation);
        panelState.Show(Today());
        panel ??= CreatePanel();
        panel.RenderState();
        activateAfterPlacement = true;
        QueuePlacement();
        RefreshLms();
        CheckForUpdates();
    }

    private void OnNotificationInvoked()
    {
        if (!Dispatcher.HasShutdownStarted)
        {
            Dispatcher.BeginInvoke(() =>
            {
                if (tray is null) return;
                pendingDismissal?.Abort();
                panelState.GoToToday(Today());
                panelState.ShowList();
                ShowPanel(tray.PlacementInvocation());
            });
        }
    }

    private PanelWindow CreatePanel()
    {
        var window = new PanelWindow(panelState, todos!, lms!, Today);
        window.EditorRequested += ShowEditor;
        window.SettingsRequested += ShowSettings;
        window.DismissRequested += () =>
        {
            HidePanel();
            tray?.RestoreKeyboardFocus();
        };
        window.PanelSizeChanged += QueuePlacement;
        window.DpiChanged += (_, _) => OnDesktopGeometryChanged();
        window.Deactivated += (_, _) => OnPanelDeactivated(window);
        window.Closed += (_, _) =>
        {
            panelState.Hide();
            panel = null;
        };
        return window;
    }

    private void OnPanelDeactivated(PanelWindow window)
    {
        if (!panelState.IsVisible || tray?.ShouldKeepPanelOpenOnDeactivation(window) == true)
        {
            return;
        }

        // The shell's activation callback may arrive immediately after the focus change.
        pendingDismissal?.Abort();
        pendingDismissal = Dispatcher.InvokeAsync(() =>
        {
            pendingDismissal = null;
            if (window.IsVisible && !window.IsActive)
            {
                HidePanel();
            }
        }, DispatcherPriority.Background);
    }

    private void HidePanel()
    {
        pendingDismissal?.Abort();
        panelState.Hide();
        anchor = null;
        activateAfterPlacement = false;
        panel?.CloseTransientControls();
        panel?.Hide();
    }

    private void OnDesktopGeometryChanged()
    {
        if (panelState.IsVisible && anchor is { } currentAnchor)
        {
            anchor = currentAnchor.Refresh();
            QueuePlacement();
        }
    }

    private void RefreshLocalDate()
    {
        var today = Today();
        if (panelState.Today != today)
        {
            panelState.RefreshToday(today);
            panel?.RenderState();
        }
        editor?.RefreshTodos();
        editor?.RefreshLms();
        settings?.RefreshHistorySummary();
        reminders?.Recalculate();
    }

    private void RefreshTodoViews()
    {
        panel?.RefreshTodos();
        editor?.RefreshTodos();
        settings?.RefreshHistorySummary();
        reminders?.Recalculate();
    }

    private void RefreshLmsViews()
    {
        if (Dispatcher.HasShutdownStarted)
        {
            return;
        }
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.BeginInvoke(RefreshLmsViews);
            return;
        }
        panel?.RefreshLms();
        editor?.RefreshLms();
        settings?.RefreshLmsState();
        settings?.RefreshHistorySummary();
        reminders?.Recalculate();
    }

    private void RefreshReminderSettings() => settings?.RefreshReminders();

    // Part of the last startup stage, but optional: if it fails the app runs without update checks.
    private void StartUpdateChecks(string dataDirectory)
    {
        try
        {
            var (version, build) = SettingsWindow.ReadVersion(typeof(App).Assembly);
            updates = new UpdateService(dataDirectory, version, build, UpdateSchedule.CurrentArchitecture());
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException
            or ArgumentException or NotSupportedException or System.Security.SecurityException)
        {
            updates = null;
            return;
        }
        updates.Changed += RefreshUpdateViews;
        if (tray is not null)
        {
            tray.UpdateMenuLabel = () => updates is { } service ? UpdateDisplay.MenuLabel(service.Snapshot) : null;
            tray.UpdateDownloadRequested += OpenUpdateDownload;
        }
        CheckForUpdates();
    }

    // Runs only on startup, resume and panel open. The service skips it unless 24 hours have passed.
    private void CheckForUpdates()
    {
        if (updates is { } service)
        {
            SettingsWindow.RunUpdateCheck(service, manual: false);
        }
    }

    private void OpenUpdateDownload()
    {
        if (updates?.Snapshot.DownloadUrl is { } url && !SettingsWindow.ShellOpen(url.AbsoluteUri))
        {
            ShowSettings();
            settings?.ShowUpdateError();
        }
    }

    private void RefreshUpdateViews()
    {
        if (Dispatcher.HasShutdownStarted)
        {
            return;
        }
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.BeginInvoke(RefreshUpdateViews);
            return;
        }
        settings?.RefreshUpdateState();
    }

    private async void RefreshLms(bool manual = false)
    {
        if (lms is { } service)
        {
            try
            {
                await service.RefreshAsync(manual);
            }
            catch (OperationCanceledException)
            {
                // Closing or disconnecting invalidates in-flight work.
            }
        }
    }

    private void QueuePlacement()
    {
        if (pendingPlacement?.Status == DispatcherOperationStatus.Pending)
        {
            return;
        }

        pendingPlacement = Dispatcher.InvokeAsync(() =>
        {
            pendingPlacement = null;
            if (!panelState.IsVisible || panel is null || anchor is not { } currentAnchor)
            {
                return;
            }

            var monitor = currentAnchor.Monitor;
            var preferredSize = panel.PreferredSize;
            var bounds = PanelPlacement.Place(monitor.WorkArea, currentAnchor.Point,
                preferredSize.Width, preferredSize.Height, monitor.DpiX, monitor.DpiY);
            NativeDesktop.PlaceWindow(panel, bounds);

            if (activateAfterPlacement)
            {
                activateAfterPlacement = false;
                panel.Show();
                panel.Activate();
                panel.FocusToolbar();
            }
        }, DispatcherPriority.Loaded);
    }

    private void ShowSettings()
    {
        HidePanel();
        if (settings is null)
        {
            settings = new SettingsWindow(lms!, history!, RefreshLms, reminders!, startup!, updates);
            settings.Closed += (_, _) => settings = null;
            settings.Show();
        }

        settings.RefreshLmsState();
        settings.RefreshHistorySummary();
        settings.RefreshReminders();
        settings.RefreshStartup();
        settings.RefreshUpdateState();

        if (settings.WindowState == WindowState.Minimized)
        {
            settings.WindowState = WindowState.Normal;
        }

        settings.Activate();
    }

    private void ShowHistory()
    {
        ShowSettings();
        settings?.ShowHistory();
    }

    private void ShowEditor()
    {
        HidePanel();
        if (editor is null)
        {
            editor = new EditorWindow(todos!, lms!, Today);
            editor.Closed += (_, _) => editor = null;
        }

        editor.RefreshTodos();
        editor.RefreshLms();
        if (!editor.IsVisible)
        {
            editor.Show();
        }
        if (editor.WindowState == WindowState.Minimized)
        {
            editor.WindowState = WindowState.Normal;
        }

        editor.Activate();
    }
}
