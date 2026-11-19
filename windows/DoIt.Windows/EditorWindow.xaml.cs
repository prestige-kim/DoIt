using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using DoIt.Core;

namespace DoIt.Windows;

public partial class EditorWindow : Window
{
    private const int DwmUseImmersiveDarkMode = 20;

    private readonly TodoStore todos;
    private readonly LmsService lms;
    private readonly Func<DateOnly> today;
    private readonly HashSet<Guid> batchSelection = [];
    private readonly ObservableCollection<EditorRow> displayed = [];

    // 제목 그 자리 수정 상태. 목록을 새로 그려도 유지한다.
    private Guid? editingId;
    private TodoItem? editingOriginal;
    private string editingText = "";
    private string editingError = "";
    private TextBox? activeEditor;
    private bool focusEditorPending;
    private bool committing;

    private EditorRow? dateRow;
    private Button? dateButton;
    private bool composing;
    private bool deleteArmed;
    private bool saving;

    internal EditorWindow(TodoStore todos, LmsService lms, Func<DateOnly> today)
    {
        this.todos = todos;
        this.lms = lms;
        this.today = today;
        InitializeComponent();
        Rows.ItemsSource = displayed;

        SearchBox.TextChanged += (_, _) =>
        {
            RefreshTodos();
            RefreshLms();
        };
        SortDue.Checked += (_, _) => RefreshTodos();
        SortAdded.Checked += (_, _) => RefreshTodos();
        // 한글 조합 중 Enter·Esc는 무시한다. 조합 이벤트는 창으로 터널링되므로 행마다 붙이지 않는다.
        TextCompositionManager.AddPreviewTextInputStartHandler(this, (_, _) => composing = true);
        TextCompositionManager.AddPreviewTextInputUpdateHandler(this, (_, _) => composing = true);
        TextCompositionManager.AddPreviewTextInputHandler(this, (_, _) => composing = false);
        SearchBox.LostKeyboardFocus += (_, _) => composing = false;
        SourceInitialized += (_, _) => ApplyTitleBarTheme();
        Activated += (_, _) => ApplyTitleBarTheme();
        Closed += (_, _) => DatePopup.IsOpen = false;
        RefreshTodos();
        RefreshLms();
    }

    internal void RefreshLms()
    {
        var localDate = today();
        var snapshot = lms.Snapshot;
        IReadOnlyList<LmsRow> rows = snapshot.Enabled ? lms.Visible(localDate) : [];
        var query = SearchBox.Text.Trim().Normalize(NormalizationForm.FormC);
        if (query.Length > 0)
        {
            rows = rows.Where(row => row.Item.Title.Normalize(NormalizationForm.FormC)
                .Contains(query, StringComparison.OrdinalIgnoreCase)).ToArray();
        }
        var status = snapshot.Enabled && (snapshot.IsSyncing || snapshot.Status is not (LmsSyncStatus.Ok or LmsSyncStatus.Never))
            ? LmsSection.StatusLabel(snapshot) : string.Empty;
        LmsStatus.Text = status;
        LmsStatus.Visibility = status.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        bool canToggle = snapshot is { Enabled: true, HasFeedAddress: true, DisconnectPending: false };
        LmsRows.ItemsSource = rows.Select(row => new LmsEditorRow(row, localDate, canToggle)).ToArray();
        LmsPanel.Visibility = rows.Count == 0 && status.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        if (LmsPanel.Visibility == Visibility.Collapsed)
        {
            LmsCheckError.Visibility = Visibility.Collapsed;
        }
    }

    private void ToggleLmsDone(object sender, RoutedEventArgs e)
    {
        if (sender is CheckBox { DataContext: LmsEditorRow row } checkbox && row.CanToggle)
        {
            // WPF가 먼저 체크 모양을 바꾼다. 저장에 실패하면 원래 상태로 되돌린다.
            bool saved = lms.ToggleDone(row.Row.Item.Uid);
            if (!saved)
            {
                checkbox.SetCurrentValue(ToggleButton.IsCheckedProperty, row.Row.IsDone);
            }
            LmsCheckError.Visibility = saved ? Visibility.Collapsed : Visibility.Visible;
        }
    }

