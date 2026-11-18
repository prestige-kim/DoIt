using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using DoIt.Core;

namespace DoIt.Windows;

internal sealed class TrayIconService : IDisposable
{
    private const int CallbackMessage = 0x8001; // WM_APP + 1
    private const ushort IconId = 1;
    private const uint Add = 0;
    private const uint Modify = 1;
    private const uint Delete = 2;
    private const uint SetFocus = 3;
    private const uint SetVersion = 4;
    private const uint Version4 = 4;
    private const int NotifySelect = 0x0400;
    private const int NotifyKeySelect = 0x0401;
    private const int ContextMenu = 0x007B;
    private const int DisplayChange = 0x007E;
    private const int SettingChange = 0x001A;
    private const int TimeChange = 0x001E;
    private const int WorkAreaChange = 0x002F;
    private const int PowerBroadcast = 0x0218;
    private const int ResumeSuspend = 0x0007;
    private const int ResumeAutomatic = 0x0012;
    private const uint EditorCommand = 1;
    private const uint SettingsCommand = 2;
    private const uint ExitCommand = 3;
    private const uint RefreshLmsCommand = 4;
    private const uint CleanupCommand = 5;

    private readonly Action<TrayInvocation> toggle;
    private readonly Action openEditor;
    private readonly Action openSettings;
    private readonly Action exit;
    private readonly HwndSource source;
    private readonly uint taskbarCreatedMessage = RegisterWindowMessage("TaskbarCreated");
    private readonly nint icon;
    private bool registered;
    private bool disposed;

    internal TrayIconService(Action<TrayInvocation> toggle, Action openEditor, Action openSettings, Action exit)
    {
        this.toggle = toggle;
        this.openEditor = openEditor;
        this.openSettings = openSettings;
        this.exit = exit;

        source = new HwndSource(new HwndSourceParameters("DoIt Tray")
        {
            // Hidden top-level HWND so Explorer can broadcast TaskbarCreated.
            WindowStyle = unchecked((int)0x80000000), // WS_POPUP
            ExtendedWindowStyle = 0x00000080, // WS_EX_TOOLWINDOW
            Width = 1,
            Height = 1,
        });
        icon = LoadImage(
            0, Path.Combine(AppContext.BaseDirectory, "Assets", "DoIt.ico"),
            1, 32, 32, 0x0010); // IMAGE_ICON, LR_LOADFROMFILE
        if (icon == 0)
        {
            var error = Marshal.GetLastPInvokeError();
            source.Dispose();
            throw new Win32Exception(error, "DoIt 트레이 아이콘 파일을 열 수 없습니다.");
        }

        source.AddHook(OnWindowMessage);
        if (!RegisterIcon())
        {
            Dispose();
            throw new InvalidOperationException("Windows 알림 영역에 DoIt 아이콘을 등록할 수 없습니다.");
        }
    }

    internal event Action? DesktopGeometryChanged;
    internal event Action? LocalDateMayHaveChanged;
    internal event Action? Resumed;
    internal event Action? LmsRefreshRequested;
    internal event Action? HistoryRequested;
    internal Func<bool>? CanRefreshLms { private get; set; }
    internal Func<int>? HistoryCount { private get; set; }

    internal bool ShouldKeepPanelOpenOnDeactivation(Window window)
    {
        if (window.IsActive || NativeDesktop.IsImeWindowActive())
        {
            return true;
        }
        // Explorer can activate on the press before NIN_SELECT arrives on release.
        // Let that tray activation handle the toggle when the press is on our icon.
        const int LeftMouseButton = 0x01;
        return GetAsyncKeyState(LeftMouseButton) < 0
            && ReadIconBounds() is { } iconBounds
            && GetCursorPos(out var cursor)
            && iconBounds.Contains(cursor.ToScreenPoint());
    }

