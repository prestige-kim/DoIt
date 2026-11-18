namespace DoIt.Core;

public enum PanelMode
{
    List,
    Calendar,
}

public sealed class PanelState
{
    public PanelState(DateOnly today)
    {
        Today = today;
        DisplayMonth = FirstOfMonth(today);
        SelectedDate = today;
    }

    public bool IsVisible { get; private set; }
    public PanelMode Mode { get; private set; } = PanelMode.List;
    public DateOnly Today { get; private set; }
    public DateOnly DisplayMonth { get; private set; }
    public DateOnly SelectedDate { get; private set; }

    public IReadOnlyList<DateOnly?> CalendarDays
    {
        get
        {
            int firstSunday = DisplayMonth.DayNumber - (int)DisplayMonth.DayOfWeek;
            var days = new DateOnly?[42];
            for (int index = 0; index < days.Length; index++)
            {
                int dayNumber = firstSunday + index;
                if (dayNumber >= DateOnly.MinValue.DayNumber && dayNumber <= DateOnly.MaxValue.DayNumber)
                    days[index] = DateOnly.FromDayNumber(dayNumber);
            }

            return days;
        }
    }

    public void Show(DateOnly today)
    {
        RefreshToday(today);
        IsVisible = true;
    }

    public void Hide() => IsVisible = false;

    public void Toggle(DateOnly today)
    {
        if (IsVisible)
            Hide();
        else
            Show(today);
    }

    public void OpenCalendar(DateOnly today)
    {
        Mode = PanelMode.Calendar;
        GoToToday(today);
    }

    public void ShowList() => Mode = PanelMode.List;

    public void MoveMonth(int months)
    {
        long monthNumber = ((long)DisplayMonth.Year - 1) * 12 + DisplayMonth.Month - 1 + months;
        if (monthNumber >= 0 && monthNumber < DateOnly.MaxValue.Year * 12)
            DisplayMonth = DisplayMonth.AddMonths(months);
    }

    public void SelectDate(DateOnly date)
    {
        SelectedDate = date;
        DisplayMonth = FirstOfMonth(date);
    }

    public void GoToToday(DateOnly today)
    {
        Today = today;
        SelectDate(today);
    }

    public void RefreshToday(DateOnly today)
    {
        if (SelectedDate == Today)
        {
            SelectedDate = today;
            if (DisplayMonth == FirstOfMonth(Today))
                DisplayMonth = FirstOfMonth(today);
        }

        Today = today;
    }

    private static DateOnly FirstOfMonth(DateOnly date) => new(date.Year, date.Month, 1);
}
