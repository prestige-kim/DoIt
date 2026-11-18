using System.Globalization;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using DoIt.Core;

namespace DoIt.Windows;

public partial class LmsSection : UserControl
{
    private LmsService? lms;

    public LmsSection() => InitializeComponent();

    internal event Action? LayoutChanged;

    internal void Refresh(LmsService service, DateOnly today, DateOnly? selectedDate = null, string search = "")
    {
        lms = service;
        var snapshot = service.Snapshot;
        IReadOnlyList<LmsRow> rows = snapshot.Enabled
            ? selectedDate is { } day ? service.ForDate(day) : service.Visible(today)
            : [];
        var query = search.Trim().Normalize(NormalizationForm.FormC);
        if (query.Length > 0)
        {
            rows = rows.Where(row => row.Item.Title.Normalize(NormalizationForm.FormC)
                .Contains(query, StringComparison.OrdinalIgnoreCase)).ToArray();
        }
        var status = snapshot.Enabled && selectedDate is null && (snapshot.IsSyncing || snapshot.Status is not (LmsSyncStatus.Ok or LmsSyncStatus.Never))
            ? StatusLabel(snapshot) : string.Empty;
        HeadingText.Text = $"LMS 과제 · {rows.Count}개";
        SyncStatus.Text = status;
        SyncStatus.Visibility = status.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        bool canToggle = snapshot is { Enabled: true, HasFeedAddress: true, DisconnectPending: false }
            && (selectedDate is null || selectedDate >= today);
        Rows.ItemsSource = rows.Select(row => new DisplayRow(row, today, canToggle)).ToArray();
        Visibility = rows.Count == 0 && status.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        if (Visibility == Visibility.Collapsed)
        {
            CheckError.Visibility = Visibility.Collapsed;
        }
    }

    internal static string StatusLabel(LmsSnapshot snapshot) => snapshot switch
    {
        { DisconnectPending: true } => "피드 주소 삭제를 완료하지 못했습니다. 새 요청은 중지했습니다.",
        { IsSyncing: true } => "LMS 과제를 새로 고치는 중입니다.",
        { Status: LmsSyncStatus.StorageError } => "LMS 정보를 저장하지 못했습니다. 다시 시도해 주세요.",
        { Enabled: false } => "LMS 연동이 꺼져 있습니다.",
        { Status: LmsSyncStatus.Disconnected } => "연결이 끊겼어요. 설정에서 피드 주소를 확인해 주세요.",
        { Status: LmsSyncStatus.Offline } => "지금 LMS에 연결할 수 없어 마지막 목록을 표시합니다.",
        { Status: LmsSyncStatus.InvalidFeed } => "캘린더 피드를 읽지 못했습니다. 마지막 목록은 유지합니다.",
        { Status: LmsSyncStatus.RateLimited } => "LMS 요청 제한으로 새로고침을 잠시 쉬고 있습니다.",
        { Status: LmsSyncStatus.Ok } => "LMS 과제를 새로 고쳤습니다.",
        _ => "아직 새로고침한 적이 없습니다.",
    };

    private void OnExpansion(object sender, RoutedEventArgs e) => LayoutChanged?.Invoke();

    private void ToggleDone(object sender, RoutedEventArgs e)
    {
        if (sender is CheckBox { DataContext: DisplayRow row } checkbox && lms is { } service && row.CanToggle)
        {
            // WPF changes the visual state first. A failed save leaves the model untouched.
            bool saved = service.ToggleDone(row.Row.Item.Uid);
            if (!saved)
            {
                checkbox.SetCurrentValue(CheckBox.IsCheckedProperty, row.Row.IsDone);
            }
            CheckError.Visibility = saved ? Visibility.Collapsed : Visibility.Visible;
            LayoutChanged?.Invoke();
        }
    }

    private sealed class DisplayRow(LmsRow row, DateOnly today, bool canToggle)
    {
        public LmsRow Row { get; } = row;
        public bool CanToggle { get; } = canToggle;
        public bool IsOverdue => !Row.IsDone && Row.Item.DueDate < today;
        public string CompletionLabel => $"{Row.Item.Title}, 과제 완료 체크";
        public string DateLabel => Row.Item.DueDate.ToString("M/d(ddd)", CultureInfo.GetCultureInfo("ko-KR"))
            + (Row.Item.DueTime is { } time ? " " + time.ToString("HH:mm", CultureInfo.InvariantCulture) : "");

        public string DayLabel => (Row.Item.DueDate.DayNumber - today.DayNumber) switch
        {
            0 => "D-Day",
            -1 when !Row.IsDone => "어제 마감",
            > 0 and var days => $"D-{days}",
            var days => $"D+{-days}",
        };

        public string CourseLabel => Row.Item.CourseName is { } name ? LmsDisplay.ShortCourseName(name) : "";
    }
}
