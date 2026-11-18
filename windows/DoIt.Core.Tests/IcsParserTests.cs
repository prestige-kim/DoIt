using System.Text;
using System.Text.Json;
using DoIt.Core;

internal static class IcsParserTests
{
    private static readonly TimeZoneInfo Seoul = TimeZoneInfo.CreateCustomTimeZone("Test Seoul", TimeSpan.FromHours(9), "Test Seoul", "Test Seoul");

    internal static (string Name, Action Run)[] Cases =>
    [
        ("ICS keeps unique assignment events and reports malformed and non-assignment counts", SelectEvents),
        ("ICS converts UTC and TZID due times to the local date", TimeZones),
        ("ICS accepts floating, DATE, and DATE values with extra time", DateValues),
        ("ICS uses DTEND only when DTSTART is absent", EndDateFallback),
        ("ICS rejects invalid dates, times and unknown timezones per event", InvalidEvents),
        ("ICS unfolds bytes including splits inside a Korean UTF-8 character", FoldedBytes),
        ("ICS decodes escapes and splits balanced trailing brackets", TitlesAndCourses),
        ("ICS skips forbidden and nested values without decoding them", AllowedFieldsOnly),
        ("ICS rejects incomplete or invalid calendar responses with a generic error", MalformedCalendar),
        ("LMS short course display and due label preserve original item fields", Display),
    ];

    private static void SelectEvents()
    {
        var result = Parse(Event(1, "SUMMARY:가짜 과제\nDTSTART:20261112")
            + Event(1, "SUMMARY:중복\nDTSTART:20261113")
            + "BEGIN:VEVENT\nUID:other-event\nSUMMARY:가짜 비과제\nDTSTART:20261112\nEND:VEVENT\n"
            + "BEGIN:VEVENT\nSUMMARY:UID 없음\nDTSTART:20261112\nEND:VEVENT\n");
        Equal("가짜 과제", result.Items.Single().Title);
        Equal(1, result.SkippedNonAssignment);
        Equal(2, result.SkippedBroken);
    }

    private static void TimeZones()
    {
        var result = Parse(Event(1, "SUMMARY:UTC\nDTSTART:20261231T235900Z")
            + Event(2, "SUMMARY:시간대\ndtstart;TZID=\"Asia/Tokyo\":20261112T111300"));
        Equal(new DateOnly(2027, 1, 1), result.Items[0].DueDate);
        Equal<TimeOnly?>(new TimeOnly(8, 59), result.Items[0].DueTime);
        Equal<TimeOnly?>(new TimeOnly(11, 13), result.Items[1].DueTime);
    }

    private static void DateValues()
    {
        var result = Parse(Event(1, "SUMMARY:종일\nDTSTART;VALUE=DATE:20261009T000000")
            + Event(2, "SUMMARY:시각\nDTSTART:20261009T235900")
            + Event(3, "SUMMARY:날짜\nDTSTART:20261009"));
        Equal(new DateOnly(2026, 10, 9), result.Items[0].DueDate);
        Equal<TimeOnly?>(null, result.Items[0].DueTime);
        Equal<TimeOnly?>(new TimeOnly(23, 59), result.Items[1].DueTime);
        Equal<TimeOnly?>(null, result.Items[2].DueTime);
    }

    private static void EndDateFallback()
    {
        var result = Parse(Event(1, "SUMMARY:끝 날짜\nDTEND:20261115")
            + Event(2, "SUMMARY:시작 날짜\nDTSTART:20261112\nDTEND:20261115")
            + Event(3, "SUMMARY:깨진 시작\nDTSTART:20261301\nDTEND:20261115"));
        Equal(new DateOnly(2026, 11, 15), result.Items[0].DueDate);
        Equal(new DateOnly(2026, 11, 12), result.Items[1].DueDate);
        Equal(1, result.SkippedBroken);
    }

    private static void InvalidEvents()
    {
        var result = Parse(Event(1, "SUMMARY:없는 날\nDTSTART;VALUE=DATE:20260230")
            + Event(2, "SUMMARY:없는 시각\nDTSTART:20261009T256000Z")
            + Event(3, "SUMMARY:없는 시간대\nDTSTART;TZID=Nowhere/Unknown:20261009T100000")
            + Event(4, "SUMMARY:깨진 줄\n이상한 줄\nDTSTART:20261112"));
        Equal(0, result.Items.Count);
        Equal(4, result.SkippedBroken);
    }

