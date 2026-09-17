using UdonSharp;
using UnityEngine;

/// Lives on the `Screen` child inside Holder.prefab. The scene's instance of the prefab overrides
/// both fields (a reference to an object of the scene and a value), the way EmyChess sets
/// `PiecePlacer.board` on its instances of AnarchyControls.prefab.
public class HolderScreen : UdonSharpBehaviour
{
    public Transform target;
    public int number = 1;
    public string label = "prefab";
}
