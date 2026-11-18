namespace DoIt.Core;

public readonly record struct ScreenPoint(int X, int Y);

// Windows desktop coordinates are physical pixels, with an exclusive right and bottom edge.
public readonly record struct ScreenRect(int Left, int Top, int Right, int Bottom)
{
    public int Width => Right - Left;
    public int Height => Bottom - Top;
    public bool IsValid => Width > 0 && Height > 0;
    public ScreenPoint Center => new(Left + Width / 2, Top + Height / 2);

    public bool Contains(ScreenPoint point) =>
        point.X >= Left && point.X < Right && point.Y >= Top && point.Y < Bottom;
}

public static class PanelPlacement
{
    public static ScreenPoint ResolveAnchor(ScreenRect? iconRect, ScreenPoint? callbackPoint, ScreenPoint fallbackPoint) =>
        iconRect is { IsValid: true } bounds ? bounds.Center : callbackPoint ?? fallbackPoint;

    // Places the panel next to the tray anchor. The taskbar side keeps the anchor gap; the other
    // edges keep a margin from the work area, shrunk only when the work area is too small for it.
    public static ScreenRect Place(
        ScreenRect workArea, ScreenPoint anchor, double widthDip, double heightDip,
        double dpiX, double dpiY, double gapDip = 8, double marginDip = 12)
    {
        if (!workArea.IsValid)
            throw new ArgumentException("The work area must have a positive size.", nameof(workArea));

        ValidatePositive(widthDip, nameof(widthDip));
        ValidatePositive(heightDip, nameof(heightDip));
        ValidatePositive(dpiX, nameof(dpiX));
        ValidatePositive(dpiY, nameof(dpiY));
        if (!double.IsFinite(gapDip) || gapDip < 0)
            throw new ArgumentOutOfRangeException(nameof(gapDip));
        if (!double.IsFinite(marginDip) || marginDip < 0)
            throw new ArgumentOutOfRangeException(nameof(marginDip));

        int width = Math.Max(1, ToPixels(widthDip, dpiX, workArea.Width));
        int gap = ToPixels(gapDip, dpiY, workArea.Height);
        // The panel width is fixed by its layout, so a narrow work area gives up the margin first.
        int marginX = Math.Min(ToPixels(marginDip, dpiX, workArea.Width), (workArea.Width - width) / 2);
        int left = (int)Math.Clamp((long)anchor.X - width / 2,
            (long)workArea.Left + marginX, (long)workArea.Right - marginX - width);
        int marginY = ToPixels(marginDip, dpiY, workArea.Height);

        // Choose the direction from the anchor alone, so switching views cannot flip the panel.
        if (anchor.Y >= workArea.Center.Y)
        {
            int bottom = (int)Math.Clamp((long)anchor.Y - gap, (long)workArea.Top + 1, workArea.Bottom);
            int available = bottom - workArea.Top;
            int height = Math.Max(1, ToPixels(heightDip, dpiY, available - Math.Min(marginY, available / 2)));
            return new ScreenRect(left, bottom - height, left + width, bottom);
        }

        int top = (int)Math.Clamp((long)anchor.Y + gap, workArea.Top, (long)workArea.Bottom - 1);
        int downwardAvailable = workArea.Bottom - top;
        int downwardHeight = Math.Max(1,
            ToPixels(heightDip, dpiY, downwardAvailable - Math.Min(marginY, downwardAvailable / 2)));
        return new ScreenRect(left, top, left + width, top + downwardHeight);
    }

    private static int ToPixels(double size, double dpi, int limit) =>
        (int)Math.Min(limit, Math.Round(size * (dpi / 96), MidpointRounding.AwayFromZero));

    private static void ValidatePositive(double value, string parameter)
    {
        if (!double.IsFinite(value) || value <= 0)
            throw new ArgumentOutOfRangeException(parameter);
    }
}
