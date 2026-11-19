using System.ComponentModel;
using System.Globalization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
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
            var label = new TextBlock { Text = weekday, TextAlignment = TextAlignment.Center, FontSize = 12 };
            label.SetResourceReference(TextBlock.ForegroundProperty, "DoIt.Muted");
            Weekdays.Children.Add(label);
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
            // Rows are about 46 high and calendar cells 52 with margins. 760 fits a six-week month, the day's
            // heading and about three rows before scrolling; 560 fits the list header, three LMS rows and
            // about four todos. PanelPlacement still shrinks the panel to the work area.
            double height = Math.Ceiling(PanelContent.DesiredSize.Height) + FrameBorder;
            return new Size(width, Math.Clamp(height, 170, calendar ? 760 : 560));
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
        string modeName = showsCalendar ? "할 일 목록 보기" : "월간 달력 보기";
        ModeButton.Content = showsCalendar ? "\uE8FD" : "\uE787";
        ModeButton.Style = (Style)FindResource(showsCalendar ? "DoIt.IconButton.Active" : "DoIt.IconButton");
        ModeButton.ToolTip = modeName;
        AutomationProperties.SetName(ModeButton, modeName);
        TodayLabel.Text = state.Today.ToString("M/d(ddd)", Korean);
        PlaceInputArea(showsCalendar);

        if (showsCalendar)
        {
            MonthHeading.Text = state.DisplayMonth.ToString("yyyy년 M월", Korean);
            DayHeading.Text = state.SelectedDate == state.Today
                ? state.SelectedDate.ToString("M월 d일", Korean) + " · 오늘"
                : state.SelectedDate.ToString("M월 d일 (ddd)", Korean);
            RenderCalendarCells();
        }
        LmsTasks.Refresh(lms, state.Today, showsCalendar ? state.SelectedDate : null);
        TodoDivider.Visibility = LmsTasks.Visibility;

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
        UpdateDueDateLabel();
        StorageError.Text = todos.LoadError ?? saveError ?? string.Empty;
        StorageError.Visibility = StorageError.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        TodoCount.Text = visibleTodos.Count.ToString(Korean);
        TodoDoneCount.Text = $"{visibleTodos.Count(item => item.IsDone)}개 완료";
        AutomationProperties.SetName(TodoHeading, $"내 할 일 {visibleTodos.Count}개");
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
            TodoDivider.Visibility = LmsTasks.Visibility;
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
        if (FindResource("DueDateMenu") is ContextMenu { IsOpen: true } menu)
        {
            menu.IsOpen = false;
        }
        DisarmDelete();
    }

    // The list keeps the input under the header; the calendar puts it under the selected day's rows.
    private void PlaceInputArea(bool calendar)
    {
        var children = PanelContent.Children;
        bool atEnd = children.IndexOf(InputArea) == children.Count - 1;
        if (calendar != atEnd)
        {
            children.Remove(InputArea);
            if (calendar)
            {
                children.Add(InputArea);
            }
            else
            {
                children.Insert(children.IndexOf(CalendarView) + 1, InputArea);
            }
        }
        InputArea.Margin = calendar ? new Thickness(0, 10, 0, 0) : new Thickness(0, 0, 0, 14);
    }

    private void OnDueChipSizeChanged(object sender, SizeChangedEventArgs e) => UpdateInputPadding();

    private void OnDueChipVisibilityChanged(object sender, DependencyPropertyChangedEventArgs e) => UpdateInputPadding();

    // Leave room on the right of the text for the date chip that sits inside the input.
    private void UpdateInputPadding()
    {
        double right = DueDateButton.IsVisible ? DueDateButton.ActualWidth + 16 : 12;
        InputBox.Padding = new Thickness(36, 9, right, 9);
    }

    private CalendarCell CreateCalendarCell()
    {
        // Today's number sits on a 28px green disc.
        var todayDisc = new Ellipse { Width = 28, Height = 28, Visibility = Visibility.Collapsed };
        todayDisc.SetResourceReference(Shape.FillProperty, "DoIt.Green");
        var label = new TextBlock
        {
            TextAlignment = TextAlignment.Center,
            FontSize = 15,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        var number = new Grid { Width = 28, Height = 28, HorizontalAlignment = HorizontalAlignment.Center };
        number.Children.Add(todayDisc);
        number.Children.Add(label);
        var marker = new Ellipse { Width = 5, Height = 5, Margin = new Thickness(1, 2, 1, 0) };
        marker.SetResourceReference(Shape.FillProperty, "TodoAccent");
        var lmsMarker = new Ellipse { Width = 5, Height = 5, Margin = new Thickness(1, 2, 1, 0) };
        lmsMarker.SetResourceReference(Shape.FillProperty, "LmsAccent");
        var markers = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center };
        markers.Children.Add(marker);
        markers.Children.Add(lmsMarker);
        var content = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        content.Children.Add(number);
        content.Children.Add(markers);

        var button = new Button
        {
            Content = content,
            Style = (Style)FindResource("CalendarCellStyle")
        };
        button.Click += SelectDate;
        CalendarGrid.Children.Add(button);
        return new CalendarCell(button, label, todayDisc, marker, lmsMarker);
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
            RenderCalendarCell(calendarCells[index], index, dates[index], todoMarkers, lmsMarkers);
        }
    }

    private void RenderCalendarCell(CalendarCell cell, int index, DateOnly? date,
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
        // Days of other months are hidden like the design. Leading ones keep their place in the first row;
        // trailing ones collapse so a five-week month uses five rows (UniformGrid skips collapsed cells).
        bool inMonth = date is { } shown && shown.Year == state.DisplayMonth.Year && shown.Month == state.DisplayMonth.Month;
        cell.Button.Visibility = inMonth ? Visibility.Visible : index < 7 ? Visibility.Hidden : Visibility.Collapsed;

        bool isToday = date == state.Today;
        bool isPast = date < state.Today;
        bool isSunday = date?.DayOfWeek == DayOfWeek.Sunday;
        cell.TodayDisc.Visibility = isToday ? Visibility.Visible : Visibility.Collapsed;
        cell.Label.FontWeight = isToday ? FontWeights.Bold : FontWeights.Normal;
        cell.Label.SetResourceReference(TextBlock.ForegroundProperty,
            isToday ? "DoIt.OnAccent" : isSunday ? "DoIt.Red" : isPast ? "DoIt.Muted" : "DoIt.Text");
        cell.Label.Opacity = !isToday && isSunday && isPast ? 0.55 : 1;

        if (date == state.SelectedDate)
        {
            cell.Button.SetResourceReference(BorderBrushProperty, "DoIt.Green");
            cell.Button.SetResourceReference(BackgroundProperty, "DoIt.GreenSoft");
            cell.Button.BorderThickness = new Thickness(1.5);
        }
        else
        {
            cell.Button.ClearValue(BorderBrushProperty);
            cell.Button.ClearValue(BackgroundProperty);
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
            if (FindResource("DueDateMenu") is ContextMenu { IsOpen: true } menu)
            {
                menu.IsOpen = false;
                DueDateButton.Focus();
            }
            else if (DueDatePicker.Visibility == Visibility.Visible)
            {
                HideDatePicker(DueDateButton);
            }
            else
            {
                DismissRequested?.Invoke();
            }
        }
    }

    // The chip opens a small menu: today, tomorrow, +1 week, or the calendar picker.
    private void ToggleDatePicker(object sender, RoutedEventArgs e)
    {
        if (DueDatePicker.Visibility == Visibility.Visible)
        {
            HideDatePicker(DueDateButton);
            return;
        }

        if (FindResource("DueDateMenu") is ContextMenu menu)
        {
            menu.PlacementTarget = DueDateButton;
            menu.Placement = PlacementMode.Bottom;
            menu.IsOpen = true;
        }
    }

    private void OpenDatePicker(object sender, RoutedEventArgs e)
    {
        state.RefreshToday(today());
        DateTime date = DraftDueDate.ToDateTime(TimeOnly.MinValue);
        PickerCalendar.DisplayMode = CalendarMode.Month;
        PickerCalendar.SelectedDate = date;
        PickerCalendar.DisplayDate = date;
        DueDatePicker.Visibility = Visibility.Visible;
        RenderState();
        // Focus after the menu has closed and handed focus back to the chip.
        Dispatcher.BeginInvoke(DispatcherPriority.Input, new Action(() => PickerCalendar.Focus()));
    }

    private void PickRelativeDate(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string days })
        {
            DateOnly localDate = today();
            state.RefreshToday(localDate);
            int offset = int.Parse(days, CultureInfo.InvariantCulture);
            chosenDueDate = offset == 0 ? null
                : localDate.AddDays(Math.Min(offset, DateOnly.MaxValue.DayNumber - localDate.DayNumber));
            RenderState();
            HideDatePicker(InputBox);
            // The menu returns focus to the chip when it closes; put it back in the input afterwards.
            Dispatcher.BeginInvoke(DispatcherPriority.Input, new Action(() => InputBox.Focus()));
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
        AutomationProperties.SetName(DueDateButton, $"마감 날짜, {label}");
        InputBox.Tag = state.Mode == PanelMode.Calendar
            ? state.SelectedDate.ToString("M월 d일", Korean) + "에 할 일 추가…"
            : "할 일 추가…";
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

    private sealed record CalendarCell(Button Button, TextBlock Label, Ellipse TodayDisc, Ellipse Marker, Ellipse LmsMarker);

    private sealed class TodoRow(TodoItem item, DateOnly today, bool canToggle, bool canDelete) : INotifyPropertyChanged
    {
        public TodoItem Item => item;
        public bool CanToggle => canToggle;
        public bool CanDelete => canDelete;
        public bool IsOverdue => !Item.IsDone && Item.DueDate < today;
        public bool IsToday => !Item.IsDone && Item.DueDate == today;
        public bool DeleteArmed { get; private set; }
        public string DayLabel => Item.DayLabel(today);
        public string DateLabel => Item.DueDate.ToString("M/d", CultureInfo.InvariantCulture);
        public string DateDetail => Item.DueDate.ToString("M/d(ddd)", Korean);
        public Visibility DeleteVisibility => CanDelete ? Visibility.Visible : Visibility.Collapsed;
        public string DeleteLabel => DeleteArmed ? "삭제?" : "\uE711";
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
