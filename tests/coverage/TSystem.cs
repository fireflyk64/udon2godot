using UdonSharp;
using UnityEngine;
using System;
using System.Globalization;

namespace Coverage
{
    /// System types: TimeSpan, Guid, BitConverter, DateTime extras, CultureInfo, Vector4/Vector3Int/
    /// Vector2Int, Rect/Plane/Bounds setters, Mathf extras, Matrix4x4 element writes, System.Random.
    public class TSystem : UdonSharpBehaviour
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

        private bool Near(float a, float b) { return Mathf.Abs(a - b) < 0.01f; }

        public void RunTests()
        {
            TimeSpan a = TimeSpan.FromMinutes(90);
            Check(Near((float)a.TotalHours, 1.5f) && a.Hours == 1 && a.Minutes == 30, "TimeSpan components");
            TimeSpan b = new TimeSpan(0, 0, 45);
            TimeSpan c = a.Add(b).Subtract(TimeSpan.FromSeconds(15));
            Check(Near((float)c.TotalSeconds, 5430f), "TimeSpan Add/Subtract " + c.TotalSeconds);
            Check(TimeSpan.Compare(a, b) > 0 && a.CompareTo(b) > 0 && a.Negate().TotalSeconds < 0 && Near((float)a.Negate().Duration().TotalSeconds, 5400f), "TimeSpan Compare/Negate/Duration");
            TimeSpan p;
            Check(TimeSpan.TryParse("01:02:03", out p) && Near((float)p.TotalSeconds, 3723f), "TimeSpan.TryParse " + p.TotalSeconds);
            Check(!TimeSpan.TryParse("nope", out p), "TimeSpan.TryParse rejects garbage");
            Check(TimeSpan.Parse("1.02:03:04.5").Days == 1 && Near((float)TimeSpan.FromTicks(TimeSpan.TicksPerSecond * 3).TotalSeconds, 3f), "TimeSpan.Parse days / FromTicks");
            Check(a > b && b < a && a != b && (a - b).Minutes == 29, "TimeSpan operators");

            Guid g = Guid.NewGuid();
            string gs = g.ToString();
            Check(gs.Length == 36 && Guid.Parse(gs) == g && Guid.Empty.ToString() == "00000000-0000-0000-0000-000000000000", "Guid Parse/Empty " + gs);
            Guid g2;
            bool badGuid = Guid.TryParse("not a guid", out g2);
            bool goodGuid = Guid.TryParse(gs, out g2);
            Check(!badGuid && goodGuid && g2 == g, "Guid.TryParse");
            Check(g.ToByteArray().Length == 16 && new Guid(g.ToByteArray()) == g && g.ToString("N").Length == 32, "Guid bytes/format");

            byte[] bs = BitConverter.GetBytes((short)-2);
            Check(bs.Length == 2 && BitConverter.ToInt16(bs, 0) == -2, "BitConverter Int16");
            byte[] bl = BitConverter.GetBytes(123456789012L);
            Check(bl.Length == 8 && BitConverter.ToInt64(bl, 0) == 123456789012L, "BitConverter Int64");
            byte[] bd = BitConverter.GetBytes(3.25);
            Check(bd.Length == 8 && BitConverter.ToDouble(bd, 0) == 3.25, "BitConverter Double");
            Check(BitConverter.IsLittleEndian && BitConverter.ToBoolean(new byte[] { 0, 1 }, 1) && BitConverter.Int64BitsToDouble(BitConverter.DoubleToInt64Bits(2.5)) == 2.5, "BitConverter misc");
            Check(BitConverter.ToUInt16(BitConverter.GetBytes((ushort)65535), 0) == 65535, "BitConverter UInt16");

            DateTime d = new DateTime(2024, 3, 5, 6, 7, 8);
            Check(DateTime.FromBinary(d.ToBinary()).Ticks == d.Ticks, "DateTime ToBinary/FromBinary");
            Check(DateTime.FromOADate(25569.0).Year == 1970, "DateTime.FromOADate");
            Check(DateTime.SpecifyKind(d, DateTimeKind.Utc).Hour == 6, "DateTime.SpecifyKind");
            DateTime pd;
            Check(DateTime.TryParseExact("2024-03-05", "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out pd) && pd.Day == 5, "DateTime.TryParseExact");
            Check(CultureInfo.InvariantCulture.TwoLetterISOLanguageName == "iv", "CultureInfo constants");
            Check(Convert.ToDateTime("2020-01-02").Year == 2020, "Convert.ToDateTime");

            Vector4 v4 = new Vector4(1, 2, 3, 4);
            Check(Near(v4[3], 4f) && Near(Vector4.Distance(v4, Vector4.zero), v4.magnitude) && Near(Vector4.Project(v4, new Vector4(1, 0, 0, 0)).x, 1f) && Near(Vector4.MoveTowards(Vector4.zero, v4, 1f).magnitude, 1f), "Vector4 extras");
            Vector3Int vi = new Vector3Int(1, 2, 3);
            Check(vi[2] == 3 && Vector3Int.RoundToInt(new Vector3(1.4f, 2.6f, -0.7f)) == new Vector3Int(1, 3, -1), "Vector3Int indexer/RoundToInt");
            Check(Vector3Int.forward == new Vector3Int(0, 0, 1) && Near(Vector3Int.Distance(Vector3Int.zero, new Vector3Int(3, 4, 0)), 5f) && Vector3Int.Max(vi, new Vector3Int(0, 5, 0)) == new Vector3Int(1, 5, 3), "Vector3Int statics");
            Vector2Int v2 = Vector2Int.FloorToInt(new Vector2(1.7f, -1.2f));
            Check(v2 == new Vector2Int(1, -2) && v2.sqrMagnitude == 5, "Vector2Int FloorToInt/sqrMagnitude");
            Check(Near(Vector2.SqrMagnitude(new Vector2(3, 4)), 25f) && Vector2.kEpsilon < 0.001f, "Vector2 extras");

            Rect r = Rect.MinMaxRect(1, 2, 5, 8);
            Check(Near(r.width, 4f) && Near(r.height, 6f), "Rect.MinMaxRect");
            r.xMax = 7f;
            r.center = new Vector2(0, 0);
            Check(Near(r.width, 6f) && Near(r.xMin, -3f), "Rect setters " + r.width + " " + r.xMin);
            Check(Near(Rect.NormalizedToPoint(new Rect(0, 0, 10, 10), new Vector2(0.5f, 0.1f)).x, 5f) && Near(Rect.PointToNormalized(new Rect(0, 0, 10, 10), new Vector2(2, 5)).y, 0.5f), "Rect normalized");
            Plane pl = new Plane(Vector3.up, Vector3.zero);
            Check(pl.SameSide(new Vector3(0, 1, 0), new Vector3(0, 2, 0)) && !pl.SameSide(new Vector3(0, 1, 0), new Vector3(0, -2, 0)) && Near(pl.flipped.distance, 0f), "Plane SameSide/flipped");
            pl.Translate(new Vector3(0, 2, 0));
            Check(Near(pl.GetDistanceToPoint(new Vector3(0, 3, 0)), 1f), "Plane.Translate " + pl.GetDistanceToPoint(new Vector3(0, 3, 0)));
            Bounds bb = new Bounds(Vector3.zero, Vector3.one * 2);
            float dist;
            Check(bb.IntersectRay(new Ray(new Vector3(0, 5, 0), Vector3.down)) && bb.IntersectRay(new Ray(new Vector3(0, 5, 0), Vector3.down), out dist) && Near(dist, 4f), "Bounds.IntersectRay " + dist);
            bb.extents = new Vector3(2, 2, 2);
            Check(Near(bb.size.x, 4f) && Near(bb.center.x, 0f), "Bounds.extents set");
            Check(Mathf.CorrelatedColorTemperatureToRGB(6500f).r > 0.9f && Near(Mathf.HalfToFloat(Mathf.FloatToHalf(1.5f)), 1.5f), "Mathf colour temperature / half");
            Color col = Color.red;
            Check(Near(col[0], 1f) && Near(col[1], 0f), "Color indexer");
            Matrix4x4 m = Matrix4x4.identity;
            m.m03 = 5f;
            Check(Near(m.m03, 5f) && Near(m.MultiplyPoint(Vector3.zero).x, 5f), "Matrix4x4 element setter");
            System.Random rnd = new System.Random(5);
            byte[] rb = new byte[4];
            rnd.NextBytes(rb);
            Check(rb.Length == 4 && rnd.Next(1, 3) >= 1, "System.Random.NextBytes/Next");
            TextAsset ta = new TextAsset("hello text");
            Check(ta.text == "hello text" && ta.bytes.Length == 10 && ta.dataSize == 10, "TextAsset");
            Type vt = typeof(Vector3);
            Check(vt.IsVisible && vt.UnderlyingSystemType == vt && vt.MakeArrayType().HasElementType, "Type reflection extras");
            done = true;
        }
    }
}
