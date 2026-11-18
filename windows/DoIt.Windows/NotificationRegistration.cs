using System.IO;
using System.Security;
using Microsoft.Win32;

namespace DoIt.Windows;

// Per-user entries that Windows App SDK writes for an unpackaged app with an explicit AppUserModelID
// (microsoft/WindowsAppSDK dev/AppNotifications/AppNotificationUtility.cpp and ShellLocalization.cpp):
//   HKCU\Software\Classes\AppUserModelId\<AUMID>   (DisplayName, IconUri, CustomActivator = {CLSID})
//   HKCU\Software\Classes\CLSID\{CLSID}\LocalServer32 = "<exe>" ----AppNotificationActivated:
//   %LOCALAPPDATA%\Microsoft\WindowsAppSDK\<AUMID>.png
// This class must not reference Windows App SDK types, so it still works if those assemblies cannot load.
internal static class NotificationRegistration
{
    internal const string AppIdKey = @"Software\Classes\AppUserModelId\" + NotificationCenter.InstalledAppIdentifier;
    private const string ClassesKey = @"Software\Classes\CLSID\";

    internal static string IconCachePath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Microsoft", "WindowsAppSDK", NotificationCenter.InstalledAppIdentifier + ".png");

    internal static bool Exists()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(AppIdKey);
            return key is not null;
        }
        catch (Exception error) when (error is SecurityException or UnauthorizedAccessException or IOException)
        {
            return true;
        }
    }

    // Removes what the SDK left behind. Returns true when no DoIt registration remains.
    internal static bool RemoveRemaining()
    {
        if (Exists())
        {
            try
            {
                var user = Registry.CurrentUser;
                string? activator;
                using (var key = user.OpenSubKey(AppIdKey))
                {
                    activator = key?.GetValue("CustomActivator") as string;
                }
                if (activator is not null && Guid.TryParse(activator, out var clsid))
                {
                    string classKey = ClassesKey + clsid.ToString("B");
                    bool launchesDoIt;
                    using (var server = user.OpenSubKey(classKey + @"\LocalServer32"))
                    {
                        launchesDoIt = server?.GetValue(null) is string command
                            && command.Contains("DoIt.Windows.exe", StringComparison.OrdinalIgnoreCase);
                    }
                    // Delete the COM entry only when it launches this app, never another program's class.
                    if (launchesDoIt)
                    {
                        user.DeleteSubKeyTree(classKey, throwOnMissingSubKey: false);
                    }
                }
                user.DeleteSubKeyTree(AppIdKey, throwOnMissingSubKey: false);
            }
            catch (Exception error) when (error is SecurityException or UnauthorizedAccessException
                or IOException or ArgumentException)
            {
                // Exists() below reports what is left.
            }
        }
        try
        {
            File.Delete(IconCachePath);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        return !Exists();
    }
}
