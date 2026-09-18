using System;
using UdonSharp;
using UnityEngine;
using VRC.SDK3.Data;
using VRC.SDKBase;

namespace Coverage
{
    /// Base of the fixture: a constant the derived class hides, and abstract / virtual properties.
    public abstract class TNullsBase : UdonSharpBehaviour
    {
        public const int Order = 10;
        public abstract Type Kind { get; }
        public virtual int Sides { get; set; }
        public virtual string Label => "base";

        // overloads in the base, one of them overridden below
        public virtual int Pick() { return Pick(2); }
        protected virtual int Pick(int n) { return n; }

        public int BaseOrder() { return Order; }
        public string Describe() { return Label + ":" + Sides + ":" + (Kind == typeof(Light)); }
    }

    /// null in places where the generated code has a Godot value type (arrays, DataDictionary,
    /// strings, System.Type), `default`, and members that hide or override base members. All of
    /// these compiled to scripts the sandbox rejected before `scripts/compile_check_refs.sh`.
    public class TNulls : TNullsBase
    {
        public string[] failures = new string[64];
        public int failCount;
        public int total;
        public bool done;

        public new const int Order = TNullsBase.Order + 5;
        public override Type Kind => typeof(Light);
        public override int Sides { get; set; }
        public override string Label => "derived";

        protected override int Pick(int n) { return base.Pick(n) * 10; }
        private int Pick(int a, int b) { return a + b; }

        public int[] shown;
        private int[] cache;
        private DataDictionary info;
        private string note;
        private Type seen;
        private VRCUrl link;
        private int calls;

        private void Check(bool ok, string what)
        {
            total++;
            if (!ok) { failures[failCount] = what; failCount++; }
        }

        // generic methods that need T at run time
        private static T OnSame<T>(Component c) where T : Component { return c.GetComponent<T>(); }
        private static T Relay<T>(Component c) where T : Component { return OnSame<T>(c); }
        private static string TypeName<T>() { return typeof(T).Name; }
        private static bool TryOnSame<T>(Component c, out T found) where T : Component { found = c.GetComponent<T>(); return found != null; }
        private static T Cached<T>(Component c, ref T cached) where T : Component
        {
            if (cached != null) return cached;
            TryOnSame(c, out cached);
            return cached;
        }
        private static int CountEqual<T>(T[] items, T probe) { int n = 0; foreach (T i in items) if (i.Equals(probe)) n++; return n; }

        // base calls into UdonSharpBehaviour's own (empty) events
        private int interacts;
        private int restoredCalls;
        public override void Interact() { base.Interact(); interacts++; }
        public override void OnPlayerRestored(VRCPlayerApi player) { base.OnPlayerRestored(player); restoredCalls++; }

        private int[] Cache()
        {
            if (cache == null) cache = new int[3];
            return cache;
        }

        private int[] Give(int n)
        {
            if (n < 0) return null;
            return new int[n];
        }

        private string NameOf(int n) { return n < 0 ? null : "n" + n; }

        private bool TryInfo(bool ok, out DataDictionary result, ref int[] list)
        {
            if (!ok) { result = null; list = null; return false; }
            result = new DataDictionary();
            result["k"] = 7;
            list = new int[2];
            return true;
        }

        private bool TryBounds(bool ok, out Bounds b)
        {
            b = default;
            if (!ok) return false;
            b = new Bounds(Vector3.one, Vector3.one * 2f);
            return true;
        }

        private int Count(int[] xs = null) { return xs == null ? -1 : xs.Length; }

        private string Next() { calls++; return calls > 1 ? "second" : null; }

        public void RunTests()
        {
            // arrays
            Check(cache == null, "an array field nothing assigned is null");
            Check(Cache().Length == 3 && cache != null, "lazy array init through a null test");
            Cache()[1] = 5;
            Check(Cache()[1] == 5, "the lazily created array is kept");
            cache = null;
            Check(cache == null && Cache().Length == 3 && cache[1] == 0, "an array set to null is created again");
            int[] got = Give(-1);
            Check(got == null, "a method returns a null array");
            got = Give(4);
            Check(got != null && got.Length == 4, "and a real one");
            int[] local = null;
            Check(Count(local) == -1 && Count() == -1 && Count(new int[2]) == 2, "null array arguments and a null default");

            Check(shown != null && shown.Length == 0, "a serialized array starts empty, as in Unity");
            shown = null;
            Check(shown == null, "and can be set to null");

            // out / ref results
            int[] list = new int[1];
            DataDictionary d;
            Check(!TryInfo(false, out d, ref list) && d == null && list == null, "out / ref results can be null");
            Check(TryInfo(true, out d, ref list) && d != null && d["k"].Int == 7 && list.Length == 2, "out / ref results with values");
            info = d;
            Check(info != null, "a DataDictionary field holds a value");
            info = null;
            Check(info == null, "and null again");

            // strings and classes that are strings on the Godot side
            note = null;
            Check(note == null && string.IsNullOrEmpty(note), "a string field set to null");
            note = NameOf(3);
            Check(note == "n3" && NameOf(-1) == null, "a method returns a null string");
            seen = null;
            Check(seen == null, "a Type field set to null");
            seen = typeof(Light);
            Check(seen != null && seen == Kind, "a Type field with a value");
            link = null;
            Check(link == null, "a VRCUrl field set to null");
            string first = Next() ?? "fallback";
            Check(first == "fallback" && calls == 1, "the left side of ?? runs once: " + calls);
            string second = Next() ?? "fallback";
            Check(second == "second" && calls == 2, "?? keeps a non-null left side: " + second);

            // default
            Bounds b;
            Check(!TryBounds(false, out b) && b.size == Vector3.zero, "default for a struct out parameter");
            Check(TryBounds(true, out b) && b.center == Vector3.one, "struct out parameter with a value");
            Vector3 v = default;
            int n = default;
            string s = default;
            Check(v == Vector3.zero && n == 0 && s == null, "default literals");

            // members that hide or override base members
            Check(Order == 15 && BaseOrder() == 10 && TNullsBase.Order == 10, "a `new const` hides the base constant: " + Order + " / " + BaseOrder());
            Sides = 4;
            Check(Sides == 4 && Describe() == "derived:4:True", "virtual properties dispatch to the override: " + Describe());
            Check(Pick() == 20 && Pick(3) == 30 && Pick(1, 2) == 3, "an override of the second base overload: " + Pick() + " / " + Pick(3));

            // generics
            Check(OnSame<Transform>(this) == transform && Relay<Transform>(this) == transform, "GetComponent<T>() inside a generic method");
            Check(OnSame<TNulls>(this) == this && OnSame<TNullsBase>(this) == this, "GetComponent<T>() of a behaviour and of its base class");
            Check(TypeName<Light>() == typeof(Light).Name && GetUdonTypeName<TNulls>() == "TNulls", "typeof(T) and GetUdonTypeName<T>()");
            Transform tf = null;
            Check(Cached(this, ref tf) == transform && tf == transform, "T inferred from a ref argument and passed on through out");
            Check(CountEqual(new int[] { 1, 2, 1 }, 1) == 2 && CountEqual(new string[] { "a", "b" }, "b") == 1, "Equals on values of a type parameter");

            // base calls that end in UdonSharpBehaviour
            int before = restoredCalls;
            OnPlayerRestored(Networking.LocalPlayer);
            Interact();
            Check(restoredCalls == before + 1 && interacts == 1, "base.OnPlayerRestored() / base.Interact() run the override once: " + (restoredCalls - before) + " / " + interacts);
            done = true;
        }
    }
}
