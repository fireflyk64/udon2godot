using UdonSharp;
using UnityEngine;
using VRC.SDK3.Data;

namespace Coverage
{
    using Helpers = Coverage.TExtHelpers;

    /// Extension methods (static classes with `this` parameters, as UdonUtils and VUdon use them),
    /// cross-class statics and constants, object / collection / index initializers.
    public static class TExtHelpers
    {
        public const int Base = 40;
        public const int Answer = Base + 2;

        public static int LengthSafe<T>(this T[] array)
        {
            return array == null ? 0 : array.Length;
        }

        public static string Tagged(this string s, string tag = "x")
        {
            return "<" + tag + ">" + s;
        }

        public static float Half(this float f)
        {
            return f * 0.5f;
        }

        public static Vector3 Above(this Transform t, float metres)
        {
            return t.position + Vector3.up * metres;
        }

        public static int Twice(int n)
        {
            return n * 2;
        }

        public static bool TryHalve(this int n, out int half)
        {
            half = n / 2;
            return n % 2 == 0;
        }

        public static bool TryFirst<T>(this T[] items, out T first)
        {
            first = default;
            if (items == null || items.Length == 0) { return false; }
            first = items[0];
            return true;
        }

        public static void Bump(ref int counter, int by)
        {
            counter += by;
        }
    }

    public enum TExtMode { Idle, Run = 5 }

    public class TExtPeer : UdonSharpBehaviour
    {
        public const int Order = 7;
        public static int Thrice(int n) { return n * 3; }
    }

    public class TExt : UdonSharpBehaviour
    {
        // C# "Color Color": a field named like its type does not hide the type's statics
        public TExtPeer TExtPeer;

        public string[] failures = new string[64];
        public int failCount;
        public int total;
        public bool done;

        private void Check(bool ok, string what)
        {
            total++;
            if (!ok) { failures[failCount] = what; failCount++; }
        }

        private Vector3 Pick(int mode)
        {
            switch (mode)
            {
                case 0:
                    Vector3 dir = Vector3.up;
                    return dir;
                case 1:
                    dir = Vector3.right;
                    return dir;
            }
            return Vector3.zero;
        }

        // A `break` that follows a nested foreach: the sandbox compiler left the inner loop's context
        // on its stack and the break jumped to a label that was never emitted (the script did not load).
        private int BreakAfterInner(int[] items)
        {
            int n = 0;
            foreach (int a in items)
            {
                if (a == 1)
                {
                    foreach (int b in items) { n++; }
                    if (n != 0) { break; }
                }
                n += 100;
            }
            return n;
        }

        private int touched;
        private bool Touch(out int v)
        {
            touched++;
            v = 7;
            return true;
        }

        public void RunTests()
        {
            int[] three = new int[3];
            int[] none = null;
            Check(three.LengthSafe() == 3 && none.LengthSafe() == 0, "extension on an array (generic this T[]), null receiver");
            Check("a".Tagged() == "<x>a" && "a".Tagged("b") == "<b>a", "extension on string with a default argument");
            float f = 5f;
            Check(Mathf.Abs(f.Half() - 2.5f) < 0.001f, "extension on float");
            Check((transform.Above(2f) - transform.position - Vector3.up * 2f).magnitude < 0.001f, "extension on a Unity type (Transform)");
            Check(TExtHelpers.Twice(21) == 42 && TExtHelpers.Answer == 42, "cross-class static call and chained constant: " + TExtHelpers.Twice(21) + " " + TExtHelpers.Answer);
            int ten = 10;
            Check(ten.TryHalve(out var five) && five == 5 && !five.TryHalve(out int two) && two == 2, "out var through an extension method of another class: " + five + " " + two);
            string[] words = new string[] { "first", "second" };
            Check(words.TryFirst(out var word) && word.Length == 5, "generic out parameter takes the element type: " + word);
            int counter = 1;
            TExtHelpers.Bump(ref counter, 4);
            Check(counter == 5, "ref argument through a cross-class static call: " + counter);
            TExtMode mode = TExtMode.Run;
            Check(mode.ToString() == "Run" && ("" + mode) == "Run" && $"{mode}" == "Run" && KeyCode.Space.ToString() == "Space", "enum values print as member names: " + mode);
            Check(TExtPeer.Order == 7 && TExtPeer.Thrice(4) == 12 && TExtPeer == null, "field named like its type still reaches the type's statics");
            Check(Pick(0) == Vector3.up && Pick(1) == Vector3.right, "switch sections share one declaration space");
            var byKey = new DataDictionary();
            string key = " k ";
            byKey[key.Trim()] = 5;
            Check(byKey.Count == 1 && byKey["k"].Int == 5, "dictionary element with a computed key is assigned");
            Check(GetType().Name == "TExt", "GetType() on this: " + GetType());
            string oldName = name;
            name = "Renamed";
            Check(gameObject.name == "Renamed", "inherited `name` setter without this.");
            name = oldName;
            Check(Mathf.Abs(Single.Parse("1.5") - 1.5f) < 0.001f && Int32.MaxValue == int.MaxValue, "BCL aliases of keyword types");
            Check(BreakAfterInner(new int[] { 2, 1, 3 }) == 103, "break after a nested foreach leaves the outer loop: " + BreakAfterInner(new int[] { 2, 1, 3 }));
            // && and || whose right operand needs statements (an out argument): it must not run when
            // the left operand decides, the usual `x != null && x.TryGet(out y)` guard relies on it
            bool no = failCount > 1000;
            bool yes = !no;
            int a1, a2;
            bool r1 = no && Touch(out a1);
            bool r2 = yes || Touch(out a2);
            Check(!r1 && r2 && touched == 0, "short-circuit skips a right operand with an out argument: touched " + touched);
            bool r3 = yes && Touch(out int a3);
            Check(r3 && a3 == 7 && touched == 1, "and runs it when the left operand lets it: " + a3 + " touched " + touched);
            int[] missing = null;
            Check(!(missing != null && missing.TryFirst(out int firstOfNone)), "null guard before an extension call with an out argument");
            var d = new DataDictionary { ["ok"] = true, ["n"] = 3 };
            Check(d.Count == 2 && d["n"].Int == 3 && d["ok"].Boolean, "index initializer on DataDictionary");
            var l = new DataList { 1, 2, 3 };
            Check(l.Count == 3 && l[2].Int == 3, "collection initializer on DataList");
            done = true;
        }
    }
}
