using UdonSharp;
using UnityEngine;

namespace Coverage
{
    /// Transform, GameObject, components, hierarchy, instantiate/destroy.
    public class TTransform : UdonSharpBehaviour
    {
        public string[] failures = new string[128];
        public int failCount;
        public int total;
        public bool done;

        public Transform child;      // Node3D "Child" under the host, with a grandchild "GrandChild"
        public GameObject other;     // sibling Node3D "Other" (has a TTransform script too)
        public Rigidbody body;       // RigidBody3D "Body"
        public MeshRenderer meshObj; // MeshInstance3D "Mesh"
        public GameObject spawnedRef;

        private void Check(bool ok, string what)
        {
            total++;
            if (!ok) { failures[failCount] = what; failCount++; }
        }

        private bool NearV(Vector3 a, Vector3 b) { return (a - b).magnitude < 0.01f; }
        private bool Near(float a, float b) { return Mathf.Abs(a - b) < 0.01f; }

        public void RunTests()
        {
            transform.position = new Vector3(1, 2, 3);
            transform.rotation = Quaternion.identity;
            transform.localScale = Vector3.one;
            Check(NearV(transform.position, new Vector3(1, 2, 3)), "position set/get");
            Check(NearV(transform.localPosition, new Vector3(1, 2, 3)), "localPosition equals position at root");
            transform.rotation = Quaternion.Euler(0, 90, 0);
            Check(NearV(transform.forward, Vector3.right), "forward after Euler(0,90,0) (Unity axes): " + transform.forward);
            Check(NearV(transform.right, Vector3.back), "right after rotation");
            Check(NearV(transform.up, Vector3.up), "up unchanged");
            Check(Near(transform.eulerAngles.y, 90f), "eulerAngles.y: " + transform.eulerAngles.y);
            Check(Near(transform.localEulerAngles.y, 90f), "localEulerAngles");
            Vector3 wp = transform.TransformPoint(new Vector3(0, 0, 1));
            Check(NearV(wp, new Vector3(2, 2, 3)), "TransformPoint: " + wp);
            Check(NearV(transform.InverseTransformPoint(wp), new Vector3(0, 0, 1)), "InverseTransformPoint");
            Check(NearV(transform.TransformDirection(Vector3.forward), Vector3.right), "TransformDirection");
            Check(NearV(transform.InverseTransformDirection(Vector3.right), Vector3.forward), "InverseTransformDirection");
            transform.localScale = new Vector3(2, 2, 2);
            Check(NearV(transform.TransformVector(Vector3.forward), Vector3.right * 2f), "TransformVector scales");
            Check(NearV(transform.TransformDirection(Vector3.forward), Vector3.right), "TransformDirection ignores scale");
            Check(NearV(transform.lossyScale, new Vector3(2, 2, 2)), "lossyScale");
            transform.localScale = Vector3.one;
            transform.rotation = Quaternion.identity;
            transform.Rotate(0, 90, 0);
            Check(NearV(transform.forward, Vector3.right), "Rotate(0,90,0)");
            transform.Rotate(Vector3.up, -90f);
            Check(NearV(transform.forward, Vector3.forward), "Rotate(axis, angle)");
            transform.Translate(0, 0, 1);
            Check(NearV(transform.position, new Vector3(1, 2, 4)), "Translate local");
            transform.Translate(Vector3.up, Space.World);
            Check(NearV(transform.position, new Vector3(1, 3, 4)), "Translate world");
            transform.LookAt(transform.position + Vector3.right);
            Check(NearV(transform.forward, Vector3.right), "LookAt");
            transform.LookAt(transform.position + Vector3.forward);
            Check(NearV(transform.forward, Vector3.forward), "LookAt forward");
            transform.RotateAround(transform.position + Vector3.right, Vector3.up, 180f);
            Check(NearV(transform.position, new Vector3(3, 3, 4)), "RotateAround: " + transform.position);
            transform.SetPositionAndRotation(Vector3.zero, Quaternion.identity);
            Check(NearV(transform.position, Vector3.zero) && NearV(transform.forward, Vector3.forward), "SetPositionAndRotation");
            transform.localRotation = Quaternion.Euler(45, 0, 0);
            Check(Near(Quaternion.Angle(transform.localRotation, Quaternion.Euler(45, 0, 0)), 0f), "localRotation");
            transform.rotation = Quaternion.identity;

            // hierarchy
            Check(child != null && child.parent == transform, "child.parent is this transform");
            Check(transform.childCount >= 1, "childCount");
            Check(transform.GetChild(0) != null, "GetChild");
            Check(transform.Find("Child") == child, "Find by name");
            Check(child.Find("GrandChild") != null, "Find nested");
            Check(child.IsChildOf(transform) && !transform.IsChildOf(child), "IsChildOf");
            Check(child.root == transform || child.root != null, "root");
            child.localPosition = new Vector3(0, 1, 0);
            transform.position = new Vector3(5, 0, 0);
            Check(NearV(child.position, new Vector3(5, 1, 0)), "child world position follows parent");
            Transform gc = child.Find("GrandChild");
            gc.SetParent(transform, true);
            Check(gc.parent == transform, "SetParent(worldPositionStays)");
            gc.SetParent(child);
            Check(gc.parent == child, "SetParent back");
            Check(child.gameObject.name == "Child" && child.name == "Child", "name");
            child.name = "Renamed";
            Check(child.name == "Renamed", "rename");
            child.name = "Child";

            // GameObject
            GameObject go = gameObject;
            Check(go != null && go == this.gameObject && go.transform == transform, "gameObject/transform identity");
            Check(go.activeSelf && go.activeInHierarchy, "active by default");
            child.gameObject.SetActive(false);
            Check(!child.gameObject.activeSelf && !child.gameObject.activeInHierarchy, "SetActive(false)");
            child.gameObject.SetActive(true);
            Check(child.gameObject.activeSelf, "SetActive(true)");
            go.tag = "Player";
            Check(go.CompareTag("Player") && go.tag == "Player", "tag/CompareTag");
            go.layer = 9;
            Check(go.layer == 9, "layer");
            Check(1 << go.layer == 512, "layer mask arithmetic");
            Check(LayerMask.NameToLayer("Player") == 9 && LayerMask.LayerToName(9) == "Player", "LayerMask names");
            int mask = LayerMask.GetMask("Player", "Default");
            Check((mask & (1 << 9)) != 0 && (mask & 1) != 0, "LayerMask.GetMask");
            Check(GameObject.Find("Other") == other, "GameObject.Find");
            GameObject found = GameObject.Find("Child/GrandChild");
            Check(found != null && found.transform.parent == child, "GameObject.Find with a path below the name");
            Check(GameObject.Find("NoSuchObject") == null, "GameObject.Find of a name that is not there");
            child.gameObject.SetActive(false);
            Check(GameObject.Find("Child") == null && GameObject.Find("GrandChild") == null, "GameObject.Find sees active objects only");
            child.gameObject.SetActive(true);
            Check(GameObject.Find("GrandChild") == found, "... and finds them again once active");
            Check(GameObject.FindGameObjectWithTag("Player") == go, "FindGameObjectWithTag");

            // components
            Rigidbody rb = body.GetComponent<Rigidbody>();
            Check(rb == body, "GetComponent<Rigidbody> on rigidbody node");
            Check(GetComponent<Rigidbody>() == null, "GetComponent<Rigidbody> on plain node is null");
            Check(GetComponentInChildren<Rigidbody>() == body, "GetComponentInChildren<Rigidbody>");
            Rigidbody[] rbs = GetComponentsInChildren<Rigidbody>();
            Check(rbs.Length == 1 && rbs[0] == body, "GetComponentsInChildren");
            Check(body.GetComponentInParent<TTransform>() == this, "GetComponentInParent<UdonBehaviour>");
            TTransform o2 = other.GetComponent<TTransform>();
            Check(o2 != null && o2 != this, "GetComponent<user class> on other");
            UdonSharpBehaviour ub = other.GetComponent<UdonSharpBehaviour>();
            Check(ub != null, "GetComponent<UdonSharpBehaviour>");
            Check(GetComponent(typeof(Rigidbody)) == null && body.GetComponent(typeof(Rigidbody)) == body, "GetComponent(typeof)");
            Check(meshObj.GetComponent<MeshRenderer>() == meshObj, "MeshRenderer component");
            Check(body.transform == body.gameObject.transform, "component.transform/gameObject");
            Check(body.name == "Body", "component name");
            Collider bc = body.GetComponent<Collider>();
            bc.enabled = false;
            Check(bc.enabled == false, "Collider.enabled roundtrip");
            bc.enabled = true;
            Check(Utilities_IsValid(body) && !Utilities_IsValid(null), "validity helper");

            // instantiate / destroy
            GameObject clone = Instantiate(child.gameObject);
            Check(clone != null && clone != child.gameObject, "Instantiate creates a new object");
            clone.name = "Clone";
            Check(clone.transform.parent == transform, "Instantiate keeps parent");
            spawnedRef = clone;
            Destroy(clone);
            done = true;
        }

        private bool Utilities_IsValid(Object o) { return VRC.SDKBase.Utilities.IsValid(o); }

        /// Called by the runner one frame later.
        public void AfterFrames()
        {
            Check(spawnedRef == null, "destroyed object compares equal to null");
            Check(!spawnedRef, "destroyed object is falsy");
            Check(transform.Find("Clone") == null, "destroyed object removed from hierarchy");
        }
    }
}
