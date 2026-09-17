using System;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using UdonSharp;
using UnityEngine;

namespace Coverage
{
    /// Strings, formatting, StringBuilder, Regex, char, Convert, DateTime/TimeSpan.
    public class TStrings : UdonSharpBehaviour
    {
        public string[] failures = new string[128];
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
            string s = "Hello, World";
            Check(s.Length == 12, "Length");
            Check(s.Substring(7) == "World" && s.Substring(0, 5) == "Hello", "Substring");
            Check(s.IndexOf("World") == 7 && s.IndexOf('o') == 4 && s.IndexOf("zzz") == -1, "IndexOf");
            Check(s.LastIndexOf('o') == 8, "LastIndexOf");
            Check(s.Contains("lo, W") && !s.Contains("hello"), "Contains is case-sensitive");
            Check(s.StartsWith("Hell") && s.EndsWith("rld"), "StartsWith/EndsWith");
            Check(s.Replace("World", "Udon") == "Hello, Udon", "Replace");
            Check(s.ToUpper() == "HELLO, WORLD" && s.ToLower() == "hello, world", "ToUpper/ToLower");
            Check("  pad ".Trim() == "pad" && "  pad ".TrimStart() == "pad " && "  pad ".TrimEnd() == "  pad", "Trim family");
            string[] parts = "a,b,,c".Split(',');
            Check(parts.Length == 4 && parts[0] == "a" && parts[2] == "" && parts[3] == "c", "Split(char) keeps empties");
            string[] parts2 = "a;b c".Split(new char[] { ';', ' ' });
            Check(parts2.Length == 3 && parts2[1] == "b", "Split(char[])");
            Check(string.Join("-", new string[] { "x", "y", "z" }) == "x-y-z", "Join");
            Check("abc".PadLeft(5) == "  abc" && "abc".PadRight(5, '.') == "abc..", "PadLeft/PadRight");
            Check("abc".Insert(1, "Z") == "aZbc" && "abcdef".Remove(3) == "abc" && "abcdef".Remove(1, 2) == "adef", "Insert/Remove");
            Check(string.IsNullOrEmpty("") && !string.IsNullOrEmpty("x"), "IsNullOrEmpty");
            Check(string.IsNullOrWhiteSpace("   "), "IsNullOrWhiteSpace");
            Check(s[0] == 'H' && s[4] == 'o', "indexer returns char");
            char[] chars = "hey".ToCharArray();
            Check(chars.Length == 3 && chars[1] == 'e', "ToCharArray");
            Check("a" + 1 + 2.5f + true == "a12.5True", "concatenation with numbers/bools uses C# formatting");
            Check("x" + 'y' == "xy", "string + char");
            Check(string.Concat("a", "b", "c") == "abc", "string.Concat");
            Check("abc".CompareTo("abd") < 0 && "b".CompareTo("a") > 0, "CompareTo");
            Check(string.Compare("a", "A", true) == 0, "Compare ignore case");
            Check("Hello".Equals("Hello") && "Hello" == "Hello" && "a" != "b", "equality");
            Check("abc".GetHashCode() == "abc".GetHashCode(), "GetHashCode stable");
            Check(string.Empty == "" && string.Empty.Length == 0, "string.Empty");

