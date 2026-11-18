using System.ComponentModel;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using DoIt.Core;

namespace DoIt.Windows;

public partial class EditorWindow : Window
{
    private readonly TodoStore todos;
    private readonly LmsService lms;
    private readonly Func<DateOnly> today;
    private readonly HashSet<Guid> batchSelection = [];
    private EditorRow[] displayed = [];
    private TodoItem? draft;
    private bool composing;
    private bool deleteArmed;
    private bool saving;

    internal EditorWindow(TodoStore todos, LmsService lms, Func<DateOnly> today)
    {
        this.todos = todos;
        this.lms = lms;
        this.today = today;
        InitializeComponent();

        SearchBox.TextChanged += (_, _) =>
        {
            RefreshTodos();
            RefreshLms();
        };
        SortBox.SelectionChanged += (_, _) => RefreshTodos();
        Rows.SelectionChanged += (_, _) => UpdateEditButton();
        TextCompositionManager.AddPreviewTextInputStartHandler(TitleBox, (_, _) => composing = true);
        TextCompositionManager.AddPreviewTextInputUpdateHandler(TitleBox, (_, _) => composing = true);
        TextCompositionManager.AddPreviewTextInputHandler(TitleBox, (_, _) => composing = false);
        TitleBox.LostKeyboardFocus += (_, _) => composing = false;
        Closed += (_, _) => DatePopup.IsOpen = false;
        RefreshTodos();
        RefreshLms();
    }

    internal void RefreshLms()
    {
        LmsTasks.Refresh(lms, today(), search: SearchBox.Text);
        LmsScroll.Visibility = LmsTasks.Visibility;
    }

    internal void RefreshTodos()
    {
        if (saving)
        {
            return;
        }
        var selected = (Rows.SelectedItem as EditorRow)?.Item.Id;
        var localDate = today();
        bool canWrite = todos.LoadError is null;
        var sort = SortBox.SelectedIndex == 1 ? TodoSortOrder.Added : TodoSortOrder.DueDate;
        var visible = todos.SearchVisible(localDate, SearchBox.Text, sort);
        batchSelection.IntersectWith(visible.Select(item => item.Id));
        displayed = visible.Select(item => new EditorRow(item, localDate, canWrite, batchSelection.Contains(item.Id))).ToArray();
        Rows.ItemsSource = displayed;
        Rows.SelectedItem = displayed.FirstOrDefault(row => row.Item.Id == selected);
        EmptyResult.Visibility = displayed.Length == 0 && canWrite ? Visibility.Visible : Visibility.Collapsed;
        deleteArmed = false;
        UpdateBatchControls();

        if (draft is { } active)
        {
            var current = todos.Visible(localDate).FirstOrDefault(item => item.Id == active.Id);
            if (!canWrite || current is null)
            {
                EndDraft();
                SetStatus("편집할 할 일이 더 이상 목록에 없습니다.", true);
            }
            else if (!HasSameFields(active, current))
            {
                SetStatus("할 일이 바뀌었습니다. 편집을 취소한 뒤 다시 열어 주세요.", true);
            }
        }
        if (!canWrite)
        {
            SetStatus(todos.LoadError!, true);
        }
        UpdateEditButton();
    }

    private void UpdateEditButton() => EditSelected.IsEnabled = todos.LoadError is null && Rows.SelectedItem is EditorRow;

    private void EditSelection(object sender, RoutedEventArgs e)
    {
        if (Rows.SelectedItem is EditorRow row)
        {
            BeginEdit(row.Item);
        }
    }

