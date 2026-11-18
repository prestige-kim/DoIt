using System.ComponentModel;
using System.Globalization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using DoIt.Core;

namespace DoIt.Windows;

public partial class PanelWindow : Window
{
    private static readonly CultureInfo Korean = CultureInfo.GetCultureInfo("ko-KR");

    private readonly PanelState state;
    private readonly TodoStore todos;
    private readonly LmsService lms;
    private readonly Func<DateOnly> today;
    private readonly CalendarCell[] calendarCells;
    private DateOnly? chosenDueDate;
    private TodoRow? pendingDelete;
    private const string InvalidTitleMessage = "제목을 1~200자로 입력해 주세요. 줄바꿈은 사용할 수 없습니다.";
    private string? saveError;
    private bool composing;
    private bool savingTodo;

    internal PanelWindow(PanelState state, TodoStore todos, LmsService lms, Func<DateOnly> today)
    {
        this.state = state;
        this.todos = todos;
        this.lms = lms;
        this.today = today;

        InitializeComponent();
        LmsTasks.LayoutChanged += () => PanelSizeChanged?.Invoke();

        foreach (var weekday in Korean.DateTimeFormat.AbbreviatedDayNames)
        {
            Weekdays.Children.Add(new TextBlock { Text = weekday, TextAlignment = TextAlignment.Center });
        }

        calendarCells = Enumerable.Range(0, 42).Select(_ => CreateCalendarCell()).ToArray();

        TextCompositionManager.AddPreviewTextInputStartHandler(InputBox, (_, _) => composing = true);
        TextCompositionManager.AddPreviewTextInputUpdateHandler(InputBox, (_, _) => composing = true);
        TextCompositionManager.AddPreviewTextInputHandler(InputBox, (_, _) => composing = false);
        InputBox.LostKeyboardFocus += (_, _) => composing = false;
        InputBox.PreviewKeyDown += OnInputKeyDown;
        KeyDown += OnKeyDown;
        SourceInitialized += OnSourceInitialized;
    }

    private void OnSourceInitialized(object? sender, EventArgs e)
    {
        // Windows 10 and older builds reject the corner attribute; the panel then stays square.
        NativeDesktop.TryRoundCorners(this);
        // The Fluent theme normally supplies the stroke brush. Fall back to a system color if not.
        if (TryFindResource("SurfaceStrokeColorDefaultBrush") is not Brush)
        {
            PanelFrame.SetResourceReference(Border.BorderBrushProperty, SystemColors.ActiveBorderBrushKey);
        }
    }

    internal event Action? EditorRequested;
    internal event Action? SettingsRequested;
    internal event Action? DismissRequested;
    internal event Action? PanelSizeChanged;

    internal Size PreferredSize
    {
        get
        {
            bool calendar = state.Mode == PanelMode.Calendar;
            double width = calendar ? 520 : 440;
            // FrameBorder covers the 1px panel border on both sides.
            const double FrameBorder = 2;
            PanelContent.Measure(new Size(width - FrameBorder - SystemParameters.VerticalScrollBarWidth, double.PositiveInfinity));
            // Calendar cells are 36 high, so 680 fits the month plus about three to four todos before scrolling.
            double height = Math.Ceiling(PanelContent.DesiredSize.Height) + FrameBorder;
            return new Size(width, Math.Clamp(height, 170, calendar ? 680 : 520));
        }
    }

    private bool CanModifySelectedDay => state.Mode == PanelMode.List || state.SelectedDate >= state.Today;

    private DateOnly DraftDueDate => state.Mode == PanelMode.Calendar ? state.SelectedDate : chosenDueDate ?? state.Today;

    internal void FocusToolbar()
    {
        if (IsActive)
        {
            ModeButton.Focus();
        }
    }

