using System;
using System.Globalization;
using System.Text;
using UdonSharp;
using UnityEngine;

namespace Coverage
{
    /// Overloads that `udon2godot --coverage-overloads` found unmapped: the member name had a
    /// mapping, so calls silently used another overload (hex parsed as decimal, a comparison
    /// argument ignored, a format provider taken for the format string).
    public class TOverloads : UdonSharpBehaviour
    {
        public string[] failures = new string[64];
        public int failCount;
        public int total;
        public bool done;

        private void Check(bool ok, string what)
        {
            total++;
            if (!ok) { failures[failCount] = what; failCount++; }
        }

        public void RunTests()
        {
            // styled numeric parsing
            Check(byte.Parse("FF", NumberStyles.HexNumber) == 255 && int.Parse("1A", NumberStyles.HexNumber) == 26, "hex Parse: " + byte.Parse("FF", NumberStyles.HexNumber));
            Check(int.Parse("1,234", NumberStyles.AllowThousands) == 1234 && int.Parse("42", CultureInfo.InvariantCulture) == 42, "Parse with thousands / provider");
            int v;
            Check(int.TryParse("7f", NumberStyles.HexNumber, CultureInfo.InvariantCulture, out v) && v == 127, "TryParse hex: " + v);
            Check(!int.TryParse("zz", NumberStyles.HexNumber, CultureInfo.InvariantCulture, out v), "TryParse hex rejects non-hex");
            float f = float.Parse("1,234.5", NumberStyles.Float | NumberStyles.AllowThousands, CultureInfo.InvariantCulture);
            Check(Mathf.Abs(f - 1234.5f) < 0.01f, "float.Parse with styles: " + f);
            double d;
            Check(double.TryParse("2.5", NumberStyles.Float, CultureInfo.InvariantCulture, out d) && Math.Abs(d - 2.5) < 0.0001, "double.TryParse with styles");
            Check(Convert.ToInt32("17", CultureInfo.InvariantCulture) == 17 && Convert.ToByte("ff", 16) == 255 && Convert.ToInt64("101", 2) == 5, "Convert with provider / base");
            Check(((uint)7).ToString("D3", CultureInfo.InvariantCulture) == "007" && ((long)5).ToString(CultureInfo.InvariantCulture) == "5", "ToString(format, provider)");

            // strings: ranges and comparisons
            string s = "Hello, World, Hello";
            Check(s.IndexOf('o', 5, 5) == 8 && s.IndexOf('o', 5, 3) == -1 && s.IndexOf("Hello", 1, 18) == 14, "IndexOf(value, start, count)");
            Check(s.IndexOf("hello", StringComparison.OrdinalIgnoreCase) == 0 && s.IndexOf("hello", 1, StringComparison.OrdinalIgnoreCase) == 14 && s.IndexOf("hello", StringComparison.Ordinal) == -1, "IndexOf with comparison");
            Check(s.LastIndexOf('o', 10) == 8 && s.LastIndexOf("Hello", 13) == 0 && s.LastIndexOf('o', 10, 2) == -1 && s.LastIndexOf("HELLO", StringComparison.OrdinalIgnoreCase) == 14, "LastIndexOf(value, start[, count]) / comparison");
            Check(s.StartsWith("hello", StringComparison.OrdinalIgnoreCase) && !s.StartsWith("hello", StringComparison.Ordinal) && s.EndsWith("HELLO", StringComparison.OrdinalIgnoreCase) && !s.EndsWith("HELLO", StringComparison.Ordinal), "StartsWith / EndsWith with comparison");
            Check(s.StartsWith('H') && s.EndsWith('o') && s.Contains("WORLD", StringComparison.OrdinalIgnoreCase) && !s.Contains("WORLD", StringComparison.Ordinal), "char forms and Contains with comparison");
            Check(s.Replace("hello", "Bye", StringComparison.OrdinalIgnoreCase) == "Bye, World, Bye", "Replace with comparison: " + s.Replace("hello", "Bye", StringComparison.OrdinalIgnoreCase));
            Check(string.Compare("abc", "ABC", StringComparison.OrdinalIgnoreCase) == 0 && string.Compare("abc", "ABC", StringComparison.Ordinal) != 0, "Compare with comparison");
            Check(string.Compare("xxabc", 2, "yyABC", 2, 3, true) == 0 && string.Compare("xxabc", 2, "yyabd", 2, 3) < 0, "Compare ranges");
            Check(string.Equals("a", "A", StringComparison.OrdinalIgnoreCase) && !string.Equals("a", "A", StringComparison.Ordinal), "static Equals with comparison");
            Check(string.Format(CultureInfo.InvariantCulture, "{0}-{1}", 1, "x") == "1-x", "Format with a provider: " + string.Format(CultureInfo.InvariantCulture, "{0}-{1}", 1, "x"));
            char[] mid = s.ToCharArray(7, 5);
            Check(mid.Length == 5 && mid[0] == 'W' && mid[4] == 'd', "ToCharArray(start, length)");
            Check(char.IsDigit("a1", 1) && !char.IsDigit("a1", 0) && char.IsUpper("aB", 1) && char.IsWhiteSpace("a b", 1), "char.IsX(string, index)");

            // custom date and time formats (a player list prints "dd MMMM yyyy hh:mm:ss")
            DateTime when = new DateTime(2026, 9, 17, 15, 4, 5);
            Check(when.ToString("dd MMMM yyyy hh:mm:ss tt") == "17 September 2026 03:04:05 PM", "DateTime custom format with month name and 12-hour clock: " + when.ToString("dd MMMM yyyy hh:mm:ss tt"));
            Check(when.ToString("ddd, d MMM yy 'at' H:mm") == "Thu, 17 Sep 26 at 15:04" && when.ToString("dddd") == "Thursday", "short names, quoted literal: " + when.ToString("ddd, d MMM yy 'at' H:mm"));
            Check(new DateTime(2024, 2, 29).ToString("dddd yyyy-MM-dd") == "Thursday 2024-02-29" && when.ToString("s") == "2026-09-17T15:04:05", "day of week in a leap year, sortable format");
            TimeSpan span = TimeSpan.FromSeconds(3725.5);
            Check(span.ToString(@"hh\:mm\:ss") == "01:02:05" && span.ToString(@"m\:ss\.f") == "2:05.5" && TimeSpan.FromSeconds(90000).ToString(@"d\.hh\:mm") == "1.01:00", "TimeSpan custom formats: " + span.ToString(@"hh\:mm\:ss"));

            // StringBuilder
            var sb = new StringBuilder("ab");
            sb.AppendFormat(CultureInfo.InvariantCulture, "{0}{1}", 1, 2);
            sb.Insert(0, "xy", 2);
            Check(sb.ToString() == "xyxyab12", "StringBuilder AppendFormat(provider) / Insert(count): " + sb.ToString());

            // arrays
            int[] sorted = new int[] { 1, 3, 5, 7, 9, 11 };
            Check(Array.BinarySearch(sorted, 7) == 3 && Array.BinarySearch(sorted, 4) == ~2, "BinarySearch returns the complement when missing: " + Array.BinarySearch(sorted, 4));
            Check(Array.BinarySearch(sorted, 2, 3, 9) == 4 && Array.BinarySearch(sorted, 2, 3, 1) < 0, "BinarySearch in a range");
            int[] rep = new int[] { 4, 2, 4, 2, 4 };
            Check(Array.LastIndexOf(rep, 4, 3, 2) == 2 && Array.LastIndexOf(rep, 4, 3, 1) == -1, "LastIndexOf(array, value, start, count)");

            // vectors and colours
            Vector3 n = new Vector3(0f, 2f, 0f);
            Vector3 t = new Vector3(1f, 1f, 0f);
            Vector3 b = new Vector3(1f, 1f, 1f);
            Vector3.OrthoNormalize(ref n, ref t, ref b);
            Check(Mathf.Abs(n.magnitude - 1f) < 0.001f && Mathf.Abs(Vector3.Dot(n, t)) < 0.001f && Mathf.Abs(Vector3.Dot(n, b)) < 0.001f && Mathf.Abs(Vector3.Dot(t, b)) < 0.001f && Mathf.Abs(b.magnitude - 1f) < 0.001f, "OrthoNormalize with three vectors");
            Check(new Color(1f, 0.5f, 0f, 1f).ToString("F1") == "RGBA(1.0, 0.5, 0.0, 1.0)", "Color.ToString(format): " + new Color(1f, 0.5f, 0f, 1f).ToString("F1"));
            Bounds bounds = new Bounds(Vector3.zero, Vector3.one);
            bounds.Expand(new Vector3(1f, 3f, 0f));
            Check(Mathf.Abs(bounds.size.x - 2f) < 0.001f && Mathf.Abs(bounds.size.y - 4f) < 0.001f && Mathf.Abs(bounds.size.z - 1f) < 0.001f && bounds.center.magnitude < 0.001f, "Bounds.Expand(Vector3): " + bounds.size);
            Rect inverse = new Rect(2f, 2f, -2f, -2f);
            Check(inverse.Contains(new Vector3(1f, 1f, 0f), true) && !inverse.Contains(new Vector3(1f, 1f, 0f), false), "Rect.Contains(point, allowInverse)");
            done = true;
        }
    }
}
