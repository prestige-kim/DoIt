using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using System.Windows.Interop;
using DoIt.Core;

namespace DoIt.Windows;

internal readonly record struct TrayInvocation(
    nint SourceHandle, ScreenRect? IconBounds, ScreenPoint? SelectionPoint, bool IsKeyboard);

internal readonly record struct MonitorGeometry(
    ScreenRect Bounds, ScreenRect WorkArea, double DpiX, double DpiY);

internal readonly record struct TrayAnchor(
    nint SourceHandle, ScreenPoint Point, MonitorGeometry Monitor)
{
    internal TrayAnchor Refresh() => NativeDesktop.RefreshAnchor(this);
}

internal static class NativeDesktop
{
    private const uint MonitorDefaultToNull = 0;
    private const uint MonitorDefaultToPrimary = 1;
    private const uint PositionOnly = 0x0001 | 0x0004 | 0x0010; // NOSIZE | NOZORDER | NOACTIVATE
    private const uint PlaceWithoutActivation = 0x0004 | 0x0010; // NOZORDER | NOACTIVATE
    private const int DefaultDpi = 96;
    private const int DwmWindowCornerPreference = 33; // DWMWA_WINDOW_CORNER_PREFERENCE
    private const int DwmCornerRound = 2; // DWMWCP_ROUND

    internal static TrayAnchor ResolveAnchor(TrayInvocation invocation)
    {
        var monitor = invocation.IconBounds is { } icon
            ? MonitorFromPoint(new NativePoint(icon.Center), MonitorDefaultToNull)
            : 0;
        if (monitor == 0 && invocation.SelectionPoint is { } point)
        {
            monitor = MonitorFromPoint(new NativePoint(point), MonitorDefaultToNull);
        }
        if (monitor == 0)
        {
            return ReadTaskbarAnchor(invocation.SourceHandle);
        }

        var geometry = ReadMonitor(monitor, invocation.SourceHandle);
        var anchor = PanelPlacement.ResolveAnchor(
            invocation.IconBounds, invocation.SelectionPoint, WorkAreaCorner(geometry));
        return new TrayAnchor(invocation.SourceHandle, anchor, geometry);
    }

    internal static TrayAnchor RefreshAnchor(TrayAnchor previous)
    {
        var monitor = MonitorFromPoint(new NativePoint(previous.Point), MonitorDefaultToNull);
        if (monitor == 0)
        {
            return ReadTaskbarAnchor(previous.SourceHandle);
        }
        var geometry = ReadMonitor(monitor, previous.SourceHandle);
        return previous with { Monitor = geometry };
    }

    internal static bool IsOnDesktop(ScreenPoint point) =>
        MonitorFromPoint(new NativePoint(point), MonitorDefaultToNull) != 0;

    internal static void PlaceWindow(Window window, ScreenRect bounds)
    {
        var handle = new WindowInteropHelper(window).EnsureHandle();
        if (GetWindowRect(handle, out var current) && current.ToScreenRect() == bounds)
        {
            return;
        }
        if (!SetWindowPos(handle, 0, bounds.Left, bounds.Top, bounds.Width, bounds.Height, PlaceWithoutActivation))
        {
            throw new Win32Exception(Marshal.GetLastPInvokeError());
        }
    }

    internal static bool IsImeWindowActive()
    {
        var foreground = GetForegroundWindow();
        if (foreground == 0)
        {
            return false;
        }
        var className = new StringBuilder(128);
        _ = GetClassName(foreground, className, className.Capacity);
        var name = className.ToString();
        return name is "IME" or "MSCTFIME UI" or "CiceroUIWndFrame"
            || name.StartsWith("Microsoft.IME.", StringComparison.Ordinal);
    }

    // Asks DWM for Windows 11 rounded corners. Older Windows returns an error and nothing changes.
    internal static bool TryRoundCorners(Window window)
    {
        var handle = new WindowInteropHelper(window).Handle;
        if (handle == 0)
        {
            return false;
        }
        var preference = DwmCornerRound;
        return DwmSetWindowAttribute(handle, DwmWindowCornerPreference, ref preference, sizeof(int)) >= 0;
    }

