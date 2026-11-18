using System.Text;

namespace DoIt.Core;

public static class LmsDisplay
{
    public const int DefaultWeeks = 2;
    public const int MaxWeeks = 8;

    public static int ClampWeeks(int weeks) => Math.Clamp(weeks, 1, MaxWeeks);

    public static string ShortCourseName(string name)
    {
        var result = new StringBuilder(name.Length);
        for (int index = 0; index < name.Length; index++)
        {
            char value = name[index];
            if (value is '(' or '（')
            {
                int end = name.IndexOf(value == '(' ? ')' : '）', index + 1);
                if (end >= 0 && IsEnglish(name.AsSpan(index + 1, end - index - 1)))
                {
                    index = end;
                    continue;
                }
            }
            result.Append(value);
        }
        string collapsed = string.Join(' ', result.ToString().Split(' ', StringSplitOptions.RemoveEmptyEntries));
        return collapsed.Length == 0 ? name : collapsed;
    }

    private static bool IsEnglish(ReadOnlySpan<char> text)
    {
        bool containsLatin = false;
        foreach (char value in text)
        {
            if (value is >= '\uAC00' and <= '\uD7A3' or >= '\u3131' and <= '\u318E' or >= '\u1100' and <= '\u11FF')
            {
                return false;
            }
            containsLatin |= value is >= 'A' and <= 'Z' or >= 'a' and <= 'z';
        }
        return containsLatin;
    }
}
