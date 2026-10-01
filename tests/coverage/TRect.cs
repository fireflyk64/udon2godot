using UdonSharp;
using UnityEngine;
using UnityEngine.UI;

namespace Coverage
{
    /// RectTransform and layout components driven from a script. The runner builds a world canvas
    /// the way the scene importer does (unidot's rect_transform.gd): canvas 400 x 200 at Unity
    /// (1, 1, 2), scale 0.01; `panel` 200 x 100 in its centre with `child` 40 x 20 at (20, 10);
    /// `list` 100 x 200 with a VerticalLayoutGroup (padding 4, spacing 2, width controlled and
    /// expanded) over `itemA` (height 20) and `itemB` (height 30, LayoutElement); `spot`, a plain
    /// Transform at (3, 0.5, -1) turned 90 degrees about y. Every expected number is Unity's.
    public class TRect : UdonSharpBehaviour
    {
        public string[] failures = new string[128];
        public int failCount;
        public int total;
        public bool done;

        public Transform canvas;
        public RectTransform panel;
        public RectTransform child;
        public RectTransform list;
        public RectTransform itemA;
        public RectTransform itemB;
        public RectTransform mover;
        public Transform spot;

        private void Check(bool ok, string what)
        {
            total++;
            if (!ok) { failures[failCount] = what; failCount++; }
        }

        private bool Near(float a, float b) { return Mathf.Abs(a - b) < 0.01f; }
        private bool Near2(Vector2 a, float x, float y) { return Near(a.x, x) && Near(a.y, y); }
        private bool Near3(Vector3 a, float x, float y, float z) { return Mathf.Abs(a.x - x) < 0.002f && Mathf.Abs(a.y - y) < 0.002f && Mathf.Abs(a.z - z) < 0.002f; }

