using DoIt.Core;

var today = new DateOnly(2026, 11, 30);
var tomorrow = today.AddDays(1);
var earlierDate = new DateOnly(2026, 10, 14);
var workArea = new ScreenRect(0, 0, 1920, 1040);
var trayPoint = new ScreenPoint(1850, 1060);

(string Name, Action Run)[] tests =
[
    ("Fresh session opens the list with today's date", () =>
    {
        var panel = new PanelState(today);
        Equal(false, panel.IsVisible);
        panel.Toggle(today);
        Equal(true, panel.IsVisible);
        Equal(PanelMode.List, panel.Mode);
        Equal(today, panel.SelectedDate);
        Equal(new DateOnly(2026, 11, 1), panel.DisplayMonth);
        panel.Toggle(today);
        Equal(false, panel.IsVisible);
    }),
    ("Hiding keeps calendar mode, browsed month, and selected date", () =>
    {
        var panel = new PanelState(today);
        panel.Show(today);
        panel.OpenCalendar(today);
        panel.SelectDate(earlierDate);
        panel.MoveMonth(1);
        panel.Hide();
        panel.Show(today);
        Equal(true, panel.IsVisible);
        Equal(PanelMode.Calendar, panel.Mode);
        Equal(new DateOnly(2026, 11, 1), panel.DisplayMonth);
        Equal(earlierDate, panel.SelectedDate);
    }),
    ("Calendar button starts from today after switching to the list", () =>
    {
        var panel = new PanelState(today);
        panel.OpenCalendar(today);
        panel.SelectDate(earlierDate);
        panel.ShowList();
        Equal(PanelMode.List, panel.Mode);
        panel.OpenCalendar(tomorrow);
        Equal(PanelMode.Calendar, panel.Mode);
        Equal(tomorrow, panel.SelectedDate);
        Equal(tomorrow, panel.DisplayMonth);
    }),
    ("Choosing a date in an adjacent month moves the displayed month", () =>
    {
        var panel = new PanelState(today);
        panel.OpenCalendar(today);
        panel.SelectDate(tomorrow);
        Equal(tomorrow, panel.DisplayMonth);
        Equal(tomorrow, panel.SelectedDate);
    }),
    ("Today button returns to the current month and current date", () =>
    {
        var panel = new PanelState(today);
        panel.OpenCalendar(today);
        panel.SelectDate(earlierDate);
        panel.GoToToday(tomorrow);
        Equal(tomorrow, panel.Today);
        Equal(tomorrow, panel.SelectedDate);
        Equal(tomorrow, panel.DisplayMonth);
    }),
    ("A new app session starts from the list even after the previous session browsed the calendar", () =>
    {
        var previousSession = new PanelState(today);
        previousSession.OpenCalendar(today);
        previousSession.SelectDate(earlierDate);
        var newSession = new PanelState(tomorrow);
        newSession.Show(tomorrow);
        Equal(PanelMode.List, newSession.Mode);
        Equal(tomorrow, newSession.SelectedDate);
    }),
    ("Reopening after midnight updates a selection of yesterday's today and the old month", () =>
    {
        var panel = new PanelState(today);
        panel.Show(today);
        panel.OpenCalendar(today);
        panel.Hide();
        panel.Show(tomorrow);
        Equal(PanelMode.Calendar, panel.Mode);
        Equal(tomorrow, panel.Today);
        Equal(tomorrow, panel.SelectedDate);
        Equal(tomorrow, panel.DisplayMonth);
    }),
    ("A day change preserves a different selected date and month", () =>
    {
        var panel = new PanelState(today);
        panel.OpenCalendar(today);
        panel.SelectDate(earlierDate);
        panel.RefreshToday(tomorrow);
        Equal(tomorrow, panel.Today);
        Equal(earlierDate, panel.SelectedDate);
        Equal(new DateOnly(2026, 10, 1), panel.DisplayMonth);
    }),
    ("A day change preserves the independently browsed month", () =>
    {
        var panel = new PanelState(today);
        panel.OpenCalendar(today);
        panel.MoveMonth(-1);
        panel.RefreshToday(tomorrow);
        Equal(tomorrow, panel.SelectedDate);
        Equal(new DateOnly(2026, 10, 1), panel.DisplayMonth);
    }),
    ("Calendar uses six Sunday-start weeks including adjacent months", () =>
    {
        var panel = new PanelState(new DateOnly(2026, 12, 6));
        var days = panel.CalendarDays;
        Equal(42, days.Count);
        Equal<DateOnly?>(new DateOnly(2026, 11, 29), days[0]);
        Equal<DateOnly?>(new DateOnly(2026, 12, 1), days[2]);
        Equal<DateOnly?>(new DateOnly(2027, 1, 9), days[^1]);
    }),
    ("Calendar handles the ends of DateOnly without jumping or throwing", () =>
    {
        var earliest = new PanelState(DateOnly.MinValue);
        earliest.MoveMonth(-1);
        Equal(DateOnly.MinValue, earliest.DisplayMonth);
        Equal<DateOnly?>(null, earliest.CalendarDays[0]);
        Equal<DateOnly?>(DateOnly.MinValue, earliest.CalendarDays[1]);
        var latest = new PanelState(DateOnly.MaxValue);
        latest.MoveMonth(1);
        Equal(new DateOnly(9999, 12, 1), latest.DisplayMonth);
        Equal<DateOnly?>(null, latest.CalendarDays[^1]);
    }),
    ("Bottom tray anchors list and calendar to the same bottom edge", () =>
    {
        var list = PanelPlacement.Place(workArea, trayPoint, 440, 320, 96, 96);
        var calendar = PanelPlacement.Place(workArea, trayPoint, 520, 580, 96, 96);
        Equal(new ScreenRect(1468, 720, 1908, 1040), list);
        Equal(new ScreenRect(1388, 460, 1908, 1040), calendar);
        Equal(list, PanelPlacement.Place(workArea, trayPoint, 440, 320, 96, 96));
    }),
    ("Anchor inside hidden icons stays fixed during expansion", () =>
    {
        var hiddenIcon = new ScreenPoint(1790, 930);
        var list = PanelPlacement.Place(workArea, hiddenIcon, 440, 320, 96, 96);
        var calendar = PanelPlacement.Place(workArea, hiddenIcon, 520, 580, 96, 96);
        Equal(922, list.Bottom);
        Equal(list.Bottom, calendar.Bottom);
        Equal(list.Right, calendar.Right);
        Equal(1908, list.Right);
    }),
    ("Work area supports monitors with negative desktop coordinates", () =>
    {
        var result = PanelPlacement.Place(new ScreenRect(-1920, -120, 0, 920), new ScreenPoint(-80, 950), 440, 320, 96, 96);
        Equal(new ScreenRect(-452, 600, -12, 920), result);
    }),
    ("Each monitor's DPI determines the physical window dimensions", () =>
    {
        var standard = PanelPlacement.Place(workArea, trayPoint, 440, 320, 96, 96);
        var scaled = PanelPlacement.Place(workArea, trayPoint, 440, 320, 144, 144);
        Equal(440, standard.Width);
        Equal(320, standard.Height);
        Equal(660, scaled.Width);
        Equal(480, scaled.Height);
        Equal(1040, scaled.Bottom);
        Equal(1902, scaled.Right);
    }),
    ("Small work areas constrain size at high DPI", () =>
    {
        var small = new ScreenRect(20, 30, 320, 230);
        var result = PanelPlacement.Place(small, new ScreenPoint(280, 245), 520, 580, 192, 192);
        Equal(new ScreenRect(20, 54, 320, 229), result);
    }),
    ("An anchor at the top expands down without leaving the work area", () =>
    {
        var topWorkArea = new ScreenRect(0, 40, 1920, 1080);
        var result = PanelPlacement.Place(topWorkArea, new ScreenPoint(120, 20), 440, 320, 96, 96);
        Equal(new ScreenRect(12, 40, 452, 360), result);
    }),
    ("A narrow work area shrinks the side margin to stay on screen", () =>
    {
        var narrow = PanelPlacement.Place(new ScreenRect(0, 0, 450, 1040), new ScreenPoint(400, 1060), 440, 320, 96, 96);
        Equal(new ScreenRect(5, 720, 445, 1040), narrow);
        var exact = PanelPlacement.Place(new ScreenRect(0, 0, 440, 1040), new ScreenPoint(400, 1060), 440, 320, 96, 96);
        Equal(new ScreenRect(0, 720, 440, 1040), exact);
    }),
    ("A short work area keeps the far-edge margin and shrinks the panel", () =>
    {
        var result = PanelPlacement.Place(new ScreenRect(0, 0, 1920, 600), new ScreenPoint(1850, 620), 520, 640, 96, 96);
        Equal(new ScreenRect(1388, 12, 1908, 600), result);
    }),
    ("Margins scale with DPI on a monitor above and left of the primary", () =>
    {
        var result = PanelPlacement.Place(new ScreenRect(-2560, -1440, 0, -48), new ScreenPoint(-100, -20), 440, 320, 144, 144);
        Equal(new ScreenRect(-678, -528, -18, -48), result);
    }),
    ("A top taskbar on a left monitor at 144 DPI keeps the bottom margin", () =>
    {
        var result = PanelPlacement.Place(new ScreenRect(-1440, 60, 0, 900), new ScreenPoint(-1400, 30), 520, 640, 144, 144);
        Equal(new ScreenRect(-1422, 60, -642, 882), result);
    }),
    ("Anchor source prefers a valid icon, then the callback, then the fallback", () =>
    {
        var icon = new ScreenRect(-24, 1048, -4, 1068);
        var fallback = new ScreenPoint(1919, 1039);
        Equal(new ScreenPoint(-14, 1058), PanelPlacement.ResolveAnchor(icon, trayPoint, fallback));
        Equal(trayPoint, PanelPlacement.ResolveAnchor(default(ScreenRect), trayPoint, fallback));
        Equal(fallback, PanelPlacement.ResolveAnchor(null, null, fallback));
    }),
];

int failures = 0;
var allTests = tests.Concat(TodoStoreTests.Cases).Concat(IcsParserTests.Cases).Concat(LmsSyncTests.Cases)
    .Concat(HistoryServiceTests.Cases).Concat(ReminderPlannerTests.Cases).ToArray();
foreach (var test in allTests)
{
    try
    {
        test.Run();
        Console.WriteLine($"PASS {test.Name}");
    }
    catch (Exception error)
    {
        failures++;
        Console.Error.WriteLine($"FAIL {test.Name}: {error.Message}");
    }
}

Console.WriteLine($"{allTests.Length - failures} passed, {failures} failed");
return failures == 0 ? 0 : 1;

static void Equal<T>(T expected, T actual)
{
    if (!EqualityComparer<T>.Default.Equals(expected, actual))
        throw new InvalidOperationException($"Expected {expected}, got {actual}.");
}
