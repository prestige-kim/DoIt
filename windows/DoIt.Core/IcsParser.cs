using System.Buffers;
using System.Globalization;
using System.Text;

namespace DoIt.Core;

public sealed record IcsParseResult(IReadOnlyList<LmsItem> Items, int SkippedNonAssignment, int SkippedBroken);

public static class IcsParser
{
    private static readonly UTF8Encoding Utf8 = new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);

    public static IcsParseResult Parse(ReadOnlySpan<byte> data, TimeZoneInfo? localZone = null)
    {
        localZone ??= TimeZoneInfo.Local;
        if (data.StartsWith(new ReadOnlySpan<byte>([0xEF, 0xBB, 0xBF])))
        {
            data = data[3..];
        }

        var components = new Stack<ComponentFrame>();
        var items = new List<LmsItem>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var current = new EventFields();
        bool completedCalendar = false;
        int skippedNonAssignment = 0;
        int skippedBroken = 0;

        while (!data.IsEmpty)
        {
            var line = ReadPhysicalLine(ref data);
            if (line.IsEmpty || IsFoldingSpace(line[0]))
            {
                continue;
            }

            int separator = line.IndexOfAny((byte)':', (byte)';');
            var name = separator < 0 ? line : line[..separator];
            var property = ClassifyProperty(name);
            bool inAssignmentComponent = components.Count == 2 && components.Peek().Kind == Component.Event;
            bool keep = property is Property.Begin or Property.End || inAssignmentComponent && property != Property.Other;
            if (!keep)
            {
                if (inAssignmentComponent && !IsPropertyName(name))
                {
                    current.Broken = true;
                }
                SkipFoldedLines(ref data);
                continue;
            }

            ArrayBufferWriter<byte>? unfolded = null;
            while (!data.IsEmpty && IsFoldingSpace(data[0]))
            {
                if (unfolded is null)
                {
                    unfolded = new ArrayBufferWriter<byte>(line.Length);
                    unfolded.Write(line);
                }
                unfolded.Write(ReadPhysicalLine(ref data)[1..]);
            }

            var logical = unfolded is null ? line : unfolded.WrittenSpan;
            int colon = FindUnquoted(logical, (byte)':');
            if (colon < 0)
            {
                if (property is Property.Begin or Property.End)
                {
                    throw InvalidCalendar();
                }
                current.Broken = true;
                continue;
            }

            var value = logical[(colon + 1)..];
            switch (property)
            {
                case Property.Begin:
                {
                    var component = ReadComponent(value);
                    if ((components.Count == 0) != (component.Kind == Component.Calendar) || completedCalendar)
                    {
                        throw InvalidCalendar();
                    }
                    if (component.Kind == Component.Event && components.Count == 1)
                    {
                        current = new EventFields();
                    }
                    components.Push(component);
                    break;
                }
                case Property.End:
                {
                    var component = ReadComponent(value);
                    if (!components.TryPop(out var opened) || opened != component)
                    {
                        throw InvalidCalendar();
                    }
                    if (component.Kind == Component.Event && components.Count == 1)
                    {
                        Finish(current, items, seen, ref skippedNonAssignment, ref skippedBroken);
                    }
                    if (component.Kind == Component.Calendar)
                    {
                        completedCalendar = true;
                    }
                    break;
                }
                case Property.Uid:
                    current.Uid = Unescape(Decode(value)).Trim();
                    break;
                case Property.Summary:
                    current.Summary = Unescape(Decode(value));
                    break;
                case Property.Start:
                    current.HasStart = true;
                    current.Start = ParseDate(logical[..colon], value, localZone);
                    break;
                case Property.EndDate:
                    current.End = ParseDate(logical[..colon], value, localZone);
                    break;
            }
        }

        if (!completedCalendar || components.Count != 0)
        {
            throw InvalidCalendar();
        }
        return new IcsParseResult(items.AsReadOnly(), skippedNonAssignment, skippedBroken);
    }

    private static void Finish(EventFields fields, List<LmsItem> items,
        HashSet<string> seen, ref int skippedNonAssignment, ref int skippedBroken)
    {
        if (string.IsNullOrEmpty(fields.Uid))
        {
            skippedBroken++;
            return;
        }
        if (!fields.Uid.StartsWith("event-assignment-", StringComparison.Ordinal))
        {
            skippedNonAssignment++;
            return;
        }
        var due = fields.HasStart ? fields.Start : fields.End;
        if (fields.Broken || fields.Summary is null || due is null || seen.Contains(fields.Uid))
        {
            skippedBroken++;
            return;
        }
        var (title, course) = SplitSummary(fields.Summary);
        if (title.Length == 0)
        {
            skippedBroken++;
            return;
        }
        seen.Add(fields.Uid);
        items.Add(new LmsItem(fields.Uid, title, course, due.Value.Date, due.Value.Time));
    }

    private static (DateOnly Date, TimeOnly? Time)? ParseDate(ReadOnlySpan<byte> head, ReadOnlySpan<byte> bytes, TimeZoneInfo localZone)
    {
        string value = Decode(bytes).Trim();
        if (value.Length < 8 || !DateOnly.TryParseExact(value.AsSpan(0, 8), "yyyyMMdd", CultureInfo.InvariantCulture,
                DateTimeStyles.None, out var date))
        {
            return null;
        }

        bool dateOnly = false;
        ReadOnlySpan<byte> zoneName = default;
        int parameterStart = head.IndexOf((byte)';');
        while (parameterStart >= 0)
        {
            head = head[(parameterStart + 1)..];
            parameterStart = FindUnquoted(head, (byte)';');
            var parameter = parameterStart < 0 ? head : head[..parameterStart];
            int equals = parameter.IndexOf((byte)'=');
            if (equals <= 0)
            {
                continue;
            }
            var name = parameter[..equals];
            var content = parameter[(equals + 1)..];
            if (content.Length >= 2 && content[0] == '"' && content[^1] == '"')
            {
                content = content[1..^1];
            }
            if (Ascii.EqualsIgnoreCase(name, "VALUE"u8))
            {
                dateOnly = Ascii.EqualsIgnoreCase(content, "DATE"u8);
            }
            if (Ascii.EqualsIgnoreCase(name, "TZID"u8))
            {
                zoneName = content;
            }
        }

        if (dateOnly || value.Length == 8)
        {
            return (date, null);
        }
        bool utc = value.Length == 16 && value[^1] is 'Z' or 'z';
        if ((value.Length != 15 && !utc) || value[8] is not ('T' or 't')
            || !int.TryParse(value.AsSpan(9, 2), NumberStyles.None, CultureInfo.InvariantCulture, out int hours)
            || !int.TryParse(value.AsSpan(11, 2), NumberStyles.None, CultureInfo.InvariantCulture, out int minutes)
            || !int.TryParse(value.AsSpan(13, 2), NumberStyles.None, CultureInfo.InvariantCulture, out int seconds)
            || hours > 23 || minutes > 59 || seconds > 60)
        {
            return null;
        }

        TimeZoneInfo sourceZone = utc ? TimeZoneInfo.Utc : localZone;
        if (!utc && !zoneName.IsEmpty && !TimeZoneInfo.TryFindSystemTimeZoneById(Decode(zoneName), out sourceZone!))
        {
            return null;
        }

        try
        {
            var source = date.ToDateTime(new TimeOnly(hours, minutes)).AddSeconds(seconds);
            if (source.Day != date.Day || sourceZone.IsInvalidTime(source))
            {
                return null;
            }
            var local = TimeZoneInfo.ConvertTime(source, sourceZone, localZone);
            return (DateOnly.FromDateTime(local), new TimeOnly(local.Hour, local.Minute));
        }
        catch (ArgumentOutOfRangeException)
        {
            return null;
        }
    }

    private static (string Title, string? Course) SplitSummary(string summary)
    {
        string trimmed = summary.Trim();
        if (!trimmed.EndsWith(']'))
        {
            return (OneLine(trimmed), null);
        }
        int depth = 0;
        for (int index = trimmed.Length - 1; index >= 0; index--)
        {
            if (trimmed[index] == ']')
            {
                depth++;
            }
            if (trimmed[index] == '[' && --depth == 0)
            {
                string title = trimmed[..index].Trim();
                string course = trimmed[(index + 1)..^1].Trim();
                if (title.Length > 0)
                {
                    return (OneLine(title), course.Length == 0 ? null : OneLine(course));
                }
                break;
            }
        }
        return (OneLine(trimmed), null);
    }

    private static string OneLine(string value) => value.Replace('\r', ' ').Replace('\n', ' ');

    private static string Unescape(string value)
    {
        if (!value.Contains('\\'))
        {
            return value;
        }
        var text = new StringBuilder(value.Length);
        for (int index = 0; index < value.Length; index++)
        {
            if (value[index] == '\\' && index + 1 < value.Length)
            {
                char next = value[index + 1];
                if (next is 'n' or 'N' or '\\' or ';' or ',')
                {
                    text.Append(next is 'n' or 'N' ? '\n' : next);
                    index++;
                    continue;
                }
            }
            text.Append(value[index]);
        }
        return text.ToString();
    }

    private static ReadOnlySpan<byte> ReadPhysicalLine(ref ReadOnlySpan<byte> input)
    {
        int end = input.IndexOfAny((byte)'\r', (byte)'\n');
        if (end < 0)
        {
            var last = input;
            input = default;
            return last;
        }

        var line = input[..end];
        int lineBreak = input[end] == '\r' && end + 1 < input.Length && input[end + 1] == '\n' ? 2 : 1;
        input = input[(end + lineBreak)..];
        return line;
    }

    private static void SkipFoldedLines(ref ReadOnlySpan<byte> input)
    {
        while (!input.IsEmpty && IsFoldingSpace(input[0]))
        {
            ReadPhysicalLine(ref input);
        }
    }

    private static bool IsFoldingSpace(byte value) => value is (byte)' ' or (byte)'\t';

    private static int FindUnquoted(ReadOnlySpan<byte> input, byte delimiter)
    {
        bool quoted = false;
        for (int index = 0; index < input.Length; index++)
        {
            if (input[index] == '"')
            {
                quoted = !quoted;
            }
            else if (input[index] == delimiter && !quoted)
            {
                return index;
            }
        }
        return -1;
    }

    private static bool IsPropertyName(ReadOnlySpan<byte> name)
    {
        foreach (byte ch in name)
        {
            if (ch is not (>= (byte)'A' and <= (byte)'Z' or >= (byte)'a' and <= (byte)'z'
                or >= (byte)'0' and <= (byte)'9' or (byte)'-'))
            {
                return false;
            }
        }
        return !name.IsEmpty;
    }

    private static Property ClassifyProperty(ReadOnlySpan<byte> name)
    {
        if (Ascii.EqualsIgnoreCase(name, "BEGIN"u8)) return Property.Begin;
        if (Ascii.EqualsIgnoreCase(name, "END"u8)) return Property.End;
        if (Ascii.EqualsIgnoreCase(name, "UID"u8)) return Property.Uid;
        if (Ascii.EqualsIgnoreCase(name, "SUMMARY"u8)) return Property.Summary;
        if (Ascii.EqualsIgnoreCase(name, "DTSTART"u8)) return Property.Start;
        if (Ascii.EqualsIgnoreCase(name, "DTEND"u8)) return Property.EndDate;
        return Property.Other;
    }

    private static ComponentFrame ReadComponent(ReadOnlySpan<byte> name)
    {
        if (!IsPropertyName(name))
        {
            throw InvalidCalendar();
        }

        if (Ascii.EqualsIgnoreCase(name, "VCALENDAR"u8)) return new(Component.Calendar, "VCALENDAR");
        if (Ascii.EqualsIgnoreCase(name, "VEVENT"u8)) return new(Component.Event, "VEVENT");
        return new(Component.Other, Encoding.ASCII.GetString(name).ToUpperInvariant());
    }

    private static string Decode(ReadOnlySpan<byte> text)
    {
        try
        {
            return Utf8.GetString(text);
        }
        catch (DecoderFallbackException)
        {
            throw InvalidCalendar();
        }
    }

    private static FormatException InvalidCalendar() => new("유효한 캘린더 형식이 아닙니다.");

    private enum Property { Other, Begin, End, Uid, Summary, Start, EndDate }
    private enum Component { Other, Calendar, Event }
    private readonly record struct ComponentFrame(Component Kind, string Name);

    private struct EventFields
    {
        internal string? Uid;
        internal string? Summary;
        internal bool HasStart;
        internal (DateOnly Date, TimeOnly? Time)? Start;
        internal (DateOnly Date, TimeOnly? Time)? End;
        internal bool Broken;
    }
}