    internal void RenderState()
    {
        DisarmDelete();
        var showsCalendar = state.Mode == PanelMode.Calendar;
        CalendarView.Visibility = showsCalendar ? Visibility.Visible : Visibility.Collapsed;
        ModeButton.Content = showsCalendar ? "목록" : "달력";
        AutomationProperties.SetName(ModeButton, showsCalendar ? "할 일 목록 보기" : "월간 달력 보기");

        if (showsCalendar)
        {
            MonthHeading.Text = state.DisplayMonth.ToString("yyyy년 M월", Korean);
            RenderCalendarCells();
        }
        LmsTasks.Refresh(lms, state.Today, showsCalendar ? state.SelectedDate : null);

        var visibleTodos = showsCalendar ? todos.ForDate(state.SelectedDate) : todos.Visible(state.Today);
        bool canWrite = todos.LoadError is null && CanModifySelectedDay;
        QuickAdd.Visibility = CanModifySelectedDay ? Visibility.Visible : Visibility.Collapsed;
        QuickAdd.IsEnabled = canWrite;
        PastDay.Visibility = CanModifySelectedDay ? Visibility.Collapsed : Visibility.Visible;
        if (showsCalendar)
        {
            DueDatePicker.Visibility = Visibility.Collapsed;
        }
        DueDateButton.Visibility = showsCalendar ? Visibility.Collapsed : Visibility.Visible;
        CalendarDueDate.Visibility = showsCalendar ? Visibility.Visible : Visibility.Collapsed;
        UpdateDueDateLabel();
        StorageError.Text = todos.LoadError ?? saveError ?? string.Empty;
        StorageError.Visibility = StorageError.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        TodoHeading.Text = showsCalendar ? state.SelectedDate.ToString("M월 d일 (ddd) 할 일", Korean) : "할 일";
        TodoList.ItemsSource = visibleTodos.Select(item => new TodoRow(item, state.Today, canWrite, canWrite && !showsCalendar)).ToArray();
        EmptyDay.Text = showsCalendar ? "이 날의 할 일이 없어요." : "할 일이 없어요.";
        EmptyDay.Visibility = visibleTodos.Count == 0 && todos.LoadError is null ? Visibility.Visible : Visibility.Collapsed;
        PanelSizeChanged?.Invoke();
    }

    internal void RefreshLms()
    {
        if (state.IsVisible)
        {
            bool calendar = state.Mode == PanelMode.Calendar;
            if (calendar)
            {
                RenderCalendarCells();
            }
            LmsTasks.Refresh(lms, state.Today, calendar ? state.SelectedDate : null);
            PanelSizeChanged?.Invoke();
        }
    }

    internal void RefreshTodos()
    {
        // Panel actions render after the save so the draft and focus can be updated first.
        if (state.IsVisible && !savingTodo)
        {
            state.RefreshToday(today());
            RenderState();
        }
    }

    internal void CloseTransientControls()
    {
        DueDatePicker.Visibility = Visibility.Collapsed;
        DisarmDelete();
    }

    private CalendarCell CreateCalendarCell()
    {
        var label = new TextBlock { TextAlignment = TextAlignment.Center };
        var marker = new Ellipse { Width = 5, Height = 5, Margin = new Thickness(0, 2, 0, 0) };
        marker.SetResourceReference(Shape.FillProperty, "TodoAccent");
        var lmsMarker = new Ellipse { Width = 5, Height = 5, Margin = new Thickness(2, 2, 0, 0) };
        lmsMarker.SetResourceReference(Shape.FillProperty, "LmsAccent");
        var markers = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center };
        markers.Children.Add(marker);
        markers.Children.Add(lmsMarker);
        var content = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        content.Children.Add(label);
        content.Children.Add(markers);

