using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Windows.AppLifecycle;
using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;

namespace DoIt.Windows;

internal sealed class NotificationCenter : IDisposable
{
    private const string ActionKey = "action";
    private const string OpenTodayAction = "openToday";
    private const string InstalledAppId = "com.personal.doit.Windows";
    private readonly Action openToday;
    private AppNotificationManager? manager;

    internal NotificationCenter(bool installed, Action openToday)
    {
        this.openToday = openToday;
        try
        {
            string appId = installed ? InstalledAppId : "com.personal.doit.Windows.Dev";
            Marshal.ThrowExceptionForHR(SetCurrentProcessExplicitAppUserModelID(appId));
            var candidate = AppNotificationManager.Default;
            candidate.NotificationInvoked += OnInvoked;
            try
            {
                candidate.Register();
                manager = candidate;
            }
            catch
            {
                candidate.NotificationInvoked -= OnInvoked;
                throw;
            }
        }
        catch (Exception error) when (IsUnavailable(error))
        {
            // The rest of DoIt remains available when this Windows service cannot be registered.
        }
        if (manager is not null)
        {
            HandleLaunchActivation();
        }
    }

    // When DoIt is not running, a click launches a new process. Windows App SDK delivers that click
    // through the launch arguments, not NotificationInvoked, so read it once after Register().
    private void HandleLaunchActivation()
    {
        try
        {
            if (AppInstance.GetCurrent().GetActivatedEventArgs() is { Kind: ExtendedActivationKind.AppNotification } activation
                && activation.Data is AppNotificationActivatedEventArgs launch)
            {
                HandleArguments(launch.Arguments);
            }
        }
        catch (Exception error) when (IsUnavailable(error))
        {
            // An ordinary start continues without opening the panel.
        }
    }

    internal string? UnavailableReason
    {
        get
        {
            try
            {
                return manager?.Setting switch
                {
                    AppNotificationSetting.Enabled => null,
                    null => "Windows 알림 센터에 DoIt을 등록하지 못했습니다.",
                    _ => "Windows 설정에서 DoIt 알림을 허용해 주세요."
                };
            }
            catch (Exception error) when (IsUnavailable(error))
            {
                return "Windows 알림 설정을 확인할 수 없습니다.";
            }
        }
    }

    internal bool Show(int count, bool test = false)
    {
        if (manager is null || count < 1 || UnavailableReason is not null)
        {
            return false;
        }
        try
        {
            var alert = new AppNotificationBuilder().AddArgument(ActionKey, OpenTodayAction)
                .AddText(test ? "DoIt 테스트 알림" : "DoIt 마감 알림")
                .AddText($"오늘 마감 {count}개")
                .BuildNotification();
            manager.Show(alert);
            return true;
        }
        catch (Exception error) when (IsUnavailable(error))
        {
            return false;
        }
    }

    internal static async Task<bool> RemoveInstalledRegistrationAsync()
    {
        try
        {
            Marshal.ThrowExceptionForHR(SetCurrentProcessExplicitAppUserModelID(InstalledAppId));
            var registered = AppNotificationManager.Default;
            bool cleared = true;
            try { await registered.RemoveAllAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(3)); }
            catch (Exception error) when (IsUnavailable(error) || error is TimeoutException) { cleared = false; }
            registered.UnregisterAll();
            return cleared;
        }
        catch (Exception error) when (IsUnavailable(error)) { return false; }
    }

    private void OnInvoked(AppNotificationManager sender, AppNotificationActivatedEventArgs args) => HandleArguments(args.Arguments);

    private void HandleArguments(IDictionary<string, string> arguments)
    {
        if (arguments.TryGetValue(ActionKey, out var action) && action == OpenTodayAction)
        {
            openToday();
        }
    }

    public void Dispose()
    {
        if (manager is { } registered)
        {
            manager = null;
            try
            {
                registered.NotificationInvoked -= OnInvoked;
                registered.Unregister();
            }
            catch (Exception error) when (IsUnavailable(error)) { }
        }
    }

    private static bool IsUnavailable(Exception error) => error is COMException or UnauthorizedAccessException
        or InvalidOperationException or TypeInitializationException or DllNotFoundException or EntryPointNotFoundException
        or IOException or NotSupportedException;

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int SetCurrentProcessExplicitAppUserModelID(string appId);
}
