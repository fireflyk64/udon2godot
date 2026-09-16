using UdonSharp;
using UnityEngine;
using VRC.SDKBase;
using VRC.Udon;

/// A VRCStation on a box: counts the local player's seat events (scenarios/player.gd sits the
/// desktop player through the pointer and leaves with Space).
public class Chair : UdonSharpBehaviour
{
    public int entered;
    public int exited;
    public string lastPlayer = "";

    public override void OnStationEntered(VRCPlayerApi player)
    {
        entered++;
        lastPlayer = player == null ? "" : player.displayName;
    }

    public override void OnStationExited(VRCPlayerApi player)
    {
        exited++;
    }
}
