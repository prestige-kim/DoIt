using System.IO;
using System.Security;
using Microsoft.Win32;

namespace DoIt.Windows;

internal sealed class InstalledStartup(string? executable)
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "DoIt";

    internal string? Executable { get; } = executable;

    internal static InstalledStartup ForProcess(string localAppData)
    {
        var expected = Path.Combine(localAppData, "Programs", "DoIt", "app", "DoIt.Windows.exe");
        var process = Environment.ProcessPath;
        return new InstalledStartup(string.Equals(expected, process, StringComparison.OrdinalIgnoreCase) ? expected : null);
    }

    internal bool Enabled
    {
        get
        {
            if (Executable is null) return false;
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(RunKey);
                return string.Equals(key?.GetValue(ValueName) as string, Command, StringComparison.OrdinalIgnoreCase);
            }
            catch (Exception error) when (IsRegistryError(error)) { return false; }
        }
    }

    internal bool SetEnabled(bool enabled)
    {
        if (Executable is null) return false;
        try
        {
            using var key = enabled ? Registry.CurrentUser.CreateSubKey(RunKey)
                : Registry.CurrentUser.OpenSubKey(RunKey, writable: true);
            if (enabled)
            {
                if (key is null || key.GetValue(ValueName) is { } existing
                    && !string.Equals(existing as string, Command, StringComparison.OrdinalIgnoreCase))
                {
                    return false;
                }
                key.SetValue(ValueName, Command, RegistryValueKind.String);
            }
            else if (string.Equals(key?.GetValue(ValueName) as string, Command, StringComparison.OrdinalIgnoreCase))
            {
                key!.DeleteValue(ValueName, throwOnMissingValue: false);
            }
            return true;
        }
        catch (Exception error) when (IsRegistryError(error)) { return false; }
    }

    private string Command => $"\"{Executable}\"";

    private static bool IsRegistryError(Exception error) => error is IOException or UnauthorizedAccessException or SecurityException;
}