            // Formatting
            float f = 3.14159f;
            Check(f.ToString("F2") == "3.14", "ToString(F2): " + f.ToString("F2"));
            Check((1234.5f).ToString("F0") == "1235", "ToString(F0) rounds: " + (1234.5f).ToString("F0"));
            Check((42).ToString("D4") == "0042", "ToString(D4)");
            Check((255).ToString("X") == "FF" && (255).ToString("x2") == "ff", "hex formatting");
            Check((1234567.891f).ToString("N2") == "1,234,567.88" || (1234567.891f).ToString("N2") == "1,234,567.89", "N2 grouping: " + (1234567.891f).ToString("N2"));
            Check((0.256f).ToString("P0") == "26 %", "P0: " + (0.256f).ToString("P0"));
            Check((3.5f).ToString("0.00") == "3.50" && (3f).ToString("0.##") == "3", "custom patterns");
            Check((3f).ToString() == "3" && (2.5f).ToString() == "2.5" && (-0.5f).ToString() == "-0.5", "float.ToString shortest: " + (3f).ToString());
            Check(true.ToString() == "True" && false.ToString() == "False", "bool.ToString");
            Check(string.Format("{0} of {1}", 3, 10) == "3 of 10", "string.Format positional");
            Check(string.Format("{0:F1}|{1,4}|{2,-4}|", 1.25f, 7, "ab") == "1.3|   7|ab  |" || string.Format("{0:F1}|{1,4}|{2,-4}|", 1.25f, 7, "ab") == "1.2|   7|ab  |", "string.Format spec/alignment: " + string.Format("{0:F1}|{1,4}|{2,-4}|", 1.25f, 7, "ab"));
            Check(string.Format("{{literal}} {0}", 1) == "{literal} 1", "string.Format escaped braces");
            int n = 5;
            string interp = $"n={n} half={n / 2f:F1} vec={Vector3.one}";
            Check(interp == "n=5 half=2.5 vec=(1.00, 1.00, 1.00)", "interpolation: " + interp);
            Check(Vector3.one.ToString() == "(1.00, 1.00, 1.00)", "Vector3.ToString");
            Check(new Vector2(1.5f, 2f).ToString() == "(1.50, 2.00)", "Vector2.ToString");

            // Parsing / Convert
            Check(int.Parse("42") == 42 && float.Parse("2.5") == 2.5f, "Parse");
            int parsed;
            Check(int.TryParse("17", out parsed) && parsed == 17, "int.TryParse ok");
            Check(!int.TryParse("x7", out parsed), "int.TryParse fails");
            float pf;
            Check(float.TryParse("1.75", out pf) && pf == 1.75f, "float.TryParse");
            Check(Convert.ToInt32("12") == 12 && Convert.ToSingle("1.5") == 1.5f && Convert.ToInt32(2.6f) == 3, "Convert");
            Check(Convert.ToString(7) == "7" && Convert.ToBoolean(1) && !Convert.ToBoolean(0), "Convert bool/string");
            Check(Convert.ToInt32("ff", 16) == 255 && Convert.ToString(255, 16) == "ff" && Convert.ToString(5, 2) == "101", "Convert bases");
            Check("12".ToString() == "12" && (12).ToString() == "12", "ToString identity");

            // char
            Check(char.IsDigit('7') && !char.IsDigit('a') && char.IsLetter('a') && char.IsWhiteSpace(' ') && char.IsUpper('Q'), "char classification");
            Check(char.ToUpper('a') == 'A' && char.ToLower('A') == 'a', "char case");
            Check('a' < 'b' && 'z' - 'a' == 25, "char comparison/arithmetic");

            // StringBuilder
            StringBuilder sb = new StringBuilder();
            sb.Append("a").Append(1).Append(2.5f).Append('c').AppendLine().AppendFormat("{0}-{1}", "x", 9);
            Check(sb.ToString() == "a12.5c\nx-9", "StringBuilder chain: " + sb.ToString());
            Check(sb.Length == 10, "StringBuilder.Length");
            sb.Insert(0, ">");
            sb.Replace("x", "y");
            sb.Remove(1, 1);
            Check(sb.ToString() == ">12.5c\ny-9", "StringBuilder insert/replace/remove: " + sb.ToString());
            sb.Clear();
            Check(sb.Length == 0 && sb.ToString() == "", "StringBuilder.Clear");
            sb.Append("hello");
            sb[0] = 'J';
            Check(sb[0] == 'J' && sb[4] == 'o' && sb.ToString() == "Jello", "StringBuilder indexer get/set: " + sb.ToString());

