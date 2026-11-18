using System.Text.Json.Serialization;

namespace DoIt.Core;

public sealed record TodoItem(
    [property: JsonRequired] Guid Id,
    [property: JsonRequired] string Title,
    [property: JsonRequired] DateOnly DueDate,
    [property: JsonRequired] DateTimeOffset CreatedAt,
    [property: JsonRequired] DateTimeOffset UpdatedAt,
    [property: JsonRequired] bool IsDone,
    DateTimeOffset? DoneAt)
{
    public string DayLabel(DateOnly today)
    {
        int days = DueDate.DayNumber - today.DayNumber;
        return days switch
        {
            0 => "D-Day",
            > 0 => $"D-{days}",
            _ => $"D+{-days}",
        };
    }
}
