using System.Globalization;
using System.Text.Json.Serialization;

namespace DoIt.Core;

public sealed record LmsItem(
    [property: JsonRequired] string Uid,
    [property: JsonRequired] string Title,
    string? CourseName,
    [property: JsonRequired] DateOnly DueDate,
    TimeOnly? DueTime)
{
    public string DueLabel(DateOnly today)
    {
        int days = DueDate.DayNumber - today.DayNumber;
        var label = days switch
        {
            0 => "D-Day",
            > 0 => $"D-{days}",
            _ => $"D+{-days}",
        };
        return DueTime is { } time ? $"{label} {time.ToString("HH:mm", CultureInfo.InvariantCulture)}" : label;
    }
}