            // primitive leftovers: decimal, char categories, string extras, small integer parsing
            decimal d1 = new decimal(10.5);
            decimal d2 = new decimal(4);
            Check(decimal.Add(d1, d2) == new decimal(14.5) && decimal.Subtract(d1, d2) == new decimal(6.5) && decimal.Multiply(d1, d2) == new decimal(42), "decimal Add/Subtract/Multiply");
            Check(decimal.Divide(d1, d2) == new decimal(2.625) && decimal.Remainder(d1, d2) == new decimal(2.5) && decimal.Negate(d1) == new decimal(-10.5), "decimal Divide/Remainder/Negate");
            Check(decimal.Floor(d1) == new decimal(10) && decimal.Ceiling(d1) == new decimal(11) && decimal.Truncate(decimal.Negate(d1)) == new decimal(-10), "decimal Floor/Ceiling/Truncate");
            Check(decimal.Round(new decimal(2.5)) == new decimal(2) && decimal.Round(new decimal(3.5)) == new decimal(4) && decimal.Round(new decimal(2.5), MidpointRounding.AwayFromZero) == new decimal(3), "decimal Round to even / away from zero");
            Check(decimal.Round(new decimal(1.2345), 2) == new decimal(1.23), "decimal Round digits");
            Check(decimal.Compare(d1, d2) == 1 && decimal.Compare(d2, d1) == -1 && decimal.ToInt32(d1) == 10 && decimal.ToDouble(d2) == 4.0, "decimal Compare/ToInt32/ToDouble");
            Check(decimal.Parse("12.5") == new decimal(12.5) && decimal.Add(decimal.One, decimal.MinusOne) == decimal.Zero, "decimal Parse and constants");
            decimal dp;
            bool dok = decimal.TryParse("7.25", out dp);
            decimal dgot = dp;
            bool dbad = decimal.TryParse("x", out dp);
            Check(dok && dgot == new decimal(7.25) && !dbad, "decimal TryParse");
            int[] bits = decimal.GetBits(new decimal(-12.5));
            Check(bits.Length == 4 && bits[0] == 125 && ((bits[3] >> 16) & 255) == 1 && bits[3] < 0 && new decimal(bits) == new decimal(-12.5), "decimal GetBits / ctor(bits): " + bits[0] + " " + bits[3]);
            Check(!char.IsHighSurrogate('a') && !char.IsLowSurrogate('a') && !char.IsSurrogatePair('a', 'b'), "char surrogate tests");
            Check(char.GetUnicodeCategory('A') == UnicodeCategory.UppercaseLetter && char.GetUnicodeCategory('a') == UnicodeCategory.LowercaseLetter && char.GetUnicodeCategory('7') == UnicodeCategory.DecimalDigitNumber && char.GetUnicodeCategory(' ') == UnicodeCategory.SpaceSeparator, "char.GetUnicodeCategory");
            Check(new string('x', 3) == "xxx" && new string(new char[] { 'a', 'b', 'c' }) == "abc" && new string(new char[] { 'a', 'b', 'c', 'd' }, 1, 2) == "bc", "string ctors");
            Check("hello world".IndexOfAny(new char[] { 'w', 'o' }) == 4 && "hello world".IndexOfAny(new char[] { 'o' }, 5) == 7 && "hello".IndexOfAny(new char[] { 'z' }) == -1, "IndexOfAny");
            Check("hello world".LastIndexOfAny(new char[] { 'o', 'h' }) == 7 && "hello world".LastIndexOfAny(new char[] { 'o' }, 6) == 4, "LastIndexOfAny");
            Check(string.CompareOrdinal("a", "b") < 0 && string.CompareOrdinal("b", "a") > 0 && string.CompareOrdinal("abc", "abc") == 0 && string.CompareOrdinal("xxab", 2, "yyab", 2, 2) == 0, "CompareOrdinal");
            char[] dest = new char[5];
            "hello".CopyTo(1, dest, 0, 3);
            Check(dest[0] == 'e' && dest[2] == 'l', "string.CopyTo");
            Check(string.Copy("abc") == "abc" && string.Intern("q") == "q" && "abc".IsNormalized() && "abc".Normalize() == "abc", "Copy/Intern/Normalize");
            Check(sbyte.Parse("-5") == -5 && ushort.Parse("65535") == 65535 && ulong.Parse("1234") == 1234, "sbyte/ushort/ulong Parse");
            ushort us;
            bool uok = ushort.TryParse("42", out us);
            ushort ugot = us;
            bool ubad = ushort.TryParse("x", out us);
            Check(uok && ugot == 42 && !ubad, "ushort.TryParse");
            Check(double.IsPositiveInfinity(double.PositiveInfinity) && double.IsNegativeInfinity(double.NegativeInfinity) && !double.IsPositiveInfinity(1.0), "double infinities");
            object o1 = new object();
            object o2 = new object();
            Check(o1 != null && !o1.Equals(o2) && o1.Equals(o1), "new object() identities");