        var button = new Button
        {
            Content = content,
            Style = (Style)FindResource("CalendarCellStyle")
        };
        button.Click += SelectDate;
        CalendarGrid.Children.Add(button);
        return new CalendarCell(button, label, marker, lmsMarker);
    }

    private void RenderCalendarCells()
    {
        var dates = state.CalendarDays;
        var firstVisible = dates[0] ?? DateOnly.MinValue;
        var lastVisible = dates[^1] ?? DateOnly.MaxValue;
        var todoMarkers = todos.All.Where(item => item.DueDate >= firstVisible && item.DueDate <= lastVisible)
            .GroupBy(item => item.DueDate).ToDictionary(group => group.Key, group => group.Any(item => !item.IsDone));
        var lmsMarkers = lms.Snapshot is { Enabled: true, HasFeedAddress: true, DisconnectPending: false }
            ? lms.All.Where(row => row.Item.DueDate >= firstVisible && row.Item.DueDate <= lastVisible)
                .GroupBy(row => row.Item.DueDate).ToDictionary(group => group.Key, group => group.Any(row => !row.IsDone))
            : [];
        for (var index = 0; index < calendarCells.Length; index++)
        {
            RenderCalendarCell(calendarCells[index], dates[index], todoMarkers, lmsMarkers);
        }
    }

    private void RenderCalendarCell(CalendarCell cell, DateOnly? date,
        IReadOnlyDictionary<DateOnly, bool> markers, IReadOnlyDictionary<DateOnly, bool> lmsMarkers)
    {
        cell.Button.Tag = date;
        cell.Button.IsEnabled = date.HasValue;
        cell.Label.Text = date?.Day.ToString(Korean) ?? "";
        bool hasIncomplete = false;
        var hasTodo = date is { } day && markers.TryGetValue(day, out hasIncomplete);
        cell.Marker.Visibility = hasTodo ? Visibility.Visible : Visibility.Hidden;
        cell.Marker.Opacity = hasIncomplete ? 1 : 0.35;
        bool hasIncompleteLms = false;
        bool hasLms = date is { } lmsDay && lmsMarkers.TryGetValue(lmsDay, out hasIncompleteLms);
        cell.LmsMarker.Visibility = hasLms ? Visibility.Visible : Visibility.Hidden;
        cell.LmsMarker.Opacity = hasIncompleteLms ? 1 : 0.35;
        cell.LmsMarker.SetResourceReference(Shape.FillProperty, hasIncompleteLms && date < state.Today ? "OverdueAccent" : "LmsAccent");
        cell.Label.Opacity = date?.Month == state.DisplayMonth.Month ? 1 : 0.66;
        cell.Label.FontWeight = date == state.Today ? FontWeights.Bold : FontWeights.Normal;

        if (date == state.SelectedDate)
        {
            cell.Button.SetResourceReference(BorderBrushProperty, "TodoAccent");
            cell.Button.BorderThickness = new Thickness(2);
        }
        else
        {
            cell.Button.ClearValue(BorderBrushProperty);
            cell.Button.ClearValue(BorderThicknessProperty);
        }

        var description = date?.ToString("yyyy년 M월 d일 dddd", Korean) ?? "";
        if (date == state.Today)
        {
            description += ", 오늘";
        }
        if (date == state.SelectedDate)
        {
            description += ", 선택됨";
        }
        if (hasTodo)
        {
            description += ", 할 일 있음";
        }
        if (hasLms)
        {
            description += ", LMS 과제 있음";
        }
        AutomationProperties.SetName(cell.Button, description);
    }

    private void ToggleMode(object sender, RoutedEventArgs e)
    {
        var localDate = today();
        state.RefreshToday(localDate);
        if (state.Mode == PanelMode.Calendar)
        {
            state.ShowList();
        }
        else
        {
            state.OpenCalendar(localDate);
        }

        chosenDueDate = null;
        RenderState();
        PanelScroll.ScrollToTop();
    }

    private void PreviousMonth(object sender, RoutedEventArgs e) => MoveMonth(-1);

    private void NextMonth(object sender, RoutedEventArgs e) => MoveMonth(1);

    private void MoveMonth(int months)
    {
        state.RefreshToday(today());
        state.MoveMonth(months);
        RenderState();
    }

    private void GoToToday(object sender, RoutedEventArgs e)
    {
        state.GoToToday(today());
        RenderState();
    }

    private void SelectDate(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: DateOnly date } button)
        {
            var hadKeyboardFocus = button.IsKeyboardFocused;
            state.RefreshToday(today());
            state.SelectDate(date);
            RenderState();
            if (hadKeyboardFocus && !Equals(button.Tag, date))
            {
                calendarCells.First(cell => Equals(cell.Button.Tag, date)).Button.Focus();
            }
        }
    }

    private void OpenEditor(object sender, RoutedEventArgs e) => EditorRequested?.Invoke();

    private void OpenSettings(object sender, RoutedEventArgs e) => SettingsRequested?.Invoke();

    private void OnKeyDown(object sender, KeyEventArgs e)
    {
        // Let the TextBox and IME process the key before treating it as panel dismissal.
        if (e.Key == Key.Escape && !composing)
        {
            e.Handled = true;
            if (DueDatePicker.Visibility == Visibility.Visible)
            {
                HideDatePicker(DueDateButton);
            }
            else
            {
                DismissRequested?.Invoke();
            }
        }
    }

    private void ToggleDatePicker(object sender, RoutedEventArgs e)
    {
        if (DueDatePicker.Visibility == Visibility.Visible)
        {
            HideDatePicker(DueDateButton);
            return;
        }

        state.RefreshToday(today());
        DateTime date = DraftDueDate.ToDateTime(TimeOnly.MinValue);
        PickerCalendar.DisplayMode = CalendarMode.Month;
        PickerCalendar.SelectedDate = date;
        PickerCalendar.DisplayDate = date;
        DueDatePicker.Visibility = Visibility.Visible;
        RenderState();
        PickTodayButton.Focus();
    }

    private void PickRelativeDate(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string days })
        {
            DateOnly localDate = today();
            state.RefreshToday(localDate);
            int offset = int.Parse(days, CultureInfo.InvariantCulture);
            chosenDueDate = offset == 0 ? null
                : localDate.AddDays(Math.Min(offset, DateOnly.MaxValue.DayNumber - localDate.DayNumber));
            RenderState();
            HideDatePicker(InputBox);
        }
    }

    private void PickCalendarDate(object sender, RoutedEventArgs e)
    {
        if (PickerCalendar.SelectedDate is { } date)
        {
            chosenDueDate = DateOnly.FromDateTime(date);
            state.RefreshToday(today());
            RenderState();
            HideDatePicker(InputBox);
        }
    }

    private void HideDatePicker(Control focusTarget)
    {
        DueDatePicker.Visibility = Visibility.Collapsed;
        PanelSizeChanged?.Invoke();
        focusTarget.Focus();
    }

    private void UpdateDueDateLabel()
    {
        DateOnly date = DraftDueDate;
        string label = date == state.Today ? "오늘" : date.ToString("M/d(ddd)", Korean);
        DueDateButton.Content = label;
        CalendarDueDate.Text = label;
        AutomationProperties.SetName(DueDateButton, $"마감 날짜, {label}");
    }

    private void OnInputKeyDown(object sender, KeyEventArgs e)
    {
        // IME-processed Enter belongs to the composition even if the completion event just cleared `composing`.
        if (e.Key == Key.Enter && !composing && !e.IsRepeat)
        {
            e.Handled = true;
            SaveDraft();
        }
    }

    private void AddTodo(object sender, RoutedEventArgs e) => SaveDraft();

    private void SaveDraft()
    {
        state.RefreshToday(today());
        if (!CanModifySelectedDay || composing || todos.LoadError is not null || string.IsNullOrWhiteSpace(InputBox.Text))
        {
            return;
        }

        if (TrySave(() => todos.Add(InputBox.Text, DraftDueDate)))
        {
            InputBox.Clear();
            chosenDueDate = null;
            DueDatePicker.Visibility = Visibility.Collapsed;
            ModeButton.Focus();
        }
        else if (saveError is null)
        {
            // Keep the draft so the user can shorten it or remove line breaks.
            saveError = InvalidTitleMessage;
        }
        RenderState();
    }

    private void ToggleTodo(object sender, RoutedEventArgs e)
    {
        if (sender is CheckBox { DataContext: TodoRow row } checkbox)
        {
            state.RefreshToday(today());
            if (CanModifySelectedDay && todos.LoadError is null)
            {
                TrySave(() => todos.ToggleDone(row.Item.Id));
            }
            bool restoreFocus = checkbox.IsKeyboardFocused;
            RenderState();
            if (restoreFocus)
            {
                RestoreTodoFocus(row.Item.Id);
            }
        }
    }

    private void DeleteTodo(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { DataContext: TodoRow row } || !row.CanDelete || state.Mode != PanelMode.List)
        {
            return;
        }

        if (pendingDelete != row)
        {
            DisarmDelete();
            pendingDelete = row;
            row.SetDeleteArmed(true);
            return;
        }

        TrySave(() => todos.Delete(row.Item.Id));
        RenderState();
        InputBox.Focus();
    }

    private bool TrySave(Func<bool> save)
    {
        savingTodo = true;
        try
        {
            var changed = save();
            saveError = null;
            return changed;
        }
        catch (TodoStorageException exception)
        {
            saveError = exception.Message;
            return false;
        }
        finally
        {
            savingTodo = false;
        }
    }

    private void CancelDelete(object sender, MouseEventArgs e)
    {
        if (sender is FrameworkElement row && row.DataContext == pendingDelete)
        {
            DisarmDelete();
        }
    }

    private void CancelDeleteOnFocusLoss(object sender, KeyboardFocusChangedEventArgs e)
    {
        if (sender is FrameworkElement row && !row.IsKeyboardFocusWithin && row.DataContext == pendingDelete)
        {
            DisarmDelete();
        }
    }

    private void DisarmDelete()
    {
        pendingDelete?.SetDeleteArmed(false);
        pendingDelete = null;
    }

    private void RestoreTodoFocus(Guid id)
    {
        Dispatcher.BeginInvoke(DispatcherPriority.Loaded, new Action(() =>
        {
            if (!IsVisible || !IsActive)
            {
                return;
            }

            var item = TodoList.Items.OfType<TodoRow>().FirstOrDefault(row => row.Item.Id == id);
            if (item is not null && TodoList.ItemContainerGenerator.ContainerFromItem(item) is ContentPresenter presenter)
            {
                presenter.ApplyTemplate();
                if (presenter.ContentTemplate?.FindName("DoneToggle", presenter) is CheckBox { IsEnabled: true } checkbox)
                {
                    checkbox.Focus();
                    return;
                }
            }
            ModeButton.Focus();
        }));
    }

    private sealed record CalendarCell(Button Button, TextBlock Label, Ellipse Marker, Ellipse LmsMarker);

    private sealed class TodoRow(TodoItem item, DateOnly today, bool canToggle, bool canDelete) : INotifyPropertyChanged
    {
        public TodoItem Item => item;
        public bool CanToggle => canToggle;
        public bool CanDelete => canDelete;
        public bool IsOverdue => !Item.IsDone && Item.DueDate < today;
        public bool DeleteArmed { get; private set; }
        public string DayLabel => Item.DayLabel(today);
        public string DateLabel => Item.DueDate.ToString("M/d(ddd)", Korean);
        public Visibility DeleteVisibility => CanDelete ? Visibility.Visible : Visibility.Collapsed;
        public string DeleteLabel => DeleteArmed ? "삭제?" : "×";
        public string DeleteDescription => DeleteArmed ? $"{Item.Title} 삭제 확인" : $"{Item.Title} 삭제";
        public string CompletionLabel => $"{Item.Title} {(Item.IsDone ? "완료 취소" : "완료")}";
        public event PropertyChangedEventHandler? PropertyChanged;

        public void SetDeleteArmed(bool armed)
        {
            DeleteArmed = armed;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null));
        }
    }
}