    internal void RefreshTodos()
    {
        if (saving)
        {
            return;
        }
        var localDate = today();
        bool canWrite = todos.LoadError is null;
        var sort = SortAdded.IsChecked == true ? TodoSortOrder.Added : TodoSortOrder.DueDate;
        var visible = todos.SearchVisible(localDate, SearchBox.Text, sort);
        batchSelection.IntersectWith(visible.Select(item => item.Id));
        SyncRows(visible, localDate, canWrite);
        EmptyResult.Visibility = displayed.Count == 0 && canWrite ? Visibility.Visible : Visibility.Collapsed;
        deleteArmed = false;
        UpdateBatchControls();

        if (editingId is { } id && editingOriginal is { } original)
        {
            var current = todos.Visible(localDate).FirstOrDefault(item => item.Id == id);
            if (!canWrite || current is null || displayed.All(row => row.Item.Id != id))
            {
                EndEdit();
                SetStatus("편집할 할 일이 더 이상 목록에 없습니다.", true);
            }
            else if (!HasSameFields(original, current))
            {
                SetEditError("할 일이 바뀌었습니다. Esc로 취소한 뒤 다시 수정해 주세요.");
            }
        }
        if (!canWrite)
        {
            SetStatus(todos.LoadError!, true);
        }
    }

    // 같은 할 일의 행 객체를 다시 쓴다. 행을 통째로 새로 만들면 누르던 버튼이 사라져 클릭이 사라진다.
    private void SyncRows(IReadOnlyList<TodoItem> visible, DateOnly localDate, bool canWrite)
    {
        var wanted = visible.Select(item => item.Id).ToHashSet();
        for (int index = displayed.Count - 1; index >= 0; index--)
        {
            if (!wanted.Contains(displayed[index].Item.Id))
            {
                displayed.RemoveAt(index);
            }
        }
        for (int index = 0; index < visible.Count; index++)
        {
            var item = visible[index];
            int existing = -1;
            for (int search = index; search < displayed.Count; search++)
            {
                if (displayed[search].Item.Id == item.Id)
                {
                    existing = search;
                    break;
                }
            }
            if (existing < 0)
            {
                displayed.Insert(index, new EditorRow(item));
            }
            else if (existing != index)
            {
                displayed.Move(existing, index);
            }
            var row = displayed[index];
            row.Update(item, localDate, canWrite, batchSelection.Contains(item.Id));
            row.IsEditing = editingId == item.Id;
            row.EditError = row.IsEditing ? editingError : "";
        }
    }

    // ---------- 제목 그 자리 수정 ----------