    internal void RestoreKeyboardFocus()
    {
        var data = CreateIconData();
        ShellNotifyIcon(SetFocus, ref data);
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }
        disposed = true;
        if (registered)
        {
            var data = CreateIconData();
            ShellNotifyIcon(Delete, ref data);
            registered = false;
        }
        source.RemoveHook(OnWindowMessage);
        source.Dispose();
        DestroyIcon(icon);
    }

    private bool RegisterIcon()
    {
        var data = CreateIconData();
        data.Flags = 0x0001 | 0x0002 | 0x0004 | 0x0080; // MESSAGE | ICON | TIP | SHOWTIP
        data.Callback = CallbackMessage;
        data.Icon = icon;
        data.Tooltip = "DoIt";
        // TaskbarCreated may also arrive when the taskbar changes DPI and the icon survives.
        registered = ShellNotifyIcon(Add, ref data) || ShellNotifyIcon(Modify, ref data);
        if (!registered)
        {
            return false;
        }

        data.Version = Version4;
        if (ShellNotifyIcon(SetVersion, ref data))
        {
            return true;
        }
        ShellNotifyIcon(Delete, ref data);
        registered = false;
        return false;
    }

    private NotifyIconData CreateIconData() => new()
    {
        Size = (uint)Marshal.SizeOf<NotifyIconData>(),
        Window = source.Handle,
        Id = IconId,
        Tooltip = "",
        Info = "",
        InfoTitle = "",
    };

    private nint OnWindowMessage(nint hwnd, int message, nint wParam, nint lParam, ref bool handled)
    {
        if (message == taskbarCreatedMessage)
        {
            RegisterIcon();
            DesktopGeometryChanged?.Invoke();
        }
        else if (message == DisplayChange || (message == SettingChange && wParam == WorkAreaChange))
        {
            DesktopGeometryChanged?.Invoke();
        }
        else if (message == TimeChange)
        {
            LocalDateMayHaveChanged?.Invoke();
        }
        else if (message == PowerBroadcast && wParam is ResumeSuspend or ResumeAutomatic)
        {
            LocalDateMayHaveChanged?.Invoke();
            Resumed?.Invoke();
        }
        else if (message == CallbackMessage && ((lParam.ToInt64() >> 16) & 0xFFFF) == IconId)
        {
            switch ((int)(lParam.ToInt64() & 0xFFFF))
            {
                case NotifySelect:
                    toggle(ReadInvocation(wParam, isKeyboard: false));
                    break;
                case NotifyKeySelect:
                    toggle(ReadInvocation(wParam, isKeyboard: true));
                    break;
                case ContextMenu:
                    ShowContextMenu();
                    break;
            }
            handled = true;
        }
        return 0;
    }

    private TrayInvocation ReadInvocation(nint wParam, bool isKeyboard)
    {
        // The Shell packs signed 16-bit coordinates, including on monitors to the left or above.
        var packed = wParam.ToInt64();
        var callback = new ScreenPoint(unchecked((short)packed), unchecked((short)(packed >> 16)));
        var selection = callback != new ScreenPoint(-1, -1) && NativeDesktop.IsOnDesktop(callback)
            ? callback
            : (ScreenPoint?)null;
        var iconBounds = ReadIconBounds();
        if (iconBounds is { } rect && selection is { } point && !rect.Contains(point))
        {
            // Explorer may already have closed the overflow popup and report another rectangle.
            // The coordinates from this selection still belong to the activated icon.
            iconBounds = null;
        }
        return new TrayInvocation(source.Handle, iconBounds, selection, isKeyboard);
    }

    private ScreenRect? ReadIconBounds()
    {
        var identifier = new NotifyIconIdentifier
        {
            Size = (uint)Marshal.SizeOf<NotifyIconIdentifier>(),
            Window = source.Handle,
            Id = IconId,
        };
        if (ShellNotifyIconGetRect(ref identifier, out var nativeRect) != 0)
        {
            return null;
        }
        var rect = nativeRect.ToScreenRect();
        return rect.IsValid && NativeDesktop.IsOnDesktop(rect.Center) ? rect : null;
    }

    internal TrayInvocation PlacementInvocation() => new(source.Handle, ReadIconBounds(), null, false);

    private void ShowContextMenu()
    {
        var menu = CreatePopupMenu();
        if (menu == 0)
        {
            return;
        }

        uint command;
        try
        {
            int cleanup = HistoryCount?.Invoke() ?? 0;
            if (!AppendMenu(menu, 0, EditorCommand, "전체 편집기…")
                || !AppendMenu(menu, 0, SettingsCommand, "설정")
                || (CanRefreshLms?.Invoke() == true && !AppendMenu(menu, 0, RefreshLmsCommand, "LMS 지금 새로고침"))
                || (cleanup > 0 && !AppendMenu(menu, 0, CleanupCommand, $"기록 정리 필요 ({cleanup}개)"))
                || !AppendMenu(menu, 0, ExitCommand, "종료"))
            {
                return;
            }
            // WM_CONTEXTMENU doesn't promise coordinates. Prefer the Shell's icon rectangle.
            var invocation = new TrayInvocation(source.Handle, ReadIconBounds(), null, false);
            var anchor = NativeDesktop.ResolveAnchor(invocation);
            SetForegroundWindow(source.Handle);
            const uint MenuFlags = 0x0002 | 0x0020 | 0x0080 | 0x0100; // RIGHTBUTTON | BOTTOMALIGN | NONOTIFY | RETURNCMD
            command = TrackPopupMenu(menu, MenuFlags, anchor.Point.X, anchor.Point.Y, source.Handle, 0);
            PostMessage(source.Handle, 0, 0, 0); // WM_NULL lets the next context menu open normally.
        }
        finally
        {
            DestroyMenu(menu);
        }

        switch (command)
        {
            case EditorCommand:
                openEditor();
                break;
            case SettingsCommand:
                openSettings();
                break;
            case RefreshLmsCommand:
                LmsRefreshRequested?.Invoke();
                break;
            case CleanupCommand:
                HistoryRequested?.Invoke();
                break;
            case ExitCommand:
                exit();
                break;
            default:
                RestoreKeyboardFocus();
                break;
        }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NotifyIconData
    {
        internal uint Size;
        internal nint Window;
        internal uint Id;
        internal uint Flags;
        internal uint Callback;
        internal nint Icon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] internal string Tooltip;
        private uint state;
        private uint stateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] internal string Info;
        internal uint Version;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] internal string InfoTitle;
        private uint infoFlags;
        private Guid guid;
        private nint balloonIcon;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NotifyIconIdentifier
    {
        internal uint Size;
        internal nint Window;
        internal uint Id;
        private Guid guid;
    }

    [DllImport("shell32.dll", EntryPoint = "Shell_NotifyIconW", ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ShellNotifyIcon(uint message, ref NotifyIconData data);

    [DllImport("shell32.dll", EntryPoint = "Shell_NotifyIconGetRect", ExactSpelling = true)]
    private static extern int ShellNotifyIconGetRect(ref NotifyIconIdentifier identifier, out NativeDesktop.NativeRect rect);

    [DllImport("user32.dll", EntryPoint = "RegisterWindowMessageW", ExactSpelling = true, CharSet = CharSet.Unicode)]
    private static extern uint RegisterWindowMessage(string name);

    [DllImport("user32.dll", EntryPoint = "LoadImageW", ExactSpelling = true, CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern nint LoadImage(nint instance, string filename, uint kind, int width, int height, uint flags);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyIcon(nint icon);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetCursorPos(out NativeDesktop.NativePoint cursor);

    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int key);

    [DllImport("user32.dll")]
    private static extern nint CreatePopupMenu();

    [DllImport("user32.dll", EntryPoint = "AppendMenuW", ExactSpelling = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AppendMenu(nint menu, uint flags, nuint command, string label);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(nint window);

    [DllImport("user32.dll", EntryPoint = "TrackPopupMenuEx", ExactSpelling = true)]
    private static extern uint TrackPopupMenu(nint menu, uint flags, int x, int y, nint window, nint parameters);

    [DllImport("user32.dll", EntryPoint = "PostMessageW", ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool PostMessage(nint window, uint message, nint wParam, nint lParam);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyMenu(nint menu);
}
