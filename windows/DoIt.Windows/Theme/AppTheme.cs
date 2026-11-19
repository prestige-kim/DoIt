using System.Windows;
using Microsoft.Win32;

namespace DoIt.Windows;

// Picks DoIt's light or dark color dictionary from the Windows app theme and swaps it when the user changes it.
// It listens to the system preference event only; there is no polling.
internal static class AppTheme
{
    private const string PersonalizeKey = @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";
    private static readonly Uri LightColors = new("/DoIt.Windows;component/Theme/Colors.Light.xaml", UriKind.Relative);
    private static readonly Uri DarkColors = new("/DoIt.Windows;component/Theme/Colors.Dark.xaml", UriKind.Relative);
    private static ResourceDictionary? current;
    private static Application? owner;
    private static bool? applied;

    internal static bool IsLight { get; private set; }

    internal static void Start(Application app)
    {
        owner = app;
        Apply();
        SystemEvents.UserPreferenceChanged += OnPreferenceChanged;
    }

    internal static void Stop()
    {
        SystemEvents.UserPreferenceChanged -= OnPreferenceChanged;
        owner = null;
    }

    private static void OnPreferenceChanged(object sender, UserPreferenceChangedEventArgs e)
    {
        if (e.Category is UserPreferenceCategory.General or UserPreferenceCategory.Color or UserPreferenceCategory.VisualStyle
            && owner is { } app && !app.Dispatcher.HasShutdownStarted)
        {
            app.Dispatcher.BeginInvoke(Apply);
        }
    }

    private static void Apply()
    {
        if (owner is not { } app)
        {
            return;
        }
        bool light = ReadAppsUseLightTheme();
        if (applied == light && current is not null)
        {
            return;
        }
        var next = new ResourceDictionary { Source = light ? LightColors : DarkColors };
        var merged = app.Resources.MergedDictionaries;
        if (current is not null)
        {
            merged.Remove(current);
        }
        merged.Add(next);
        current = next;
        applied = light;
        IsLight = light;
    }

    private static bool ReadAppsUseLightTheme()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(PersonalizeKey);
            return key?.GetValue("AppsUseLightTheme") is not int value || value != 0;
        }
        catch (Exception error) when (error is System.Security.SecurityException or UnauthorizedAccessException
            or System.IO.IOException)
        {
            return true;
        }
    }
}