    private void OnTitleMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ClickCount == 2 && sender is FrameworkElement { DataContext: EditorRow row })
        {
            e.Handled = true;
            BeginEdit(row);
        }
    }

    private void EditTitle(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: EditorRow row })
        {
            BeginEdit(row);
        }
    }

    private void OnRowKeyDown(object sender, KeyEventArgs e)
    {
        // 행의 체크 위에서 Enter = 제목 수정. Space는 체크 자체가 처리한다(선택 체크 = 일괄 선택 토글).
        if (e.Key == Key.Enter && !e.IsRepeat && e.OriginalSource is CheckBox { DataContext: EditorRow row })
        {
            e.Handled = true;
            BeginEdit(row);
        }
    }

    private void BeginEdit(EditorRow row)
    {
        if (todos.LoadError is not null || !row.IsWritable)
        {
            return;
        }
        if (editingId == row.Item.Id)
        {
            activeEditor?.Focus();
            return;
        }
        if (editingId is not null && !CommitEdit())
        {
            return;
        }

        deleteArmed = false;
        UpdateBatchControls();
        editingId = row.Item.Id;
        editingOriginal = row.Item;
        editingText = row.Item.Title;
        editingError = "";
        focusEditorPending = true;
        SetStatus("");
        row.EditError = "";
        row.IsEditing = true;
    }

    private void OnTitleEditorVisibleChanged(object sender, DependencyPropertyChangedEventArgs e)
    {
        if (sender is not TextBox { DataContext: EditorRow row } box || !box.IsVisible || editingId != row.Item.Id)
        {
            return;
        }
        activeEditor = box;
        box.Text = editingText;
        if (focusEditorPending)
        {
            focusEditorPending = false;
            box.Focus();
            box.SelectAll();
        }
    }

    private void OnTitleEditorTextChanged(object sender, TextChangedEventArgs e)
    {
        if (sender is TextBox { DataContext: EditorRow row } box && editingId == row.Item.Id && ReferenceEquals(box, activeEditor))
        {
            editingText = box.Text;
        }
    }

    private void OnTitleEditorKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter && !composing && !e.IsRepeat)
        {
            e.Handled = true;
            if (CommitEdit())
            {
                FocusRow(sender);
            }
        }
    }

    private void OnTitleEditorLostFocus(object sender, KeyboardFocusChangedEventArgs e)
    {
        composing = false;
        // 창이 비활성화되어 포커스가 창 밖으로 나간 경우(NewFocus 없음)는 수정 중 상태를 그대로 둔다.
        if (ReferenceEquals(sender, activeEditor) && editingId is not null && e.NewFocus is not null)
        {
            CommitEdit();
        }
    }

    private void OnWindowMouseDown(object sender, MouseButtonEventArgs e)
    {
        // 입력칸 밖을 누르면 저장한다(포커스를 받지 않는 빈 곳을 눌렀을 때도).
        if (editingId is not null && activeEditor is { } box && e.OriginalSource is DependencyObject source
            && !IsWithin(source, box))
        {
            CommitEdit();
        }
    }

    // 저장했거나 수정 중이 아니면 true. 검증·저장 실패면 수정 상태를 유지하고 false.
    private bool CommitEdit()
    {
        if (editingId is not { } id || editingOriginal is not { } original)
        {
            return true;
        }
        if (committing || composing)
        {
            return false;
        }
        if (todos.LoadError is not null)
        {
            EndEdit();
            return true;
        }
        if (todos.All.FirstOrDefault(item => item.Id == id) is not { } current || !HasSameFields(original, current))
        {
            SetEditError("할 일이 바뀌었습니다. Esc로 취소한 뒤 다시 수정해 주세요.");
            return false;
        }
        string text = editingText;
        if (!TodoStore.IsValidEditorTitle(text))
        {
            SetEditError("제목을 1~200자로 입력해 주세요. 줄바꿈은 사용할 수 없습니다.");
            return false;
        }
        if (text.Trim() == current.Title)
        {
            EndEdit();
            return true;
        }

        committing = true;
        try
        {
            if (TrySave(() => todos.Update(id, text, current.DueDate), "수정할 할 일을 찾을 수 없습니다."))
            {
                EndEdit();
                RefreshTodos();
                SetStatus("저장했습니다.");
                return true;
            }
            return false;
        }
        finally
        {
            committing = false;
        }
    }

    private void CancelEdit()
    {
        var box = activeEditor;
        EndEdit();
        SetStatus("");
        if (box is not null)
        {
            FocusRow(box);
        }
    }

    private void EndEdit()
    {
        var id = editingId;
        editingId = null;
        editingOriginal = null;
        editingText = "";
        editingError = "";
        focusEditorPending = false;
        activeEditor = null;
        composing = false;
        if (displayed.FirstOrDefault(row => row.Item.Id == id) is { } row)
        {
            row.IsEditing = false;
            row.EditError = "";
        }
    }

    private void SetEditError(string message)
    {
        editingError = message;
        if (displayed.FirstOrDefault(row => row.Item.Id == editingId) is { } row)
        {
            row.EditError = message;
        }
    }

    // 수정을 마친 행의 첫 칸(선택 체크)으로 포커스를 돌린다.
    private void FocusRow(object element)
    {
        if (element is FrameworkElement { DataContext: EditorRow row }
            && Rows.ItemContainerGenerator.ContainerFromItem(row) is UIElement container
            && container.MoveFocus(new TraversalRequest(FocusNavigationDirection.First)))
        {
            return;
        }
        SearchBox.Focus();
    }

    // ---------- 키보드 ----------

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
        else if (editingId is not null)
        {
            e.Handled = true;
            CancelEdit();
        }
        else if (deleteArmed)
        {
            e.Handled = true;
            deleteArmed = false;
            UpdateBatchControls();
        }
    }

    // ---------- 완료 토글 ----------

    private void ToggleTodoDone(object sender, RoutedEventArgs e)
    {
        if (sender is not CheckBox { DataContext: EditorRow row } checkbox || !row.IsWritable)
        {
            return;
        }
        if (TrySave(() => todos.ToggleDone(row.Item.Id), "완료 상태를 바꿀 할 일을 찾을 수 없습니다."))
        {
            RefreshTodos();
        }
        else
        {
            checkbox.SetCurrentValue(ToggleButton.IsCheckedProperty, row.Item.IsDone);
        }
    }

    // ---------- 날짜 수정 ----------

    private void OpenCalendar(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { DataContext: EditorRow row } button || !row.IsWritable || todos.LoadError is not null)
        {
            return;
        }
        dateRow = row;
        dateButton = button;
        DateTime selected = row.Item.DueDate.ToDateTime(TimeOnly.MinValue);
        DueCalendar.DisplayMode = CalendarMode.Month;
        DueCalendar.SelectedDate = selected;
        DueCalendar.DisplayDate = selected;
        DatePopup.PlacementTarget = button;
        DatePopup.IsOpen = true;
    }

    private void OnCalendarOpened(object? sender, EventArgs e) => DueCalendar.MoveFocus(new TraversalRequest(FocusNavigationDirection.First));

    private void OnCalendarClosed(object? sender, EventArgs e)
    {
        // Calendar는 날짜를 누른 뒤 마우스 캡처를 쥐고 있을 수 있다.
        if (Mouse.Captured is { } captured && IsWithin(captured as DependencyObject, DueCalendar))
        {
            Mouse.Capture(null);
        }
    }

    private void OnCalendarKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape)
        {
            e.Handled = true;
            CloseCalendar();
        }
        else if (e.Key == Key.Enter && !e.IsRepeat)
        {
            // 화살표는 날짜만 옮기고, Enter로 고른 날짜를 저장한다.
            e.Handled = true;
            ApplyPickedDate();
        }
    }

    private void OnCalendarMouseUp(object sender, MouseButtonEventArgs e)
    {
        if (FindAncestor<CalendarDayButton>(e.OriginalSource as DependencyObject) is not null)
        {
            // 선택은 마우스를 누를 때 바뀐다. 클릭 처리가 끝난 뒤 저장한다.
            Dispatcher.BeginInvoke(new Action(ApplyPickedDate), DispatcherPriority.Input);
        }
    }

    private void ApplyPickedDate()
    {
        if (!DatePopup.IsOpen || dateRow is not { } row || DueCalendar.SelectedDate is not { } selected)
        {
            return;
        }
        var date = DateOnly.FromDateTime(selected);
        CloseCalendar();
        if (todos.All.FirstOrDefault(item => item.Id == row.Item.Id) is not { } current)
        {
            SetStatus("수정할 할 일을 찾을 수 없습니다.", true);
            return;
        }
        if (current.DueDate == date)
        {
            return;
        }
        if (TrySave(() => todos.Update(current.Id, current.Title, date), "수정할 할 일을 찾을 수 없습니다."))
        {
            if (editingId == current.Id && todos.All.FirstOrDefault(item => item.Id == current.Id) is { } updated)
            {
                editingOriginal = updated;
            }
            RefreshTodos();
            SetStatus("마감일을 바꿨습니다.");
        }
    }

    private void CloseCalendar()
    {
        DatePopup.IsOpen = false;
        if (dateButton is { IsVisible: true } button)
        {
            button.Focus();
        }
    }

    // ---------- 일괄 작업 ----------

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
        SearchBox.Focus();
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
            SearchBox.Focus();
            SetStatus("선택한 할 일을 삭제했습니다.");
        }
    }

    private void UpdateBatchControls()
    {
        int count = batchSelection.Count;
        BatchControls.Visibility = count > 0 ? Visibility.Visible : Visibility.Collapsed;
        // 떠 있는 막대가 마지막 행을 가리지 않게 본문 아래 여백을 둔다.
        BodyPanel.Margin = new Thickness(0, 8, 0, count > 0 ? 80 : 16);
        BatchCount.Text = $"{count}개 선택";
        DeleteSelected.Content = deleteArmed ? $"{count}개 삭제?" : "삭제";
        if (deleteArmed)
        {
            DeleteSelected.SetResourceReference(BackgroundProperty, "DoIt.RedSoft");
        }
        else
        {
            DeleteSelected.ClearValue(BackgroundProperty);
        }
    }

    // ---------- 공통 ----------

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

    private void ApplyTitleBarTheme()
    {
        var handle = new WindowInteropHelper(this).Handle;
        if (handle == 0)
        {
            return;
        }
        int dark = AppTheme.IsLight ? 0 : 1;
        // 실패해도(오래된 Windows) 기본 제목줄로 남는다.
        _ = DwmSetWindowAttribute(handle, DwmUseImmersiveDarkMode, ref dark, sizeof(int));
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(nint window, int attribute, ref int value, int size);

    private static bool IsWithin(DependencyObject? node, DependencyObject ancestor)
    {
        while (node is not null)
        {
            if (ReferenceEquals(node, ancestor))
            {
                return true;
            }
            node = node is Visual or System.Windows.Media.Media3D.Visual3D
                ? VisualTreeHelper.GetParent(node) ?? LogicalTreeHelper.GetParent(node)
                : LogicalTreeHelper.GetParent(node);
        }
        return false;
    }

    private static T? FindAncestor<T>(DependencyObject? node) where T : DependencyObject
    {
        while (node is not null and not T)
        {
            node = node is Visual or System.Windows.Media.Media3D.Visual3D
                ? VisualTreeHelper.GetParent(node)
                : LogicalTreeHelper.GetParent(node);
        }
        return node as T;
    }

    private static string ShortDate(DateOnly date) => date.ToString("M/d", CultureInfo.InvariantCulture);

    private static bool HasSameFields(TodoItem before, TodoItem after) =>
        before.Title == after.Title && before.DueDate == after.DueDate;

    private sealed class EditorRow(TodoItem item) : INotifyPropertyChanged
    {
        private DateOnly today;
        private bool isBatchSelected;
        private bool isEditing;
        private string editError = "";

        public TodoItem Item { get; private set; } = item;
        public bool IsWritable { get; private set; }
        public string BatchLabel => $"{Item.Title}, 일괄 작업 선택";
        public string DoneLabel => $"{Item.Title}, 완료 체크";
        public string EditLabel => $"{Item.Title}, 제목 수정 입력칸";
        public string PencilLabel => $"{Item.Title}, 제목 수정";
        public string DateLabel => $"{ShortDate(Item.DueDate)} · {Item.DayLabel(today)}";
        public string DateButtonLabel =>
            $"{Item.Title}, 마감일 {Item.DueDate.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture)} 바꾸기";
        public bool IsOverdue => !Item.IsDone && Item.DueDate < today;

        public bool IsBatchSelected
        {
            get => isBatchSelected;
            set => Set(ref isBatchSelected, value, nameof(IsBatchSelected));
        }

        public bool IsEditing
        {
            get => isEditing;
            set => Set(ref isEditing, value, nameof(IsEditing));
        }

        public string EditError
        {
            get => editError;
            set
            {
                if (editError != value)
                {
                    editError = value;
                    Raise(nameof(EditError));
                    Raise(nameof(HasEditError));
                }
            }
        }

        public bool HasEditError => editError.Length > 0;

        public event PropertyChangedEventHandler? PropertyChanged;

        public void Update(TodoItem next, DateOnly localDate, bool canWrite, bool batchSelected)
        {
            if (!Equals(Item, next) || today != localDate || IsWritable != canWrite)
            {
                Item = next;
                today = localDate;
                IsWritable = canWrite;
                // 빈 이름 = 모든 속성을 다시 읽는다.
                Raise(string.Empty);
            }
            IsBatchSelected = batchSelected;
        }

        private void Set(ref bool field, bool value, string name)
        {
            if (field != value)
            {
                field = value;
                Raise(name);
            }
        }

        private void Raise(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }

    private sealed class LmsEditorRow(LmsRow row, DateOnly today, bool canToggle)
    {
        public LmsRow Row { get; } = row;
        public bool CanToggle { get; } = canToggle;
        public bool IsOverdue => !Row.IsDone && Row.Item.DueDate < today;
        public string CompletionLabel => $"{Row.Item.Title}, 과제 완료 체크";
        public string CourseLabel => Row.Item.CourseName is { } name ? LmsDisplay.ShortCourseName(name) : "";
        public bool HasCourse => CourseLabel.Length > 0;

        public string DueLabel => ShortDate(Row.Item.DueDate) + " · " + (Row.Item.DueDate.DayNumber - today.DayNumber) switch
        {
            0 => "D-Day",
            -1 when !Row.IsDone => "어제 마감",
            > 0 and var days => $"D-{days}",
            var days => $"D+{-days}",
        };
    }
}
