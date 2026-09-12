using UdonSharp;
using UnityEngine;

namespace Coverage
{
    /// Coordinate convention: the runner builds this scene the way unidot_importer does (X mirrored,
    /// cameras carry a half-turn) and switches U.coord_mode to UNIDOT. Every number below is what
    /// Unity would report for the same scene.
    public class TCoord : UdonSharpBehaviour
    {
        public string[] failures = new string[128];
        public int failCount;
        public int total;
        public bool done;

        public Transform child;   // Unity local position (1, 0, 2)
        public Transform camGO;   // GameObject with a Camera, rotated Euler(0, 90, 0)
        public Camera cam;        // the Camera component (unidot: child node "Camera" with a half-turn)
        public Rigidbody body;    // Unity position (0, 1, 0)
        public Collider wall;     // static box of size 1 at Unity position (5, 0, 0)

        private void Check(bool ok, string what)
        {
            total++;
            if (!ok) { failures[failCount] = what; failCount++; }
        }

        private bool NearV(Vector3 a, Vector3 b) { return (a - b).magnitude < 0.01f; }
        private bool Near(float a, float b) { return Mathf.Abs(a - b) < 0.01f; }

        public void RunTests()
        {
            Check(NearV(transform.position, new Vector3(1, 2, 3)), "position reads back Unity numbers: " + transform.position);
            Check(NearV(child.localPosition, new Vector3(1, 0, 2)), "localPosition: " + child.localPosition);
            Check(NearV(child.position, new Vector3(2, 2, 5)), "child world position: " + child.position);
            Check(NearV(transform.forward, Vector3.forward) && NearV(transform.right, Vector3.right) && NearV(transform.up, Vector3.up), "identity axes");
            transform.rotation = Quaternion.Euler(0, 90, 0);
            Check(NearV(transform.forward, Vector3.right), "forward after Euler(0,90,0): " + transform.forward);
            Check(NearV(transform.right, Vector3.back), "right after Euler(0,90,0): " + transform.right);
            Check(Near(transform.eulerAngles.y, 90f), "eulerAngles.y: " + transform.eulerAngles.y);
            Check(Near(Quaternion.Angle(transform.rotation, Quaternion.Euler(0, 90, 0)), 0f), "rotation round trip");
            Check(NearV(child.position, new Vector3(3, 2, 2)), "child world position after parent rotation: " + child.position);
            Check(NearV(transform.TransformPoint(new Vector3(0, 0, 1)), new Vector3(2, 2, 3)), "TransformPoint: " + transform.TransformPoint(new Vector3(0, 0, 1)));
            Check(NearV(transform.InverseTransformPoint(new Vector3(2, 2, 3)), new Vector3(0, 0, 1)), "InverseTransformPoint");
            Check(NearV(transform.TransformDirection(Vector3.forward), Vector3.right), "TransformDirection");
            Check(NearV(transform.InverseTransformDirection(Vector3.right), Vector3.forward), "InverseTransformDirection");
            transform.Rotate(0, -90, 0);
            Check(NearV(transform.forward, Vector3.forward), "Rotate back: " + transform.forward);
            transform.LookAt(transform.position + Vector3.left);
            Check(NearV(transform.forward, Vector3.left), "LookAt left: " + transform.forward);
            transform.localRotation = Quaternion.Euler(0, 0, 90);
            Check(NearV(transform.up, Vector3.left), "roll 90 about Z: up becomes left: " + transform.up);
            transform.rotation = Quaternion.identity;
            transform.localScale = new Vector3(2, 1, 1);
            Check(NearV(transform.lossyScale, new Vector3(2, 1, 1)) && NearV(transform.TransformVector(Vector3.right), new Vector3(2, 0, 0)), "scale is not mirrored");
            transform.localScale = Vector3.one;

            // camera: the component's transform is the GameObject's transform
            Check(NearV(camGO.forward, Vector3.right), "camera GameObject forward (Euler 0,90,0): " + camGO.forward);
            Check(NearV(cam.transform.forward, Vector3.right), "Camera.transform.forward matches its GameObject: " + cam.transform.forward);
            Check(Near(Quaternion.Angle(cam.transform.rotation, Quaternion.Euler(0, 90, 0)), 0f), "Camera.transform.rotation: " + cam.transform.rotation.eulerAngles);
            Vector3 sp = cam.WorldToScreenPoint(camGO.position + camGO.forward * 5f);
            Check(sp.z > 4.9f && sp.z < 5.1f, "WorldToScreenPoint depth along camera forward: " + sp.z);
            Ray r = cam.ScreenPointToRay(new Vector3(Screen.width / 2f, Screen.height / 2f, 0));
            Check(NearV(r.direction, Vector3.right), "ScreenPointToRay centre points along forward: " + r.direction);
            cam.transform.rotation = Quaternion.Euler(0, 180, 0);
            Check(NearV(cam.transform.forward, Vector3.back), "setting a camera rotation keeps Unity semantics: " + cam.transform.forward);
            cam.transform.rotation = Quaternion.Euler(0, 90, 0);

            // physics
            RaycastHit hit;
            Check(Physics.Raycast(new Vector3(0, 0, 0), Vector3.right, out hit, 100f), "raycast +X hits the wall");
            Check(Near(hit.point.x, 4.5f) && Near(hit.normal.x, -1f), "hit point/normal in Unity numbers: " + hit.point + " " + hit.normal);
            Check(hit.collider == wall, "hit collider is the wall");
            Check(!Physics.Raycast(Vector3.zero, Vector3.left, 100f), "raycast -X misses");
            Check(Physics.OverlapSphere(new Vector3(5, 0, 0), 0.1f).Length == 1, "OverlapSphere at the wall's Unity position");
            Bounds wb = wall.bounds;
            Check(Near(wb.center.x, 5f) && Near(wb.size.x, 1f), "collider bounds: " + wb.center + " " + wb.size);
            Check(NearV(body.position, new Vector3(0, 1, 0)), "rigidbody position: " + body.position);
            body.velocity = new Vector3(3, 0, 0);
            Check(NearV(body.velocity, new Vector3(3, 0, 0)), "velocity round trip: " + body.velocity);
            body.angularVelocity = new Vector3(0, 2, 0);
            Check(NearV(body.angularVelocity, new Vector3(0, 2, 0)), "angular velocity round trip: " + body.angularVelocity);
            body.velocity = Vector3.zero;
            body.angularVelocity = Vector3.zero;
            Check(Physics.gravity.y < 0f && Near(Physics.gravity.x, 0f), "gravity: " + Physics.gravity);
            Check(NearV(Vector3.Cross(Vector3.right, Vector3.up), Vector3.forward), "cross product uses Unity numbers");
            transform.position = new Vector3(1, 2, 3);
            done = true;
        }
    }
}