    private static TrayAnchor ReadTaskbarAnchor(nint sourceHandle)
    {
        var taskbar = FindWindow("Shell_TrayWnd", null);
        var monitor = taskbar == 0 ? 0 : MonitorFromWindow(taskbar, MonitorDefaultToNull);
        if (monitor == 0)
        {
            monitor = MonitorFromPoint(new NativePoint(new ScreenPoint(0, 0)), MonitorDefaultToPrimary);
        }
        var geometry = ReadMonitor(monitor, sourceHandle);
        return new TrayAnchor(sourceHandle, WorkAreaCorner(geometry), geometry);
    }

    private static ScreenPoint WorkAreaCorner(MonitorGeometry geometry)
    {
        var area = geometry.WorkArea;
        var topTaskbar = area.Top - geometry.Bounds.Top > geometry.Bounds.Bottom - area.Bottom;
        return new ScreenPoint(area.Right - 1, topTaskbar ? area.Top : area.Bottom - 1);
    }

    private static MonitorGeometry ReadMonitor(nint monitor, nint sourceHandle)
    {
        var info = new MonitorInfo { Size = (uint)Marshal.SizeOf<MonitorInfo>() };
        if (!GetMonitorInfo(monitor, ref info))
        {
            throw new Win32Exception(Marshal.GetLastPInvokeError());
        }
        // GetDpiForWindow reports the DPI of the monitor occupied by this Per-Monitor V2 HWND.
        // Reuse the invisible callback window and move it only when the target monitor changes.
        if (MonitorFromWindow(sourceHandle, MonitorDefaultToNull) != monitor)
        {
            var center = info.WorkArea.ToScreenRect().Center;
            if (!SetWindowPos(sourceHandle, 0, center.X, center.Y, 0, 0, PositionOnly))
            {
                throw new Win32Exception(Marshal.GetLastPInvokeError());
            }
        }
        var dpi = GetDpiForWindow(sourceHandle);
        return new MonitorGeometry(
            info.Bounds.ToScreenRect(), info.WorkArea.ToScreenRect(),
            dpi == 0 ? DefaultDpi : dpi, dpi == 0 ? DefaultDpi : dpi);
    }

    [StructLayout(LayoutKind.Sequential)]
    internal readonly struct NativePoint(ScreenPoint point)
    {
        private readonly int x = point.X;
        private readonly int y = point.Y;

        internal ScreenPoint ToScreenPoint() => new(x, y);
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct NativeRect
    {
        private int left;
        private int top;
        private int right;
        private int bottom;

        internal readonly ScreenRect ToScreenRect() => new(left, top, right, bottom);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MonitorInfo
    {
        internal uint Size;
        internal NativeRect Bounds;
        internal NativeRect WorkArea;
        private uint flags;
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(nint window, int attribute, ref int value, int size);

    [DllImport("user32.dll")]
    private static extern nint MonitorFromPoint(NativePoint point, uint flags);

    [DllImport("user32.dll")]
    private static extern nint MonitorFromWindow(nint window, uint flags);

    [DllImport("user32.dll", EntryPoint = "GetMonitorInfoW", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetMonitorInfo(nint monitor, ref MonitorInfo info);

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(nint window);

    [DllImport("user32.dll", EntryPoint = "FindWindowW", ExactSpelling = true, CharSet = CharSet.Unicode)]
    private static extern nint FindWindow(string className, string? windowName);

    [DllImport("user32.dll", EntryPoint = "GetClassNameW", ExactSpelling = true, CharSet = CharSet.Unicode)]
    private static extern int GetClassName(nint window, StringBuilder className, int capacity);

    [DllImport("user32.dll")]
    private static extern nint GetForegroundWindow();

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetWindowRect(nint window, out NativeRect rect);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowPos(nint window, nint after, int x, int y, int width, int height, uint flags);
}
