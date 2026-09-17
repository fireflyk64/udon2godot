using UdonSharp;
using UnityEngine;

/// An UdonSharp 0.x style behaviour: the scene has only its UdonBehaviour component (no C# proxy),
/// the field values are in the Udon variable table (`Legacy.vars.json` → tools/odin_encode.py).
public class Legacy : UdonSharpBehaviour
{
    public float speed;
    public int count;
    public bool flag;
    public string title;
    public Vector3 offset;
    public Color tint;
    public Transform target;
    public Transform[] targets;
    public float[] weights;
    public string[] names;
    public Transform missing;
    public VRC.SDKBase.VRCUrl link;
    public VRC.SDKBase.VRCUrl[] links;
}