    private void OnTitleMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ClickCount == 2 && sender is FrameworkElement { DataContext: EditorRow row })
        {
            e.Handled = true;
            Rows.SelectedItem = row;
            BeginEdit(row.Item);
        }
    }

    private void BeginEdit(TodoItem item)
    {
        if (todos.LoadError is not null)
        {
            return;
        }
        if (draft is { } previous)
        {
            if (previous.Id == item.Id)
            {
                TitleBox.Focus();
                return;
            }
            if (TitleBox.Text != previous.Title || DueBox.Text != FormatDate(previous.DueDate))
            {
                SetStatus("편집 중인 할 일을 먼저 저장하거나 취소해 주세요.", true);
                return;
            }
        }

        deleteArmed = false;
        UpdateBatchControls();
        draft = item;
        TitleBox.Text = item.Title;
        DueBox.Text = FormatDate(item.DueDate);
        DraftControls.Visibility = Visibility.Visible;
        SetStatus("");
        TitleBox.Focus();
        TitleBox.SelectAll();
    }

    private void OnDraftKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter && !composing && !e.IsRepeat)
        {
            e.Handled = true;
            SaveDraft();
        }
    }

    private void OnWindowKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Escape || composing)
        {
            return;
        }
        if (DatePopup.IsOpen)
        {
            e.Handled = true;
            CloseCalendar();
        }
        else if (draft is not null)
        {
            e.Handled = true;
            CancelDraft();
        }
        else if (deleteArmed)
        {
            e.Handled = true;
            deleteArmed = false;
            UpdateBatchControls();
        }
    }

    private void OpenCalendar(object sender, RoutedEventArgs e)
    {
        if (draft is not { } active)
        {
            return;
        }
        DateOnly date = ParseDate(DueBox.Text, out var typed) ? typed : active.DueDate;
        DateTime selected = date.ToDateTime(TimeOnly.MinValue);
        DueCalendar.DisplayMode = CalendarMode.Month;
        DueCalendar.SelectedDate = selected;
        DueCalendar.DisplayDate = selected;
        DatePopup.IsOpen = true;
    }

    private void OnCalendarOpened(object? sender, EventArgs e) => DueCalendar.MoveFocus(new TraversalRequest(FocusNavigationDirection.First));

    private void OnCalendarKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape)
        {
            e.Handled = true;
            CloseCalendar();
        }
    }

    private void ApplyCalendarDate(object sender, RoutedEventArgs e)
    {
        if (DueCalendar.SelectedDate is { } selected)
        {
            DueBox.Text = FormatDate(DateOnly.FromDateTime(selected));
        }
        CloseCalendar();
    }

    private void CloseCalendar()
    {
        DatePopup.IsOpen = false;
        DueBox.Focus();
    }

    private void SaveEdit(object sender, RoutedEventArgs e) => SaveDraft();

    private void SaveDraft()
    {
        if (draft is not { } active || composing || todos.LoadError is not null)
        {
            return;
        }
        if (todos.All.FirstOrDefault(item => item.Id == active.Id) is not { } current || !HasSameFields(active, current))
        {
            SetStatus("할 일이 바뀌었습니다. 편집을 취소한 뒤 다시 열어 주세요.", true);
            return;
        }
        if (!ParseDate(DueBox.Text, out var dueDate))
        {
            SetStatus("마감일을 연도-월-일 형식으로 입력해 주세요.", true);
            DueBox.Focus();
            return;
        }
        if (!TodoStore.IsValidEditorTitle(TitleBox.Text))
        {
            SetStatus("제목을 1~200자로 입력해 주세요. 줄바꿈은 사용할 수 없습니다.", true);
            TitleBox.Focus();
            return;
        }

        if (TrySave(() => todos.Update(active.Id, TitleBox.Text, dueDate), "수정할 할 일을 찾을 수 없습니다."))
        {
            EndDraft();
            RefreshTodos();
            FocusSelectedRow();
            SetStatus("저장했습니다.");
        }
    }

    private void CancelEdit(object sender, RoutedEventArgs e) => CancelDraft();

    private void CancelDraft()
    {
        EndDraft();
        SetStatus("");
        FocusSelectedRow();
    }

    private void EndDraft()
    {
        DatePopup.IsOpen = false;
        draft = null;
        composing = false;
        DraftControls.Visibility = Visibility.Collapsed;
        TitleBox.Clear();
        DueBox.Clear();
    }

    private void FocusSelectedRow()
    {
        if (Rows.SelectedItem is not null)
        {
            Rows.Focus();
        }
        else
        {
            SearchBox.Focus();
        }
    }

    private void ToggleBatchItem(object sender, RoutedEventArgs e)
    {
        if (sender is not CheckBox { DataContext: EditorRow row } checkbox)
        {
            return;
        }
        row.IsBatchSelected = checkbox.IsChecked == true;
        if (row.IsBatchSelected)
        {
            batchSelection.Add(row.Item.Id);
        }
        else
        {
            batchSelection.Remove(row.Item.Id);
        }
        deleteArmed = false;
        UpdateBatchControls();
    }

    private void ClearBatch(object sender, RoutedEventArgs e)
    {
        batchSelection.Clear();
        foreach (var row in displayed)
        {
            row.IsBatchSelected = false;
        }
        deleteArmed = false;
        UpdateBatchControls();
        FocusSelectedRow();
    }

    private void MarkDone(object sender, RoutedEventArgs e) => SetDone(true);

    private void MarkIncomplete(object sender, RoutedEventArgs e) => SetDone(false);

    private void SetDone(bool isDone)
    {
        var ids = batchSelection.ToArray();
        deleteArmed = false;
        UpdateBatchControls();
        if (ids.Length > 0 && TrySave(() => todos.SetDone(ids, isDone), "선택한 할 일은 이미 같은 상태입니다."))
        {
            RefreshTodos();
            SetStatus(isDone ? "선택한 할 일을 완료했습니다." : "선택한 할 일을 미완료로 바꿨습니다.");
        }
    }

    private void DeleteBatch(object sender, RoutedEventArgs e)
    {
        if (batchSelection.Count == 0)
        {
            return;
        }
        if (!deleteArmed)
        {
            deleteArmed = true;
            UpdateBatchControls();
            return;
        }

        var ids = batchSelection.ToArray();
        deleteArmed = false;
        UpdateBatchControls();
        if (TrySave(() => todos.DeleteMany(ids), "삭제할 할 일을 찾을 수 없습니다."))
        {
            RefreshTodos();
            FocusSelectedRow();
            SetStatus("선택한 할 일을 삭제했습니다.");
        }
    }

    private void UpdateBatchControls()
    {
        int count = batchSelection.Count;
        BatchControls.Visibility = count > 0 ? Visibility.Visible : Visibility.Collapsed;
        BatchCount.Text = $"{count}개 선택";
        DeleteSelected.Content = deleteArmed ? $"{count}개 삭제 확인" : "삭제";
    }

    private bool TrySave(Func<bool> save, string unchangedMessage)
    {
        saving = true;
        try
        {
            if (save())
            {
                return true;
            }
            SetStatus(unchangedMessage);
        }
        catch (TodoStorageException exception)
        {
            SetStatus(exception.Message, true);
        }
        finally
        {
            saving = false;
        }
        return false;
    }

    private void SetStatus(string message, bool error = false)
    {
        StatusText.Text = message;
        if (error)
        {
            StatusText.SetResourceReference(TextBlock.ForegroundProperty, "OverdueAccent");
        }
        else
        {
            StatusText.ClearValue(TextBlock.ForegroundProperty);
        }
    }

    private static bool ParseDate(string text, out DateOnly result) =>
        DateOnly.TryParseExact(text.Trim(), "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out result);

    private static string FormatDate(DateOnly date) => date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    private static bool HasSameFields(TodoItem before, TodoItem after) =>
        before.Title == after.Title && before.DueDate == after.DueDate;

    private sealed class EditorRow(TodoItem item, DateOnly today, bool canWrite, bool batchSelected) : INotifyPropertyChanged
    {
        private bool isBatchSelected = batchSelected;

        public TodoItem Item { get; } = item;
        public bool IsWritable { get; } = canWrite;
        public string BatchLabel => $"{Item.Title}, 일괄 작업 선택";
        public string CompletionLabel => Item.IsDone ? "완료" : "미완료";
        public string DateLabel => FormatDate(Item.DueDate);
        public string DayLabel => Item.DayLabel(today);
        public bool IsOverdue => !Item.IsDone && Item.DueDate < today;

        public bool IsBatchSelected
        {
            get => isBatchSelected;
            set
            {
                if (isBatchSelected != value)
                {
                    isBatchSelected = value;
                    PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IsBatchSelected)));
                }
            }
        }

        public event PropertyChangedEventHandler? PropertyChanged;
    }
}
