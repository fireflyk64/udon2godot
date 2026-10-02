using UdonSharp;
using UnityEngine;

/// On an object whose m_IsActive an animation clip of its parent's Animator switches off after
/// a second: what the script sees of it (scenarios/fixture.gd reads the counters).
public class Lamp : UdonSharpBehaviour
{
    public int enabledCount;
    public int disabledCount;
    public int updates;
    public bool activeWhenDisabled = true;

    void OnEnable()
    {
        enabledCount++;
    }

    void OnDisable()
    {
        disabledCount++;
        activeWhenDisabled = gameObject.activeSelf;
    }

    void Update()
    {
        updates++;
    }
}