        public void RunTests()
        {
            // what the importer set is what a script reads
            Check(Near2(child.anchoredPosition, 20f, 10f), "anchoredPosition as imported: " + child.anchoredPosition);
            Check(Near2(child.sizeDelta, 40f, 20f), "sizeDelta as imported: " + child.sizeDelta);
            Check(Near2(child.anchorMin, 0.5f, 0.5f) && Near2(child.anchorMax, 0.5f, 0.5f), "anchors as imported");
            Check(Near2(child.pivot, 0.5f, 0.5f), "pivot as imported");
            Rect r = child.rect;
            Check(Near(r.xMin, -20f) && Near(r.yMin, -10f) && Near(r.width, 40f) && Near(r.height, 20f), "rect is in the rect's own space: " + r);
            Check(Near3(child.localPosition, 20f, 10f, 0f), "localPosition is the pivot in the parent: " + child.localPosition);
            Check(Near3(child.position, 1.2f, 1.1f, 2f), "world position through the canvas: " + child.position);
            Check(Near3(child.lossyScale, 0.01f, 0.01f, 0.01f), "lossyScale: " + child.lossyScale);
            Check(Near3(panel.position, 1f, 1f, 2f), "panel world position: " + panel.position);

            // hierarchy: the canvas's viewport and root control are not objects of their own
            Check(child.parent == panel, "parent of a control");
            Check(panel.parent == canvas, "parent of a canvas child is the canvas");
            Check(canvas.childCount == 3 && canvas.GetChild(0) == panel, "canvas children: " + canvas.childCount);
            Check(canvas.Find("Panel/Child") == child, "Find through the canvas");
            Check(child.GetSiblingIndex() == 0 && list.GetSiblingIndex() == 1, "sibling index: " + list.GetSiblingIndex());
            Check(child.IsChildOf(canvas), "IsChildOf through the canvas");

            // setters: Unity's rules
            child.anchoredPosition = new Vector2(-30f, 40f);
            Check(Near3(child.localPosition, -30f, 40f, 0f), "anchoredPosition setter moves the pivot: " + child.localPosition);
            child.sizeDelta = new Vector2(80f, 40f);
            Check(Near(child.rect.width, 80f) && Near(child.rect.height, 40f) && Near3(child.localPosition, -30f, 40f, 0f), "sizeDelta grows around the pivot");
            child.pivot = new Vector2(0f, 0f);
            Check(Near2(child.anchoredPosition, -30f, 40f) && Near(child.rect.xMin, 0f), "pivot setter keeps anchoredPosition, the rect moves: " + child.rect);
            child.anchorMin = new Vector2(0f, 0f);
            child.anchorMax = new Vector2(1f, 1f);
            // stretched: the size is the parent's plus sizeDelta
            Check(Near(child.rect.width, 280f) && Near(child.rect.height, 140f), "stretched anchors add the parent size: " + child.rect);
            child.offsetMin = new Vector2(10f, 20f);
            child.offsetMax = new Vector2(-30f, -40f);
            Check(Near(child.rect.width, 160f) && Near(child.rect.height, 40f), "offsetMin / offsetMax insets: " + child.rect);
            Check(Near2(child.sizeDelta, -40f, -60f) && Near2(child.offsetMin, 10f, 20f) && Near2(child.offsetMax, -30f, -40f), "offsets round trip: " + child.sizeDelta);
            child.SetSizeWithCurrentAnchors(RectTransform.Axis.Horizontal, 50f);
            child.SetSizeWithCurrentAnchors(RectTransform.Axis.Vertical, 30f);
            Check(Near(child.rect.width, 50f) && Near(child.rect.height, 30f) && Near(child.sizeDelta.x, -150f), "SetSizeWithCurrentAnchors: " + child.sizeDelta);
            child.SetInsetAndSizeFromParentEdge(RectTransform.Edge.Left, 15f, 60f);
            child.SetInsetAndSizeFromParentEdge(RectTransform.Edge.Top, 25f, 40f);
            Check(Near2(child.anchorMin, 0f, 1f) && Near2(child.anchorMax, 0f, 1f) && Near(child.rect.width, 60f) && Near(child.rect.height, 40f), "SetInsetAndSizeFromParentEdge: " + child.rect);
            // pivot (0, 0): 15 from the left edge of a 200 wide parent whose pivot is its centre
            Check(Near3(child.localPosition, -85f, -15f, 0f), "... places the pivot: " + child.localPosition);
            Vector3[] corners = new Vector3[4];
            child.GetLocalCorners(corners);
            Check(Near3(corners[0], 0f, 0f, 0f) && Near3(corners[2], 60f, 40f, 0f), "GetLocalCorners: " + corners[2]);
            child.GetWorldCorners(corners);
            Check(Near3(corners[0], 0.15f, 0.85f, 2f) && Near3(corners[2], 0.75f, 1.25f, 2f), "GetWorldCorners: " + corners[0] + " " + corners[2]);
            child.localPosition = new Vector3(0f, 0f, 0f);
            Check(Near2(child.anchorMin, 0f, 1f) && Near3(child.localPosition, 0f, 0f, 0f), "localPosition setter keeps the anchors");
            child.localScale = new Vector3(2f, 2f, 1f);
            Check(Near3(child.lossyScale, 0.02f, 0.02f, 0.01f), "localScale: " + child.lossyScale);
            child.localEulerAngles = new Vector3(0f, 0f, 90f);
            Check(Near(child.localEulerAngles.z, 90f), "localEulerAngles: " + child.localEulerAngles);
            // the rect's +x now points up: its bottom-right corner is 60 * 2 units above the pivot
            child.GetWorldCorners(corners);
            Check(Near3(corners[3], 1f, 2.2f, 2f), "rotated and scaled world corner: " + corners[3]);
            child.position = new Vector3(1.5f, 1.25f, 2f);
            Check(Near3(child.localPosition, 50f, 25f, 0f), "world position setter in the canvas plane: " + child.localPosition);

            // layout: the group placed the items as Unity does (anchors to the top-left)
            Check(Near2(itemA.anchorMin, 0f, 1f) && Near2(itemA.anchoredPosition, 50f, -14f) && Near2(itemA.sizeDelta, 92f, 20f), "vertical group places the first item: " + itemA.anchoredPosition + " " + itemA.sizeDelta);
            Check(Near2(itemB.anchoredPosition, 50f, -41f), "... and the second: " + itemB.anchoredPosition);
            VerticalLayoutGroup vg = list.GetComponent<VerticalLayoutGroup>();
            Check(vg != null && list.GetComponent<HorizontalLayoutGroup>() == null, "GetComponent finds the group by its kind");
            Check(Near(vg.spacing, 2f) && vg.padding.top == 4 && vg.childControlWidth && !vg.childControlHeight, "group settings as imported");
            Check(Near(LayoutUtility.GetPreferredHeight(list), 60f), "LayoutUtility.GetPreferredHeight: " + LayoutUtility.GetPreferredHeight(list));
            vg.spacing = 10f;
            LayoutRebuilder.ForceRebuildLayoutImmediate(list);
            Check(Near2(itemB.anchoredPosition, 50f, -49f), "spacing changed and rebuilt at once: " + itemB.anchoredPosition);
            vg.padding.top = 14;
            vg.childAlignment = TextAnchor.LowerCenter;
            LayoutRebuilder.ForceRebuildLayoutImmediate(list);
            // preferred height 14 + 4 + 20 + 30 + 10 = 78 in 200: the block sits at the bottom
            Check(Near2(itemA.anchoredPosition, 50f, -146f), "padding and alignment: " + itemA.anchoredPosition);
            LayoutElement le = itemB.GetComponent<LayoutElement>();
            Check(le != null && itemA.GetComponent<LayoutElement>() == null, "LayoutElement only where there is one");
            vg.childControlHeight = true;
            vg.childForceExpandHeight = false;
            le.preferredHeight = 50f;
            LayoutRebuilder.ForceRebuildLayoutImmediate(list);
            // itemA has no layout element: controlled, it gets its preferred height (0)
            Check(Near(itemB.rect.height, 50f) && Near(itemA.rect.height, 0f), "controlled heights come from the layout elements: " + itemA.rect.height + " " + itemB.rect.height);
            // a disabled group stops placing its children; the object stays active
            vg.enabled = false;
            itemA.anchoredPosition = new Vector2(7f, -7f);
            LayoutRebuilder.ForceRebuildLayoutImmediate(list);
            Check(!vg.enabled && list.gameObject.activeSelf && Near2(itemA.anchoredPosition, 7f, -7f), "a disabled layout group leaves its children alone: " + itemA.anchoredPosition);
            vg.enabled = true;
            LayoutRebuilder.ForceRebuildLayoutImmediate(list);
            Check(vg.enabled && Near(itemA.anchoredPosition.x, 50f), "enabled again it places them: " + itemA.anchoredPosition);
            ContentSizeFitter fitter = list.GetComponent<ContentSizeFitter>();
            fitter.verticalFit = ContentSizeFitter.FitMode.PreferredSize;
            LayoutRebuilder.ForceRebuildLayoutImmediate(list);
            Check(Near(list.rect.height, 78f), "ContentSizeFitter fits the list to its content: " + list.rect.height);

            // a UI element put on a 3D spot (position and rotation of a plain Transform): readable at once
            mover.position = spot.position;
            mover.rotation = spot.rotation;
            Check(Near3(mover.position, 3f, 0.5f, -1f), "world position of a rect moved out of its canvas: " + mover.position);
            Check(Quaternion.Angle(mover.rotation, spot.rotation) < 0.1f, "world rotation of a rect moved out of its canvas");
            // SetParent keeps either the local values or the world placement
            Vector2 before = itemA.anchoredPosition;
            itemA.SetParent(panel, false);
            Check(itemA.parent == panel && Near2(itemA.anchoredPosition, before.x, before.y), "SetParent(false) keeps the local values");
            Vector3 world = itemB.position;
            itemB.SetParent(panel, true);
            Check(itemB.parent == panel && Near3(itemB.position, world.x, world.y, world.z), "SetParent(true) keeps the world position: " + itemB.position);
            itemB.SetAsFirstSibling();
            Check(itemB.GetSiblingIndex() == 0 && panel.GetChild(0) == itemB, "SetAsFirstSibling");
            done = true;
        }

        /// A few frames later: what Unity does at the end of a frame has happened.
        public void AfterFrames()
        {
            // both items left the list: the fitted list shrank to its padding without being told to rebuild
            Check(list.childCount == 0 && Near(list.rect.height, 18f), "the list was rebuilt after its children left: " + list.rect.height);
            Check(Near3(mover.position, 3f, 0.5f, -1f), "the moved rect is still on its spot: " + mover.position);
            Check(mover.parent == canvas && canvas.childCount == 3, "... and still a child of the canvas: " + canvas.childCount);
            Check(Near3(itemB.lossyScale, 0.01f, 0.01f, 0.01f), "reparented item scale: " + itemB.lossyScale);
        }
    }
}
