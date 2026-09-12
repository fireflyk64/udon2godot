using UdonSharp;
using UnityEngine;

namespace Coverage
{
    /// Math part B: Vector2, Quaternion, Color, Matrix4x4, Random, Bounds/Rect/Plane/Ray.
    public class TMathB : UdonSharpBehaviour
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

        private bool Near(float a, float b) { return Mathf.Abs(a - b) < 0.001f; }
        private bool NearV(Vector3 a, Vector3 b) { return (a - b).magnitude < 0.001f; }

        public void RunTests()
        {
            // Vector2
            Vector2 v2 = new Vector2(3, 4);
            Check(Near(v2.magnitude, 5f) && Near(Vector2.Dot(Vector2.up, Vector2.up), 1f), "Vector2 basics");
            Check(Near(Vector2.Angle(Vector2.right, Vector2.up), 90f), "Vector2.Angle");
            Check(Near(Vector2.SignedAngle(Vector2.right, Vector2.up), 90f), "Vector2.SignedAngle");
            Vector3 v2to3 = v2;
            Check(NearV(v2to3, new Vector3(3, 4, 0)), "Vector2→Vector3 implicit");
            Vector2 v3to2 = (Vector2)new Vector3(1, 2, 3);
            Check(Near(v3to2.x, 1f) && Near(v3to2.y, 2f), "Vector3→Vector2 explicit");

            // Quaternion
            Quaternion q = Quaternion.Euler(0, 90, 0);
            Vector3 rotated = q * Vector3.forward;
            Check(NearV(rotated, Vector3.right), "Euler(0,90,0) rotates forward to right (Unity)");
            Check(NearV(Quaternion.Euler(90, 0, 0) * Vector3.forward, Vector3.down), "Euler(90,0,0) rotates forward to down");
            Check(NearV(Quaternion.AngleAxis(90, Vector3.up) * Vector3.forward, Vector3.right), "AngleAxis");
            Quaternion lr = Quaternion.LookRotation(Vector3.right);
            Check(NearV(lr * Vector3.forward, Vector3.right), "LookRotation forward");
            Check(NearV(Quaternion.Inverse(q) * rotated, Vector3.forward), "Inverse");
            Check(Near(Quaternion.Angle(Quaternion.identity, q), 90f), "Quaternion.Angle");
            Quaternion half = Quaternion.Slerp(Quaternion.identity, q, 0.5f);
            Check(Near(Quaternion.Angle(Quaternion.identity, half), 45f), "Slerp");
            Vector3 e = q.eulerAngles;
            Check(Near(e.y, 90f), "eulerAngles round trip: " + e.y);
            Quaternion ft = Quaternion.FromToRotation(Vector3.forward, Vector3.up);
            Check(NearV(ft * Vector3.forward, Vector3.up), "FromToRotation");
            Check(Near(Quaternion.Dot(q, q), 1f), "Quaternion.Dot");
            Quaternion rt = Quaternion.RotateTowards(Quaternion.identity, q, 30f);
            Check(Near(Quaternion.Angle(Quaternion.identity, rt), 30f), "RotateTowards");
            Check(q == Quaternion.Euler(0, 90, 0) && q != Quaternion.identity, "Quaternion equality");
            Check(NearV((q * Quaternion.Euler(0, 90, 0)) * Vector3.forward, Vector3.back), "Quaternion composition");

            // Color
            Color c = new Color(1f, 0.5f, 0f, 1f);
            Check(Near(c.r, 1f) && Near(c.g, 0.5f) && Near(c.a, 1f), "Color fields");
            Color lerp = Color.Lerp(Color.black, Color.white, 0.5f);
            Check(Near(lerp.r, 0.5f), "Color.Lerp");
            Check(Near(Color.red.r, 1f) && Near(Color.red.g, 0f) && Near(Color.clear.a, 0f), "Color constants");
            Check(Near((c * 2f).g, 1f), "Color * float");
            Color32 c32 = new Color32(255, 128, 0, 255);
            Color fromC32 = c32;
            Check(Near(fromC32.r, 1f) && c32.g == 128, "Color32");
            float h, s, val;
            Color.RGBToHSV(Color.red, out h, out s, out val);
            Check(Near(h, 0f) && Near(s, 1f) && Near(val, 1f), "RGBToHSV out params");
            Check(Near(Color.HSVToRGB(0f, 1f, 1f).r, 1f), "HSVToRGB");

            // Matrix4x4
            Matrix4x4 m = Matrix4x4.TRS(new Vector3(1, 2, 3), Quaternion.identity, Vector3.one);
            Check(NearV(m.MultiplyPoint(Vector3.zero), new Vector3(1, 2, 3)), "Matrix4x4.TRS translate");
            Check(NearV(m.inverse.MultiplyPoint(new Vector3(1, 2, 3)), Vector3.zero), "Matrix4x4.inverse");
            Check(NearV(m.MultiplyVector(Vector3.up), Vector3.up), "MultiplyVector ignores translation");
            Check(Near(m.m03, 1f) && Near(m.m13, 2f) && Near(m.m23, 3f) && Near(m.m33, 1f) && Near(m.m00, 1f) && Near(m.m01, 0f), "Matrix4x4 elements");
            Check(Near(m[1, 3], 2f) && Near(m[13], 2f) && Near(m[0, 0], 1f), "Matrix4x4 indexers (row,col) and column-major index");
            Vector3 iv = new Vector3(4, 5, 6);
            Quaternion iq = new Quaternion(0, 0, 0, 1);
            Check(Near(iv[0], 4f) && Near(iv[2], 6f) && Near(iq[3], 1f), "Vector3/Quaternion indexers");

            // Random
            int r = Random.Range(0, 3);
            Check(r >= 0 && r < 3, "Random.Range int exclusive max");
            float rf = Random.Range(1f, 2f);
            Check(rf >= 1f && rf <= 2f, "Random.Range float");
            Check(Random.value >= 0f && Random.value <= 1f, "Random.value");
            Check(Random.insideUnitSphere.magnitude <= 1.0001f, "insideUnitSphere");
            Check(Near(Random.onUnitSphere.magnitude, 1f), "onUnitSphere");

            // Bounds / Rect / Plane / Ray
            Bounds bounds = new Bounds(Vector3.zero, new Vector3(2, 2, 2));
            Check(bounds.Contains(new Vector3(0.5f, 0.5f, 0.5f)) && !bounds.Contains(new Vector3(2, 0, 0)), "Bounds.Contains");
            Check(NearV(bounds.min, new Vector3(-1, -1, -1)) && NearV(bounds.extents, Vector3.one), "Bounds min/extents");
            Rect rect = new Rect(0, 0, 10, 5);
            Check(rect.Contains(new Vector2(5, 2)) && Near(rect.xMax, 10f) && Near(rect.center.x, 5f), "Rect");
            Plane plane = new Plane(Vector3.up, Vector3.zero);
            Check(Near(plane.GetDistanceToPoint(new Vector3(0, 3, 0)), 3f) && plane.GetSide(Vector3.up), "Plane");
            Ray ray = new Ray(Vector3.zero, new Vector3(0, 0, 2));
            Check(NearV(ray.GetPoint(5f), new Vector3(0, 0, 5)), "Ray.GetPoint normalizes direction");
            done = true;
        }
    }
}