            // Regex
            Regex re = new Regex(@"(\w+)@(\w+)\.com");
            Check(re.IsMatch("mail bob@example.com now"), "Regex.IsMatch");
            Match m = re.Match("mail bob@example.com now");
            Check(m.Success && m.Value == "bob@example.com" && m.Index == 5, "Match value/index");
            Check(m.Groups.Count == 3 && m.Groups[1].Value == "bob" && m.Groups[2].Value == "example", "Groups");
            Check(Regex.Replace("a1b22c333", @"\d+", "#") == "a#b#c#", "Regex.Replace");
            Check(Regex.Replace("2024-01-02", @"(\d+)-(\d+)-(\d+)", "$3/$2/$1") == "02/01/2024", "Regex.Replace group refs");
            MatchCollection all = Regex.Matches("x1 y22 z333", @"\d+");
            Check(all.Count == 3 && all[2].Value == "333", "Regex.Matches");
            string[] rs = Regex.Split("a1b2c", @"\d");
            Check(rs.Length == 3 && rs[1] == "b", "Regex.Split");
            Check(Regex.Escape("a.b") == "a\\.b", "Regex.Escape");
            Regex ci = new Regex("hello", RegexOptions.IgnoreCase);
            Check(ci.IsMatch("HELLO there"), "RegexOptions.IgnoreCase");

            // DateTime / TimeSpan
            DateTime now = DateTime.Now;
            Check(now.Year >= 2024, "DateTime.Now.Year");
            DateTime later = now.AddSeconds(90);
            TimeSpan diff = later - now;
            Check(Math.Abs(diff.TotalSeconds - 90.0) < 0.01 && diff.Minutes == 1 && diff.Seconds == 30, "TimeSpan from DateTime subtraction");
            Check(later > now && now < later && now == now, "DateTime comparisons");
            TimeSpan ts = TimeSpan.FromMinutes(2.5);
            Check(Math.Abs(ts.TotalSeconds - 150.0) < 0.001, "TimeSpan.FromMinutes");
            DateTime d = new DateTime(2020, 2, 29, 12, 30, 0);
            Check(d.Year == 2020 && d.Month == 2 && d.Day == 29 && d.Hour == 12 && d.Minute == 30, "DateTime ctor parts");
            Check(d.ToString("yyyy-MM-dd HH:mm") == "2020-02-29 12:30", "DateTime.ToString pattern: " + d.ToString("yyyy-MM-dd HH:mm"));
            Check(DateTime.IsLeapYear(2020) && !DateTime.IsLeapYear(2021), "IsLeapYear");
            Check(DateTime.DaysInMonth(2021, 2) == 28, "DaysInMonth");

            // Math (System)
            Check(Math.Abs(-2.5) == 2.5 && Math.Max(3, 7) == 7 && Math.Round(2.5) == 2.0 && Math.Round(3.5) == 4.0, "System.Math");
            Check(Math.Truncate(-2.7) == -2.0 && Math.Floor(-2.7) == -3.0 && Math.Ceiling(2.1) == 3.0, "Math.Truncate/Floor/Ceiling");
            Check(Math.Sign(-3) == -1 && Math.Sign(0) == 0, "Math.Sign");
            Check(Math.Round(2.345, 2) == 2.35 || Math.Round(2.345, 2) == 2.34, "Math.Round digits");

            // Guid / BitConverter
            string guid = Guid.NewGuid().ToString();
            Check(guid.Length >= 32, "Guid.NewGuid");
            byte[] bytes = BitConverter.GetBytes(258);
            Check(bytes.Length == 4 && bytes[0] == 2 && bytes[1] == 1 && BitConverter.ToInt32(bytes, 0) == 258, "BitConverter int round trip");
            Check(BitConverter.Int32BitsToSingle(BitConverter.SingleToInt32Bits(1.5f)) == 1.5f, "float bits round trip");
            done = true;
        }
    }
}