    private static void FoldedBytes()
    {
        byte[] first = Encoding.UTF8.GetBytes("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:event-assignment-1\r\nDTSTART:20261112\r\nSUMMARY:");
        byte[] korean = Encoding.UTF8.GetBytes("가짜");
        byte[] suffix = Encoding.UTF8.GetBytes("\n\t 과제 [과\n 목]\nEND:VEVENT\nEND:VCALENDAR\n");
        byte[] bytes = [0xef, 0xbb, 0xbf, .. first, korean[0], (byte)'\r', (byte)'\n', (byte)' ', .. korean[1..], .. suffix];
        var item = IcsParser.Parse(bytes, Seoul).Items.Single();
        Equal("가짜 과제", item.Title);
        Equal("과목", item.CourseName);
    }

    private static void TitlesAndCourses()
    {
        var result = Parse(Event(1, "SUMMARY:보고서\\, 초안\\; 최종 \\\\ 제출\\n오늘 [과목 [실습] 02분반]\nDTSTART:20261112")
            + Event(2, "SUMMARY:[과목만]\nDTSTART:20261112")
            + Event(3, "SUMMARY:과제 [과목] 뒤 문구\nDTSTART:20261112"));
        Equal("보고서, 초안; 최종 \\ 제출 오늘", result.Items[0].Title);
        Equal("과목 [실습] 02분반", result.Items[0].CourseName);
        Equal("[과목만]", result.Items[1].Title);
        Equal<string?>(null, result.Items[2].CourseName);
    }

    private static void AllowedFieldsOnly()
    {
        var raw = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:event-assignment-1\nSUMMARY:가짜 과제\nDTSTART:20261112\nDESCRIPTION:"u8;
        var rest = "\n SYNTHETIC-DESCRIPTION\nATTACH:SYNTHETIC-ATTACH\nURL:SYNTHETIC-URL\nBEGIN:VALARM\nSUMMARY:SYNTHETIC-NESTED\nEND:VALARM\nEND:VEVENT\nEND:VCALENDAR\n"u8;
        byte[] bytes = [.. raw, 0xff, 0xfe, .. rest];
        var result = IcsParser.Parse(bytes, Seoul);
        Equal("가짜 과제", result.Items.Single().Title);
        Equal(false, JsonSerializer.Serialize(result).Contains("SYNTHETIC", StringComparison.Ordinal));
    }

    private static void MalformedCalendar()
    {
        Equal(0, Parse("").Items.Count);
        Reject("<html>synthetic</html>"u8);
        Reject("BEGIN:VCALENDAR\nBEGIN:VEVENT\nEND:VCALENDAR"u8);
        Reject("BEGIN:VCALENDAR\nBEGIN:VALARM\nEND:VTIMEZONE\nEND:VCALENDAR"u8);
        byte[] invalidAcceptedField = [.. "BEGIN:VCALENDAR\nBEGIN:VEVENT\nSUMMARY:"u8, 0xff, .. "\nEND:VEVENT\nEND:VCALENDAR"u8];
        Reject(invalidAcceptedField);
    }

    private static void Display()
    {
        var item = new LmsItem("event-assignment-1", "가짜 과제", "컴퓨터구조(Computer Architecture) 02분반", new DateOnly(2026, 11, 12), new TimeOnly(23, 59));
        Equal("컴퓨터구조 02분반", LmsDisplay.ShortCourseName(item.CourseName!));
        Equal("컴퓨터구조(실습 Lab)", LmsDisplay.ShortCourseName("컴퓨터구조(실습 Lab)"));
        Equal("D-Day 23:59", item.DueLabel(new DateOnly(2026, 11, 12)));
        Equal(1, LmsDisplay.ClampWeeks(0));
        Equal(8, LmsDisplay.ClampWeeks(10));
    }

    private static IcsParseResult Parse(string events) =>
        IcsParser.Parse(Encoding.UTF8.GetBytes($"BEGIN:VCALENDAR\n{events}END:VCALENDAR\n"), Seoul);

    private static string Event(int id, string properties) => $"BEGIN:VEVENT\nUID:event-assignment-{id}\n{properties}\nEND:VEVENT\n";

    private static void Reject(ReadOnlySpan<byte> data)
    {
        try
        {
            IcsParser.Parse(data, Seoul);
        }
        catch (FormatException error)
        {
            Equal("유효한 캘린더 형식이 아닙니다.", error.Message);
            return;
        }
        throw new InvalidOperationException("Expected a format error.");
    }

    private static void Equal<T>(T expected, T actual)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
        {
            throw new InvalidOperationException($"Expected {expected}, got {actual}.");
        }
    }
}
