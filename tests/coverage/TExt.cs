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
    }

    public class TExt : UdonSharpBehaviour
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
            int[] three = new int[3];
            int[] none = null;
            Check(three.LengthSafe() == 3 && none.LengthSafe() == 0, "extension on an array (generic this T[]), null receiver");
            Check("a".Tagged() == "<x>a" && "a".Tagged("b") == "<b>a", "extension on string with a default argument");
            float f = 5f;
            Check(Mathf.Abs(f.Half() - 2.5f) < 0.001f, "extension on float");
            Check((transform.Above(2f) - transform.position - Vector3.up * 2f).magnitude < 0.001f, "extension on a Unity type (Transform)");
            Check(TExtHelpers.Twice(21) == 42 && TExtHelpers.Answer == 42, "cross-class static call and chained constant: " + TExtHelpers.Twice(21) + " " + TExtHelpers.Answer);
            var d = new DataDictionary { ["ok"] = true, ["n"] = 3 };
            Check(d.Count == 2 && d["n"].Int == 3 && d["ok"].Boolean, "index initializer on DataDictionary");
            var l = new DataList { 1, 2, 3 };
            Check(l.Count == 3 && l[2].Int == 3, "collection initializer on DataList");
            done = true;
        }
    }
}
