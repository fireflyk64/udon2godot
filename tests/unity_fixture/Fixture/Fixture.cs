using UdonSharp;
using UnityEngine;
using VRC.SDKBase;
using VRC.Udon;

/// End-to-end fixture: imported by scripts/import_world.sh (unidot + udon_integration) and checked
/// by scenarios/fixture.gd. Verifies transforms in UNIDOT coordinate mode, serialized references,
/// arrays, colliders/raycasts and a Button.onClick persistent call, all through the real pipeline.
public class Fixture : UdonSharpBehaviour
{
    public Transform target;
    public BoxCollider floorCollider;
    public GameObject[] targets;
    public string[] names;
    public float speed;
    public string label;
    public int pressed;
    public int checks;
    public int failures;
    public string log = "";

    private bool Near(float a, float b) { return Mathf.Abs(a - b) < 0.001f; }
    private bool NearV(Vector3 a, Vector3 b) { return (a - b).magnitude < 0.001f; }

    private void Check(bool ok, string what)
    {
        checks++;
        if (!ok)
        {
            failures++;
            log = log + "FAIL " + what + "\n";
            Debug.LogError("[fixture] FAIL " + what);
        }
        else
        {
            Debug.Log("[fixture] ok " + what);
        }
    }

    void Start()
    {
        Check(NearV(transform.position, new Vector3(1, 2, 3)), "position " + transform.position);
        Check(NearV(transform.forward, Vector3.right), "forward after 90 deg yaw " + transform.forward);
        Check(NearV(transform.right, Vector3.back), "right after 90 deg yaw " + transform.right);
        Check(Near(transform.eulerAngles.y, 90f), "eulerAngles.y " + transform.eulerAngles.y);
        Check(NearV(transform.TransformPoint(Vector3.forward), new Vector3(2, 2, 3)), "TransformPoint " + transform.TransformPoint(Vector3.forward));
        Check(target != null, "target reference bound");
        if (target != null)
        {
            Check(NearV(target.position, new Vector3(-2, 0.5f, 4)), "target position " + target.position);
            Check(NearV(transform.InverseTransformPoint(target.position), new Vector3(-1, -1.5f, -3)), "InverseTransformPoint " + transform.InverseTransformPoint(target.position));
            Check(Vector3.Dot(target.position - transform.position, transform.forward) < 0f, "target is behind the probe");
            Check(target.gameObject.name == "Target" && target.name == "Target", "target name");
        }
        Check(transform.childCount == 1, "childCount " + transform.childCount);
        if (transform.childCount == 1)
        {
            Check(NearV(transform.GetChild(0).position, new Vector3(1, 3, 3)), "child world position " + transform.GetChild(0).position);
            Check(transform.GetChild(0).name == "Marker" && transform.Find("Marker") != null, "Find child");
            Check(NearV(transform.GetChild(0).localPosition, new Vector3(0, 1, 0)), "child local position " + transform.GetChild(0).localPosition);
        }
        RaycastHit hit;
        bool rc = Physics.Raycast(new Vector3(0, 5, 0), Vector3.down, out hit, 100f);
        Check(rc && Near(hit.distance, 4.5f) && NearV(hit.normal, Vector3.up), "raycast floor: hit=" + rc + " dist=" + hit.distance + " n=" + hit.normal);
        Check(rc && hit.collider != null && hit.collider.gameObject.name == "Floor", "raycast collider name");
        Check(floorCollider != null, "collider reference bound");
        if (floorCollider != null)
        {
            Check(NearV(floorCollider.bounds.size, new Vector3(10, 1, 10)), "collider bounds " + floorCollider.bounds.size);
            Check(rc && floorCollider.gameObject == hit.collider.gameObject, "collider reference is the hit collider");
        }
        Check(names != null && names.Length == 3 && names[2] == "c", "string array");
        Check(targets != null && targets.Length == 2 && targets[1] != null && targets[1].name == "Target", "GameObject array");
        Check(Near(speed, 2.5f) && label == "hello", "float/string fields " + speed + " " + label);
        Check(gameObject.name == "Probe" && gameObject.activeSelf, "gameObject name/active");
        Check(GetComponent<Rigidbody>() == null, "no rigidbody on the probe");
        Text label = null;
        if (targets != null && targets.Length == 2 && targets[1] != null)
        {
            label = targets[1].transform.parent == null ? null : label;
        }
        Canvas cv = (Canvas)GameObject.Find("Canvas").GetComponent(typeof(Canvas));
        Check(cv != null, "Canvas found");
        if (cv != null)
        {
            label = cv.GetComponentInChildren<Text>();
            Check(label != null && label.text == "Go" && label.fontSize == 18, "imported uGUI Text " + (label == null ? "null" : label.text));
            if (label != null)
            {
                Outline ol = label.GetComponent<Outline>();
                Check(ol != null && Near(ol.effectColor.r, 1f) && Near(ol.effectColor.g, 1f) && Near(ol.effectColor.b, 0f) && Near(ol.effectDistance.x, 2f), "imported Outline effect");
            }
            CanvasGroup cg = cv.GetComponent<CanvasGroup>();
            Check(cg != null && Near(cg.alpha, 0.8f) && cg.interactable, "imported CanvasGroup alpha " + (cg == null ? "null" : cg.alpha.ToString()));
        }
        ParticleSystem fx = GetComponentInChildren<ParticleSystem>();
        Check(fx != null, "particle system imported under Marker");
        if (fx != null)
        {
            Check(Near(fx.main.startSize.constant, 0.3f), "imported startSize " + fx.main.startSize.constant);
            Check(fx.main.maxParticles == 100, "imported maxParticles " + fx.main.maxParticles);
            Check(!fx.main.loop, "imported loop=false");
            Check(Near(fx.main.startSpeed.constantMin, 2f) && Near(fx.main.startSpeed.constantMax, 4f), "imported startSpeed random between two constants");
            Check(Near(fx.emission.rateOverTime.constant, 12f), "imported rateOverTime " + fx.emission.rateOverTime.constant);
            Check(fx.shape.shapeType == ParticleSystemShapeType.Cone && Near(fx.shape.radius, 0.25f) && Near(fx.shape.angle, 20f), "imported shape " + fx.shape.shapeType + " " + fx.shape.radius);
            Check(fx.colorOverLifetime.enabled && fx.colorOverLifetime.color.mode == ParticleSystemGradientMode.Gradient, "imported colour over lifetime");
            Check(fx.noise.enabled && Near(fx.noise.strength.constant, 0.5f), "imported noise");
            Check(fx.main.startColor.color == new Color(1f, 0.5f, 0f, 1f), "imported startColor " + fx.main.startColor.color);
            Check(fx.isPlaying, "playOnAwake");
            Check(fx.gameObject.name == "Marker", "particle system's GameObject");
        }
    }

    public void OnPressed()
    {
        pressed++;
    }
}
