#!/usr/bin/env python3
"""Writes tests/unity_ui: a Unity asset folder with nothing but UI, for testing canvas and
RectTransform import without any scripting.

    tools/gen_ui_fixture.py [out_dir]        (default tests/unity_ui/UiCases)

The scene (`UiCases.unity`) holds one canvas per group of cases:

  Rects      anchors (point, stretched on one or both axes), pivots, offsets, scale, rotation
             about z, mirrored and non-uniform scale, zero-size parents, overflow, inactive nodes
  Spatial    nodes that leave the canvas plane: tilted about x / y, pushed along z, turned
             around; nested combinations; offsets small enough to stay flat
  Metres     a canvas in metres (scale 1) whose children are scaled-down pixel layouts, with
             widgets whose Godot counterparts have a minimum size (Button, InputField, Slider)
  Layouts    HorizontalLayoutGroup / VerticalLayoutGroup / GridLayoutGroup in every mode, with
             ContentSizeFitter, LayoutElement and AspectRatioFitter
  Nested     canvases inside canvases: in place, as prefab instances, coplanar and tilted
  Placed     a canvas with an off-centre pivot under rotated and scaled plain Transforms
  Screen*    screen-space canvases with each CanvasScaler mode
  prefab instances with RectTransform overrides (Card.prefab, Board.prefab)

Unity itself is not needed: tools/unity_ui_reference.py computes where Unity puts every rect
from these files, and the imported scene is compared with that (scripts/test_ui.sh).
"""
import hashlib
import math
import os
import sys

GUID = {
    "Image": "fe87c0e1cc204ed48ad3b37840f39efc",
    "Text": "5f7201a12d95ffc409449d95f23cf332",
    "Button": "4e29b1a8efbd4b44bb3f3716e73f07ff",
    "Toggle": "9085046f02f69544eb97fd06b6048fe2",
    "Slider": "67db9e8f0e2ae9c40bc1e2b64352a6b4",
    "InputField": "d199490a83bb2b844b9695cbf13b01ef",
    "CanvasScaler": "0cd44c1031e13a943bb63640046fad76",
    "GraphicRaycaster": "dc42784cf147c0c48a680349fa168899",
    "LayoutElement": "306cc8c2b49d7114eaa3623786fc2126",
    "HorizontalLayoutGroup": "30649d3a9faa99c48a7b1166b86bf2a0",
    "VerticalLayoutGroup": "59f8146938fff824cb5fd77236b75775",
    "GridLayoutGroup": "8a8695521f0d02e499659fee002a26c2",
    "ContentSizeFitter": "3245ec927659c4140ac4f8d17403cc18",
    "AspectRatioFitter": "86710e43de46f6f4bac7c8e50813a599",
    "Mask": "31a19414c41e5ae4aae2af33fee712f6",
}

SCENE_SETTINGS = """--- !u!29 &1
OcclusionCullingSettings:
  m_ObjectHideFlags: 0
  serializedVersion: 2
  m_OcclusionBakeSettings:
    smallestOccluder: 5
    smallestHole: 0.25
    backfaceThreshold: 100
  m_SceneGUID: 00000000000000000000000000000000
  m_OcclusionCullingData: {fileID: 0}
--- !u!104 &2
RenderSettings:
  m_ObjectHideFlags: 0
  serializedVersion: 9
  m_Fog: 0
  m_FogColor: {r: 0.5, g: 0.5, b: 0.5, a: 1}
  m_FogMode: 3
  m_FogDensity: 0.01
  m_LinearFogStart: 0
  m_LinearFogEnd: 300
  m_AmbientSkyColor: {r: 0.212, g: 0.227, b: 0.259, a: 1}
  m_AmbientEquatorColor: {r: 0.114, g: 0.125, b: 0.133, a: 1}
  m_AmbientGroundColor: {r: 0.047, g: 0.043, b: 0.035, a: 1}
  m_AmbientIntensity: 1
  m_AmbientMode: 0
  m_SubtractiveShadowColor: {r: 0.42, g: 0.478, b: 0.627, a: 1}
  m_SkyboxMaterial: {fileID: 10304, guid: 0000000000000000f000000000000000, type: 0}
  m_HaloStrength: 0.5
  m_FlareStrength: 1
  m_FlareFadeSpeed: 3
  m_HaloTexture: {fileID: 0}
  m_SpotCookie: {fileID: 10001, guid: 0000000000000000e000000000000000, type: 0}
  m_DefaultReflectionMode: 0
  m_DefaultReflectionResolution: 128
  m_ReflectionBounces: 1
  m_ReflectionIntensity: 1
  m_CustomReflection: {fileID: 0}
  m_Sun: {fileID: 0}
  m_IndirectSpecularColor: {r: 0, g: 0, b: 0, a: 1}
  m_UseRadianceAmbientProbe: 0
--- !u!157 &3
LightmapSettings:
  m_ObjectHideFlags: 0
  serializedVersion: 12
  m_GIWorkflowMode: 1
  m_GISettings:
    serializedVersion: 2
    m_BounceScale: 1
    m_IndirectOutputScale: 1
    m_AlbedoBoost: 1
    m_EnvironmentLightingMode: 0
    m_EnableBakedLightmaps: 0
    m_EnableRealtimeLightmaps: 0
  m_LightingDataAsset: {fileID: 0}
  m_LightingSettings: {fileID: 0}
--- !u!196 &4
NavMeshSettings:
  serializedVersion: 2
  m_ObjectHideFlags: 0
  m_BuildSettings:
    serializedVersion: 3
    agentTypeID: 0
    agentRadius: 0.5
    agentHeight: 2
    agentSlope: 45
    agentClimb: 0.4
    ledgeDropHeight: 0
    maxJumpAcrossDistance: 0
    minRegionArea: 2
    manualCellSize: 0
    cellSize: 0.16666667
    manualTileSize: 0
    tileSize: 256
    buildHeightMesh: 0
    maxJobWorkers: 0
    preserveTilesOutsideBounds: 0
    debug:
      m_Flags: 0
  m_NavMeshData: {fileID: 0}
"""


def num(v):
    if isinstance(v, bool):
        return "1" if v else "0"
    if isinstance(v, int):
        return str(v)
    r = repr(round(float(v), 7))
    return r[:-2] if r.endswith(".0") else r


def vec(v, keys):
    return "{" + ", ".join("%s: %s" % (k, num(x)) for k, x in zip(keys, v)) + "}"


def euler_to_quat(e):
    """Unity's Quaternion.Euler: z, then x, then y (degrees)."""
    x, y, z = (math.radians(a) * 0.5 for a in e)
    cx, sx, cy, sy, cz, sz = math.cos(x), math.sin(x), math.cos(y), math.sin(y), math.cos(z), math.sin(z)
    return (
        cy * sx * cz + sy * cx * sz,
        sy * cx * cz - cy * sx * sz,
        cy * cx * sz - sy * sx * cz,
        cy * cx * cz + sy * sx * sz,
    )


class Obj:
    def __init__(self, f, name):
        self.file = f
        self.name = name
        self.go = f.new_id()
        self.t = f.new_id()
        self.parent = None
        self.children = []       # Obj or Instance
        self.components = []     # (id, text)
        self.rect = None
        self.xform = {}
        self.active = True


class Instance:
    """A prefab instance: `t` is the id of the stripped root transform in the outer file."""

    def __init__(self, f, prefab, name, mods):
        self.file = f
        self.prefab = prefab
        self.name = name
        self.id = f.new_id()
        self.t = f.new_id()
        self.parent = None
        self.mods = mods          # [(target id in the prefab, property path, value)]
        self.added = []           # objects of the outer file parented to nodes of the instance


class UnityFile:
    def __init__(self, guid, first_id=100):
        self.guid = guid
        self._next = first_id
        self.objects = []
        self.instances = []
        self.stripped = {}        # (instance id, source id) → stripped id
        self.roots = []

    def new_id(self):
        """File ids like Unity's: large and spread out. An object inside a prefab instance is
        addressed by instance id XOR source id, which collides with ordinary ids when both are
        small sequential numbers."""
        self._next += 1
        digest = hashlib.md5(("%s:%d" % (self.guid, self._next)).encode()).digest()
        return (int.from_bytes(digest[:8], "big") & 0x3FFFFFFFFFFFFFFF) | (1 << 40)

    # ---- objects ----------------------------------------------------------------------------
    def node(self, name, parent=None, rect=None, comps=(), active=True, pos=(0, 0, 0), rot=(0, 0, 0), scale=(1, 1, 1)):
        """A GameObject. `rect` (a dict) makes it a RectTransform:
        amin, amax, pos (anchoredPosition), size (sizeDelta), pivot, z, rot (Euler), scale."""
        o = Obj(self, name)
        o.active = active
        o.rect = rect
        o.xform = {"pos": pos, "rot": rot, "scale": scale}
        self.objects.append(o)
        self._attach(o, parent)
        for c in comps:
            self.add(o, c)
        return o

    def _attach(self, child, parent):
        child.parent = parent
        if parent is None:
            self.roots.append(child)
        elif isinstance(parent, tuple):
            parent[0].added.append((parent[1], child))   # (instance, source transform id)
        else:
            parent.children.append(child)

    def add(self, o, comp):
        cid = self.new_id()
        kind, body = comp
        if kind == "Canvas":
            o.components.append((cid, 223, "Canvas", "  m_GameObject: {fileID: %d}\n  m_Enabled: 1\n%s" % (o.go, body)))
        elif kind == "CanvasRenderer":
            o.components.append((cid, 222, "CanvasRenderer", "  m_GameObject: {fileID: %d}\n  m_CullTransparentMesh: 1\n" % o.go))
        else:
            head = "  m_GameObject: {fileID: %d}\n  m_Enabled: 1\n  m_EditorHideFlags: 0\n  m_Script: {fileID: 11500000, guid: %s, type: 3}\n  m_Name: \n  m_EditorClassIdentifier: \n" % (o.go, GUID[kind])
            o.components.append((cid, 114, "MonoBehaviour", head + body))
        return cid

    def instance(self, prefab, parent, name, mods=()):
        """Instance of `prefab` (a UnityFile) under `parent`; mods: [(source id, path, value)]."""
        inst = Instance(self, prefab, name, list(mods))
        self.instances.append(inst)
        self._attach(inst, parent)
        return inst

    # ---- output -----------------------------------------------------------------------------
    def text(self, scene):
        out = ["%YAML 1.1", "%TAG !u! tag:unity3d.com,2011:"]
        body = SCENE_SETTINGS if scene else ""
        for o in self.objects:
            body += self._object(o)
        for inst in self.instances:
            body += self._instance(inst)
        return "\n".join(out) + "\n" + body

    def _child_ref(self, c):
        return c.t

    def _object(self, o):
        is_rect = o.rect is not None
        comp_ids = [o.t] + [c[0] for c in o.components]
        s = "--- !u!1 &%d\nGameObject:\n  m_ObjectHideFlags: 0\n  m_CorrespondingSourceObject: {fileID: 0}\n  m_PrefabInstance: {fileID: 0}\n  m_PrefabAsset: {fileID: 0}\n  serializedVersion: 6\n  m_Component:\n" % o.go
        for cid in comp_ids:
            s += "  - component: {fileID: %d}\n" % cid
        s += "  m_Layer: %d\n  m_Name: %s\n  m_TagString: Untagged\n  m_Icon: {fileID: 0}\n  m_NavMeshLayer: 0\n  m_StaticEditorFlags: 0\n  m_IsActive: %d\n" % (5 if is_rect else 0, o.name, 1 if o.active else 0)
        parent = o.parent
        father = 0
        order = 0
        if isinstance(parent, tuple):
            inst, source = parent
            father = self._stripped(inst, source, 224 if source in inst.prefab.rect_ids() else 4)
            order = [c for _s, c in inst.added if _s == source].index(o)
        elif parent is not None:
            father = parent.t
            order = parent.children.index(o)
        else:
            order = self.roots.index(o)
        if is_rect:
            r = o.rect
            q = euler_to_quat(r.get("rot", (0, 0, 0)))
            sc = r.get("scale", (1, 1, 1))
            if isinstance(sc, (int, float)):
                sc = (sc, sc, sc)
            s += "--- !u!224 &%d\nRectTransform:\n" % o.t
            s += "  m_ObjectHideFlags: 0\n  m_CorrespondingSourceObject: {fileID: 0}\n  m_PrefabInstance: {fileID: 0}\n  m_PrefabAsset: {fileID: 0}\n  m_GameObject: {fileID: %d}\n" % o.go
            s += "  m_LocalRotation: %s\n  m_LocalPosition: {x: 0, y: 0, z: %s}\n  m_LocalScale: %s\n  m_ConstrainProportionsScale: 0\n" % (vec(q, "xyzw"), num(r.get("z", 0)), vec(sc, "xyz"))
        else:
            q = euler_to_quat(o.xform["rot"])
            s += "--- !u!4 &%d\nTransform:\n" % o.t
            s += "  m_ObjectHideFlags: 0\n  m_CorrespondingSourceObject: {fileID: 0}\n  m_PrefabInstance: {fileID: 0}\n  m_PrefabAsset: {fileID: 0}\n  m_GameObject: {fileID: %d}\n" % o.go
            s += "  m_LocalRotation: %s\n  m_LocalPosition: %s\n  m_LocalScale: %s\n  m_ConstrainProportionsScale: 0\n" % (vec(q, "xyzw"), vec(o.xform["pos"], "xyz"), vec(o.xform["scale"], "xyz"))
        if o.children:
            s += "  m_Children:\n"
            for c in o.children:
                s += "  - {fileID: %d}\n" % c.t
        else:
            s += "  m_Children: []\n"
        s += "  m_Father: {fileID: %d}\n  m_RootOrder: %d\n  m_LocalEulerAnglesHint: {x: 0, y: 0, z: 0}\n" % (father, order)
        if is_rect:
            r = o.rect
            s += "  m_AnchorMin: %s\n  m_AnchorMax: %s\n  m_AnchoredPosition: %s\n  m_SizeDelta: %s\n  m_Pivot: %s\n" % (
                vec(r.get("amin", (0.5, 0.5)), "xy"), vec(r.get("amax", (0.5, 0.5)), "xy"), vec(r.get("pos", (0, 0)), "xy"),
                vec(r.get("size", (100, 100)), "xy"), vec(r.get("pivot", (0.5, 0.5)), "xy"))
        for cid, utype, kind, body in o.components:
            s += "--- !u!%d &%d\n%s:\n  m_ObjectHideFlags: 0\n  m_CorrespondingSourceObject: {fileID: 0}\n  m_PrefabInstance: {fileID: 0}\n  m_PrefabAsset: {fileID: 0}\n%s" % (utype, cid, kind, body)
        return s

    def rect_ids(self):
        return {o.t for o in self.objects if o.rect is not None}

    def root(self):
        return self.roots[0]

    def _stripped(self, inst, source, utype):
        key = (inst.id, source)
        if key not in self.stripped:
            self.stripped[key] = inst.t if source == inst.prefab.root().t else self.new_id()
        return self.stripped[key]

    def _instance(self, inst):
        prefab = inst.prefab
        root = prefab.root()
        parent = inst.parent
        father = 0
        order = 0
        if isinstance(parent, tuple):
            father = self._stripped(parent[0], parent[1], 224)
        elif parent is not None:
            father = parent.t
            order = parent.children.index(inst)
        else:
            order = self.roots.index(inst)
        # Unity records the root's transform values on every instance, changed or not
        mods = [(root.go, "m_Name", inst.name), (root.t, "m_RootOrder", order)]
        given = {(t, path) for t, path, _v in inst.mods}
        if root.rect is not None:
            r = root.rect
            q = euler_to_quat(r.get("rot", (0, 0, 0)))
            defaults = [("m_Pivot.x", r.get("pivot", (0.5, 0.5))[0]), ("m_Pivot.y", r.get("pivot", (0.5, 0.5))[1]),
                        ("m_AnchorMax.x", r.get("amax", (0.5, 0.5))[0]), ("m_AnchorMax.y", r.get("amax", (0.5, 0.5))[1]),
                        ("m_AnchorMin.x", r.get("amin", (0.5, 0.5))[0]), ("m_AnchorMin.y", r.get("amin", (0.5, 0.5))[1]),
                        ("m_SizeDelta.x", r.get("size", (100, 100))[0]), ("m_SizeDelta.y", r.get("size", (100, 100))[1]),
                        ("m_LocalPosition.x", 0), ("m_LocalPosition.y", 0), ("m_LocalPosition.z", r.get("z", 0)),
                        ("m_LocalRotation.w", q[3]), ("m_LocalRotation.x", q[0]), ("m_LocalRotation.y", q[1]), ("m_LocalRotation.z", q[2]),
                        ("m_AnchoredPosition.x", r.get("pos", (0, 0))[0]), ("m_AnchoredPosition.y", r.get("pos", (0, 0))[1])]
            mods += [(root.t, path, value) for path, value in defaults if (root.t, path) not in given]
        mods += inst.mods
        s = "--- !u!1001 &%d\nPrefabInstance:\n  m_ObjectHideFlags: 0\n  serializedVersion: 2\n  m_Modification:\n    serializedVersion: 3\n    m_TransformParent: {fileID: %d}\n    m_Modifications:\n" % (inst.id, father)
        for target, path, value in mods:
            s += "    - target: {fileID: %d, guid: %s, type: 3}\n      propertyPath: %s\n      value: %s\n      objectReference: {fileID: 0}\n" % (target, prefab.guid, path, value if isinstance(value, str) else num(value))
        s += "    m_RemovedComponents: []\n  m_SourcePrefab: {fileID: 100100000, guid: %s, type: 3}\n" % prefab.guid
        self.stripped[(inst.id, root.t)] = inst.t
        for (iid, source), sid in list(self.stripped.items()):
            if iid != inst.id:
                continue
            is_rect = source in prefab.rect_ids()
            s += "--- !u!%d &%d stripped\n%s:\n  m_CorrespondingSourceObject: {fileID: %d, guid: %s, type: 3}\n  m_PrefabInstance: {fileID: %d}\n  m_PrefabAsset: {fileID: 0}\n" % (
                224 if is_rect else 4, sid, "RectTransform" if is_rect else "Transform", source, prefab.guid, inst.id)
        return s


# ---- components ---------------------------------------------------------------------------------

def canvas(mode=2, order=0):
    return ("Canvas", "  serializedVersion: 3\n  m_RenderMode: %d\n  m_Camera: {fileID: 0}\n  m_PlaneDistance: 100\n  m_PixelPerfect: 0\n  m_ReceivesEvents: 1\n  m_OverrideSorting: 0\n  m_OverridePixelPerfect: 0\n  m_SortingBucketNormalizedSize: 0\n  m_VertexColorAlwaysGammaSpace: 0\n  m_AdditionalShaderChannelsFlag: 25\n  m_UpdateRectTransformForStandalone: 0\n  m_SortingLayerID: 0\n  m_SortingOrder: %d\n  m_TargetDisplay: 0\n" % (mode, order))


def scaler(mode=0, factor=1, ref=(800, 600), match_mode=0, match=0):
    return ("CanvasScaler", "  m_UiScaleMode: %d\n  m_ReferencePixelsPerUnit: 100\n  m_ScaleFactor: %s\n  m_ReferenceResolution: %s\n  m_ScreenMatchMode: %d\n  m_MatchWidthOrHeight: %s\n  m_PhysicalUnit: 3\n  m_FallbackScreenDPI: 96\n  m_DefaultSpriteDPI: 96\n  m_DynamicPixelsPerUnit: 1\n  m_PresetInfoIsWorld: 0\n" % (mode, num(factor), vec(ref, "xy"), match_mode, num(match)))


def raycaster():
    return ("GraphicRaycaster", "  m_IgnoreReversedGraphics: 1\n  m_BlockingObjects: 0\n  m_BlockingMask:\n    serializedVersion: 2\n    m_Bits: 4294967295\n")


def renderer():
    return ("CanvasRenderer", "")


_GRAPHIC = "  m_Material: {fileID: 0}\n  m_Color: %s\n  m_RaycastTarget: 1\n  m_RaycastPadding: {x: 0, y: 0, z: 0, w: 0}\n  m_Maskable: 1\n  m_OnCullStateChanged:\n    m_PersistentCalls:\n      m_Calls: []\n"


def image(color=(1, 1, 1, 1)):
    return ("Image", _GRAPHIC % vec(color, "rgba") + "  m_Sprite: {fileID: 0}\n  m_Type: 0\n  m_PreserveAspect: 0\n  m_FillCenter: 1\n  m_FillMethod: 4\n  m_FillAmount: 1\n  m_FillClockwise: 1\n  m_FillOrigin: 0\n  m_UseSpriteMesh: 0\n  m_PixelsPerUnitMultiplier: 1\n")


def text(value, size=14, color=(0, 0, 0, 1), align=4):
    return ("Text", _GRAPHIC % vec(color, "rgba") + "  m_FontData:\n    m_Font: {fileID: 10102, guid: 0000000000000000e000000000000000, type: 0}\n    m_FontSize: %d\n    m_FontStyle: 0\n    m_BestFit: 0\n    m_MinSize: 1\n    m_MaxSize: 40\n    m_Alignment: %d\n    m_AlignByGeometry: 0\n    m_RichText: 1\n    m_HorizontalOverflow: 0\n    m_VerticalOverflow: 0\n    m_LineSpacing: 1\n  m_Text: %s\n" % (size, align, value))


_SELECTABLE = "  m_Navigation:\n    m_Mode: 3\n    m_WrapAround: 0\n    m_SelectOnUp: {fileID: 0}\n    m_SelectOnDown: {fileID: 0}\n    m_SelectOnLeft: {fileID: 0}\n    m_SelectOnRight: {fileID: 0}\n  m_Transition: 1\n  m_Colors:\n    m_NormalColor: {r: 1, g: 1, b: 1, a: 1}\n    m_HighlightedColor: {r: 0.96, g: 0.96, b: 0.96, a: 1}\n    m_PressedColor: {r: 0.78, g: 0.78, b: 0.78, a: 1}\n    m_SelectedColor: {r: 0.96, g: 0.96, b: 0.96, a: 1}\n    m_DisabledColor: {r: 0.78, g: 0.78, b: 0.78, a: 0.5}\n    m_ColorMultiplier: 1\n    m_FadeDuration: 0.1\n  m_Interactable: 1\n  m_TargetGraphic: {fileID: 0}\n"


def button():
    return ("Button", _SELECTABLE + "  m_OnClick:\n    m_PersistentCalls:\n      m_Calls: []\n")


def toggle(on=False):
    return ("Toggle", _SELECTABLE + "  toggleTransition: 1\n  graphic: {fileID: 0}\n  m_Group: {fileID: 0}\n  onValueChanged:\n    m_PersistentCalls:\n      m_Calls: []\n  m_IsOn: %d\n" % (1 if on else 0))


def slider(value=0.5, direction=0):
    return ("Slider", _SELECTABLE + "  m_FillRect: {fileID: 0}\n  m_HandleRect: {fileID: 0}\n  m_Direction: %d\n  m_MinValue: 0\n  m_MaxValue: 1\n  m_WholeNumbers: 0\n  m_Value: %s\n  m_OnValueChanged:\n    m_PersistentCalls:\n      m_Calls: []\n" % (direction, num(value)))


def input_field(value=""):
    return ("InputField", _SELECTABLE + "  m_TextComponent: {fileID: 0}\n  m_Placeholder: {fileID: 0}\n  m_ContentType: 0\n  m_InputType: 0\n  m_AsteriskChar: 42\n  m_KeyboardType: 0\n  m_LineType: 0\n  m_HideMobileInput: 0\n  m_CharacterValidation: 0\n  m_CharacterLimit: 0\n  m_OnSubmit:\n    m_PersistentCalls:\n      m_Calls: []\n  m_OnDidEndEdit:\n    m_PersistentCalls:\n      m_Calls: []\n  m_OnValueChanged:\n    m_PersistentCalls:\n      m_Calls: []\n  m_CaretColor: {r: 0.2, g: 0.2, b: 0.2, a: 1}\n  m_CustomCaretColor: 0\n  m_SelectionColor: {r: 0.66, g: 0.81, b: 1, a: 0.75}\n  m_Text: %s\n  m_CaretBlinkRate: 0.85\n  m_CaretWidth: 1\n  m_ReadOnly: 0\n  m_ShouldActivateOnSelect: 1\n" % value)


def _padding(p):
    return "  m_Padding:\n    m_Left: %d\n    m_Right: %d\n    m_Top: %d\n    m_Bottom: %d\n" % tuple(p)


def linear(kind, padding=(0, 0, 0, 0), spacing=0, align=0, control=(False, False), expand=(False, False), scale=(False, False), reverse=False):
    """padding: left, right, top, bottom; control / expand / scale: (width, height)."""
    return (kind, _padding(padding) + "  m_ChildAlignment: %d\n  m_Spacing: %s\n  m_ChildForceExpandWidth: %d\n  m_ChildForceExpandHeight: %d\n  m_ChildControlWidth: %d\n  m_ChildControlHeight: %d\n  m_ChildScaleWidth: %d\n  m_ChildScaleHeight: %d\n  m_ReverseArrangement: %d\n" % (
        align, num(spacing), expand[0], expand[1], control[0], control[1], scale[0], scale[1], reverse))


def hgroup(**kw):
    return linear("HorizontalLayoutGroup", **kw)


def vgroup(**kw):
    return linear("VerticalLayoutGroup", **kw)


def grid(cell=(100, 100), spacing=(0, 0), padding=(0, 0, 0, 0), align=0, corner=0, axis=0, constraint=0, count=2):
    return ("GridLayoutGroup", _padding(padding) + "  m_ChildAlignment: %d\n  m_StartCorner: %d\n  m_StartAxis: %d\n  m_CellSize: %s\n  m_Spacing: %s\n  m_Constraint: %d\n  m_ConstraintCount: %d\n" % (
        align, corner, axis, vec(cell, "xy"), vec(spacing, "xy"), constraint, count))


def fitter(h=0, v=0):
    return ("ContentSizeFitter", "  m_HorizontalFit: %d\n  m_VerticalFit: %d\n" % (h, v))


def element(min=(-1, -1), pref=(-1, -1), flex=(-1, -1), ignore=False, priority=1):
    return ("LayoutElement", "  m_IgnoreLayout: %d\n  m_MinWidth: %s\n  m_MinHeight: %s\n  m_PreferredWidth: %s\n  m_PreferredHeight: %s\n  m_FlexibleWidth: %s\n  m_FlexibleHeight: %s\n  m_LayoutPriority: %d\n" % (
        ignore, num(min[0]), num(min[1]), num(pref[0]), num(pref[1]), num(flex[0]), num(flex[1]), priority))


def aspect(mode, ratio):
    """0 None, 1 WidthControlsHeight, 2 HeightControlsWidth, 3 FitInParent, 4 EnvelopeParent."""
    return ("AspectRatioFitter", "  m_AspectMode: %d\n  m_AspectRatio: %s\n" % (mode, num(ratio)))


# ---- the cases ------------------------------------------------------------------------------------

COLORS = [(0.9, 0.3, 0.3, 1), (0.3, 0.7, 0.3, 1), (0.3, 0.4, 0.9, 1), (0.9, 0.8, 0.2, 1), (0.7, 0.3, 0.8, 1), (0.2, 0.8, 0.8, 1), (0.95, 0.6, 0.2, 1), (0.6, 0.6, 0.6, 1)]


class Builder:
    def __init__(self, f):
        self.f = f
        self.n = 0

    def img(self, name, parent, rect, comps=(), active=True, color=None):
        self.n += 1
        return self.f.node(name, parent, rect, [renderer(), image(color or COLORS[self.n % len(COLORS)])] + list(comps), active)

    def box(self, name, parent, rect, comps=(), active=True):
        """A RectTransform without a graphic (a container)."""
        return self.f.node(name, parent, rect, list(comps), active)

    def world_canvas(self, name, pos, size, scale=0.001, pivot=(0.5, 0.5), parent=None, rot=(0, 0, 0), comps=()):
        rect = {"pos": (pos[0], pos[1]), "z": pos[2], "size": size, "scale": scale, "pivot": pivot, "rot": rot, "amin": (0, 0), "amax": (0, 0)}
        return self.f.node(name, parent, rect, [canvas(2), scaler(), raycaster()] + list(comps))

    def kids(self, parent, sizes, comps=None, prefix="I"):
        """Image children with the given size deltas (centre anchors: layout groups re-anchor them)."""
        out = []
        for i, sz in enumerate(sizes):
            extra = comps[i] if comps else ()
            out.append(self.img("%s%d" % (prefix, i), parent, {"size": sz}, extra))
        return out


def card_prefab():
    """A UI prefab without a canvas: a panel with a title bar and an icon."""
    f = UnityFile("0c11ca5e000000000000000000000001")
    b = Builder(f)
    root = b.img("Card", None, {"size": (200, 120)}, color=(0.25, 0.25, 0.3, 1))
    b.img("Title", root, {"amin": (0, 1), "amax": (1, 1), "pivot": (0.5, 1), "pos": (0, 0), "size": (0, 30)}, color=(0.8, 0.5, 0.2, 1))
    b.img("Icon", root, {"amin": (0, 0), "amax": (0, 0), "pivot": (0, 0), "pos": (10, 10), "size": (40, 40)}, color=(0.2, 0.7, 0.9, 1))
    body = b.box("Body", root, {"amin": (0, 0), "amax": (1, 1), "pos": (25, -15), "size": (-70, -50)})
    b.img("Line", body, {"amin": (0, 0.5), "amax": (1, 0.5), "pos": (0, 0), "size": (0, 6)}, color=(0.9, 0.9, 0.9, 1))
    return f, {"root": root, "title": f.objects[1], "icon": f.objects[2], "body": body}


def board_prefab():
    """A prefab whose root is a world canvas (400 x 200 at scale 0.002)."""
    f = UnityFile("0c11ca5e000000000000000000000002")
    b = Builder(f)
    root = f.node("Board", None, {"size": (400, 200), "scale": 0.002, "amin": (0, 0), "amax": (0, 0)}, [canvas(2), scaler(), raycaster()])
    b.img("Back", root, {"amin": (0, 0), "amax": (1, 1), "size": (0, 0)}, color=(0.15, 0.2, 0.3, 1))
    b.img("Lamp", root, {"amin": (1, 1), "amax": (1, 1), "pivot": (1, 1), "pos": (-10, -10), "size": (50, 50)}, color=(1, 0.9, 0.3, 1))
    b.f.node("Go", root, {"pos": (0, -40), "size": (160, 50)}, [renderer(), image((0.3, 0.8, 0.4, 1)), button()])
    return f, {"root": root, "lamp": f.objects[2]}


def build_scene(card, card_ids, board, board_ids):
    f = UnityFile("0c11ca5e000000000000000000000010", first_id=1000)
    b = Builder(f)

    # ---- Rects: plain RectTransform geometry ----------------------------------------------------
    c = b.world_canvas("Rects", (0, 1.5, 2), (800, 600))
    b.img("Background", c, {"amin": (0, 0), "amax": (1, 1), "size": (0, 0)}, color=(0.1, 0.1, 0.12, 1))
    b.img("Centre", c, {"pos": (0, 0), "size": (120, 60)})
    for name, a in (("TopLeft", (0, 1)), ("TopRight", (1, 1)), ("BottomLeft", (0, 0)), ("BottomRight", (1, 0))):
        # anchored and pivoted at a corner, 10 units in
        b.img(name, c, {"amin": a, "amax": a, "pivot": a, "pos": (10 if a[0] == 0 else -10, 10 if a[1] == 0 else -10), "size": (90, 40)})
    b.img("CornerAnchorCentrePivot", c, {"amin": (1, 1), "amax": (1, 1), "pos": (-150, -30), "size": (60, 30)})
    b.img("StretchInset", c, {"amin": (0, 0), "amax": (1, 1), "pos": (-10, 5), "size": (-300, -500)})
    b.img("TopBar", c, {"amin": (0, 1), "amax": (1, 1), "pivot": (0.5, 1), "pos": (0, -60), "size": (-240, 24)})
    b.img("LeftBar", c, {"amin": (0, 0), "amax": (0, 1), "pivot": (0, 0.5), "pos": (20, 0), "size": (16, -200)})
    b.img("PartialAnchors", c, {"amin": (0.25, 0.1), "amax": (0.75, 0.3), "pos": (0, 0), "size": (0, 0)})
    b.img("PartialAnchorsOffset", c, {"amin": (0.6, 0.6), "amax": (0.9, 0.8), "pivot": (0.2, 0.8), "pos": (12, -8), "size": (20, 10)})
    b.img("PivotScaled", c, {"pivot": (0, 0), "pos": (-300, -200), "size": (40, 40), "scale": (2, 1.5, 1)})
    b.img("Rotated30", c, {"pos": (200, 150), "size": (100, 30), "rot": (0, 0, 30)})
    b.img("RotatedPivot", c, {"pivot": (0, 0.5), "pos": (200, -150), "size": (100, 20), "rot": (0, 0, -45)})
    b.img("MirroredX", c, {"pos": (-200, 150), "size": (80, 40), "scale": (-1, 1, 1)})
    b.img("NonUniform", c, {"pos": (-200, 60), "size": (50, 50), "scale": (2, 0.5, 1), "rot": (0, 0, 15)})
    b.img("Overflow", c, {"pos": (520, 380), "size": (100, 60)})
    b.img("Hidden", c, {"pos": (0, -250), "size": (200, 30)}, active=False)
    # nesting: a scaled and rotated container whose children are anchored inside it
    group = b.box("Group", c, {"pos": (-250, -80), "size": (200, 120), "scale": (0.75, 0.75, 1), "rot": (0, 0, 20)})
    b.img("GroupFill", group, {"amin": (0, 0), "amax": (1, 1), "size": (0, 0)})
    b.img("GroupCorner", group, {"amin": (1, 0), "amax": (1, 0), "pivot": (1, 0), "pos": (-5, 5), "size": (60, 30), "scale": (1.5, 1.5, 1)})
    inner = b.box("GroupInner", group, {"amin": (0, 0.5), "amax": (0.5, 1), "pos": (0, 0), "size": (-10, -10), "rot": (0, 0, -10)})
    b.img("Leaf", inner, {"amin": (0, 0), "amax": (1, 1), "pos": (0, 0), "size": (-8, -8)})
    # a zero-size parent: everything hangs off its pivot
    zero = b.box("ZeroSize", c, {"pos": (100, -50), "size": (0, 0)})
    b.img("ZeroChild", zero, {"pos": (0, 0), "size": (60, 20)})
    b.img("ZeroChildStretch", zero, {"amin": (0, 0), "amax": (1, 1), "pos": (0, -30), "size": (40, 10)})
    b.img("ZeroChildCorner", zero, {"amin": (1, 1), "amax": (1, 1), "pivot": (0, 0), "pos": (35, 0), "size": (20, 20)})
    # a hidden container keeps its children's places
    hid = b.box("HiddenGroup", c, {"pos": (300, 0), "size": (100, 100)}, active=False)
    b.img("HiddenChild", hid, {"amin": (0, 0), "amax": (1, 0.5), "size": (0, 0)})

    # ---- Spatial: nodes that are not in the canvas plane -----------------------------------------
    c = b.world_canvas("Spatial", (1.5, 1.5, 2), (600, 400))
    b.img("Flat", c, {"amin": (0, 0), "amax": (1, 1), "size": (0, 0)}, color=(0.12, 0.1, 0.1, 1))
    tilt = b.box("TiltedX", c, {"pos": (-150, 0), "size": (200, 150), "rot": (45, 0, 0)})
    b.img("TiltFill", tilt, {"amin": (0, 0), "amax": (1, 1), "size": (0, 0)})
    b.img("TiltKnob", tilt, {"amin": (1, 1), "amax": (1, 1), "pivot": (1, 1), "pos": (-10, -10), "size": (40, 40), "rot": (0, 0, 30)})
    b.img("TurnedY", c, {"pos": (150, 100), "size": (160, 80), "rot": (0, 60, 0)})
    b.img("Flipped", c, {"pos": (150, -20), "size": (120, 40), "rot": (0, 180, 0)})
    b.img("Forward", c, {"pos": (150, -120), "size": (120, 60), "z": -150})        # 15 cm in front
    b.img("Behind", c, {"pos": (0, -160), "size": (100, 40), "z": 80})
    b.img("AlmostFlat", c, {"pos": (0, 160), "size": (100, 40), "z": 0.2})          # 0.2 mm: stays in the plane
    deep = b.box("DeepGroup", c, {"pos": (-150, -150), "size": (100, 60), "z": -100, "scale": (0.5, 0.5, 0.5)})
    b.img("DeepFill", deep, {"amin": (0, 0), "amax": (1, 1), "size": (0, 0)})
    b.img("DeepTilted", deep, {"pos": (120, 0), "size": (80, 80), "rot": (0, -30, 0), "z": 40})
    both = b.img("TiltedAndTurned", c, {"pos": (0, 60), "size": (90, 90), "rot": (20, 30, 10), "scale": (1.2, 0.8, 1)})
    b.img("TiltedAndTurnedChild", both, {"pos": (0, 0), "size": (30, 30), "z": -20})
    b.img("HiddenTilted", c, {"pos": (-250, 150), "size": (60, 60), "rot": (30, 0, 0)}, active=False)

    # ---- Metres: a canvas in metres with scaled-down pixel layouts and widgets --------------------
    c = b.world_canvas("Metres", (-1.5, 1.5, 2), (1.2, 0.4), scale=1)
    panel = b.box("Panel", c, {"pos": (0, 0), "size": (240, 80), "scale": 0.005})
    b.img("PanelFill", panel, {"amin": (0, 0), "amax": (1, 1), "size": (0, 0)}, color=(0.1, 0.12, 0.1, 1))
    f.node("Press", panel, {"pos": (-80, 20), "size": (60, 24)}, [renderer(), image(COLORS[0]), button()])
    f.node("Tiny", panel, {"pos": (-80, -10), "size": (6, 4)}, [renderer(), image(COLORS[1]), button()])
    f.node("Check", panel, {"pos": (-30, 20), "size": (20, 20)}, [renderer(), image(COLORS[2]), toggle(True)])
    f.node("Field", panel, {"pos": (40, 20), "size": (100, 20)}, [renderer(), image(COLORS[3]), input_field("abc")])
    f.node("Slide", panel, {"pos": (40, -15), "size": (100, 10)}, [slider(0.25)])
    f.node("SlideV", panel, {"pos": (105, 0), "size": (8, 60)}, [slider(0.75, 2)])
    f.node("Label", panel, {"pos": (-30, -20), "size": (80, 16)}, [renderer(), text("Label", 12)])
    f.node("DirectButton", c, {"pos": (0.5, 0.15), "size": (0.12, 0.05)}, [renderer(), image(COLORS[4]), button()])

    # ---- Layouts ------------------------------------------------------------------------------
    c = b.world_canvas("Layouts", (0, 3.2, 2), (1800, 1400))
    b.img("LayoutBack", c, {"amin": (0, 0), "amax": (1, 1), "size": (0, 0)}, color=(0.08, 0.08, 0.1, 1))
    slot = [0]

    def panel(name, comps, size=(260, 110)):
        """Panels are laid out on a 6 x 10 lattice so that screenshots show every case."""
        i = slot[0]
        slot[0] += 1
        col, row = i % 6, i // 6
        return b.img(name, c, {"amin": (0, 1), "amax": (0, 1), "pivot": (0, 1), "pos": (20 + col * 295, -20 - row * 135), "size": size}, comps, color=(0.2, 0.2, 0.24, 1))

    three = [(50, 30), (70, 50), (40, 20)]
    # horizontal: children keep their size, each alignment (0 UpperLeft .. 8 LowerRight)
    for align in (0, 1, 2, 4, 6, 8):
        p = panel("H_Align%d" % align, [hgroup(padding=(10, 14, 6, 8), spacing=5, align=align)])
        b.kids(p, three)
    p = panel("H_Reverse", [hgroup(padding=(10, 10, 5, 5), spacing=5, align=3, reverse=True)])
    b.kids(p, three)
    p = panel("H_ControlWidth", [hgroup(padding=(10, 10, 5, 5), spacing=4, control=(True, False))])
    b.kids(p, three, [[element(pref=(40, -1))], [element(pref=(80, -1))], [element(min=(20, -1), pref=(60, -1))]])
    p = panel("H_ControlBoth", [hgroup(padding=(10, 10, 5, 5), spacing=4, control=(True, True), align=4)])
    b.kids(p, three, [[element(pref=(40, 20))], [element(pref=(80, 60))], [element(pref=(60, 200))]])
    p = panel("H_ExpandWidth", [hgroup(padding=(10, 10, 5, 5), spacing=4, expand=(True, False))])
    b.kids(p, three)
    p = panel("H_ControlExpand", [hgroup(padding=(10, 10, 5, 5), spacing=4, control=(True, True), expand=(True, True))])
    b.kids(p, three, [[element(pref=(40, 20))], [element(pref=(80, 30))], [element(pref=(20, 10))]])
    p = panel("H_Flexible", [hgroup(padding=(10, 10, 5, 5), spacing=4, control=(True, True))])
    b.kids(p, three, [[element(pref=(60, 40))], [element(pref=(20, 40), flex=(1, -1))], [element(pref=(20, 40), flex=(2, 1))]])
    p = panel("H_Squeezed", [hgroup(padding=(10, 10, 5, 5), spacing=4, control=(True, False))])   # less room than preferred
    b.kids(p, three, [[element(min=(20, -1), pref=(150, -1))], [element(min=(40, -1), pref=(150, -1))], [element(min=(10, -1), pref=(100, -1))]])
    p = panel("H_BelowMinimum", [hgroup(padding=(10, 10, 5, 5), spacing=4, control=(True, False))])   # less room than the minimums
    b.kids(p, three, [[element(min=(120, -1))], [element(min=(120, -1))], [element(min=(120, -1))]])
    p = panel("H_ChildScale", [hgroup(padding=(10, 10, 5, 5), spacing=6, scale=(True, True), align=3)])
    ks = b.kids(p, three)
    ks[1].rect["scale"] = (1.5, 1.5, 1)
    ks[2].rect["scale"] = (0.5, 2, 1)
    p = panel("H_ScaleNotUsed", [hgroup(padding=(10, 10, 5, 5), spacing=6, align=3)])
    ks = b.kids(p, three)
    ks[1].rect["scale"] = (1.5, 1.5, 1)
    p = panel("H_Pivots", [hgroup(padding=(10, 10, 5, 5), spacing=6, align=0)])
    ks = b.kids(p, three)
    ks[0].rect["pivot"] = (0, 0)
    ks[1].rect["pivot"] = (1, 1)
    ks[2].rect["pivot"] = (0.25, 0.75)
    p = panel("H_InactiveIgnored", [hgroup(padding=(10, 10, 5, 5), spacing=6)])
    ks = b.kids(p, [(40, 30), (40, 30), (40, 30), (40, 30)], [(), (), [element(ignore=True)], ()])
    ks[1].active = False
    ks[2].rect.update({"pos": (60, -30)})
    # vertical
    for align in (0, 4, 8):
        p = panel("V_Align%d" % align, [vgroup(padding=(8, 12, 6, 10), spacing=4, align=align)])
        b.kids(p, [(60, 20), (90, 30), (40, 15)])
    p = panel("V_ControlWidth", [vgroup(padding=(8, 8, 6, 6), spacing=4, control=(True, False), expand=(True, False))])
    b.kids(p, [(60, 20), (90, 30), (40, 15)])
    p = panel("V_ControlHeight", [vgroup(padding=(8, 8, 6, 6), spacing=4, control=(False, True), expand=(False, True))])
    b.kids(p, [(60, 20), (90, 30), (40, 15)], [[element(pref=(-1, 10))], [element(pref=(-1, 10), flex=(-1, 3))], [element(pref=(-1, 30))]])
    p = panel("V_Reverse", [vgroup(padding=(8, 8, 6, 6), spacing=4, reverse=True, align=7)])
    b.kids(p, [(60, 20), (90, 30), (40, 15)])
    p = panel("V_ExpandNoControl", [vgroup(padding=(8, 8, 6, 6), spacing=2, expand=(True, True), align=4)])
    b.kids(p, [(60, 20), (90, 30), (40, 15)])
    p = panel("V_Priority", [vgroup(padding=(8, 8, 6, 6), spacing=4, control=(True, True))])
    # a nested group asks for its content's size; a LayoutElement of priority 1 overrides it,
    # one of priority -1 does not
    n1 = b.img("WithElement", p, {"size": (10, 10)}, [hgroup(spacing=2), element(pref=(-1, 40))])
    b.kids(n1, [(30, 20), (30, 20)])
    n2 = b.img("LowPriority", p, {"size": (10, 10)}, [hgroup(spacing=2), element(pref=(-1, 40), priority=-1)])
    b.kids(n2, [(30, 20), (30, 20)])
    # grids
    six = [(10, 10)] * 6
    p = panel("G_Flexible", [grid(cell=(50, 30), spacing=(6, 4), padding=(8, 8, 6, 6))])
    b.kids(p, [(10, 10)] * 7)
    for corner in (0, 1, 2, 3):
        p = panel("G_Corner%d" % corner, [grid(cell=(50, 30), spacing=(6, 4), padding=(8, 8, 6, 6), corner=corner, constraint=1, count=3)])
        b.kids(p, [(10, 10)] * 5)
    p = panel("G_VerticalAxis", [grid(cell=(50, 30), spacing=(6, 4), padding=(8, 8, 6, 6), axis=1)])
    b.kids(p, [(10, 10)] * 7)
    p = panel("G_FixedRows", [grid(cell=(40, 30), spacing=(6, 4), padding=(8, 8, 6, 6), constraint=2, count=2, align=4)])
    b.kids(p, [(10, 10)] * 5)
    p = panel("G_FixedRowsVertical", [grid(cell=(40, 30), spacing=(6, 4), padding=(8, 8, 6, 6), constraint=2, count=2, axis=1, corner=3, align=8)])
    b.kids(p, [(10, 10)] * 5)
    p = panel("G_FixedColumnsAligned", [grid(cell=(40, 25), spacing=(6, 4), padding=(8, 8, 6, 6), constraint=1, count=4, align=5)])
    b.kids(p, [(10, 10)] * 6)
    p = panel("G_OneChild", [grid(cell=(60, 40), spacing=(6, 4), padding=(8, 8, 6, 6), align=4)])
    b.kids(p, [(10, 10)])
    p = panel("G_Empty", [grid(cell=(60, 40))])
    p = panel("G_InactiveIgnored", [grid(cell=(40, 25), spacing=(6, 4), padding=(8, 8, 6, 6), constraint=1, count=3)])
    ks = b.kids(p, [(10, 10)] * 6, [(), (), (), [element(ignore=True)], (), ()])
    ks[1].active = False
    ks[3].rect.update({"pos": (0, -30), "size": (30, 30)})
    # content size fitters
    p = panel("F_VerticalList", [])
    lst = b.img("List", p, {"amin": (0, 1), "amax": (1, 1), "pivot": (0.5, 1), "pos": (0, -5), "size": (-20, 10)}, [vgroup(padding=(4, 4, 4, 4), spacing=3, control=(True, False), expand=(True, False)), fitter(0, 2)])
    b.kids(lst, [(10, 18), (10, 24), (10, 12)])
    p = panel("F_HorizontalMin", [])
    row = b.img("Row", p, {"amin": (0, 0.5), "amax": (0, 0.5), "pivot": (0, 0.5), "pos": (8, 0), "size": (10, 40)}, [hgroup(padding=(4, 4, 4, 4), spacing=3, control=(True, False)), fitter(1, 0)])
    b.kids(row, three, [[element(min=(30, -1), pref=(60, -1))], [element(min=(50, -1), pref=(90, -1))], [element(min=(20, -1))]])
    p = panel("F_BothPivot", [])
    grow = b.img("Grow", p, {"amin": (1, 0), "amax": (1, 0), "pivot": (1, 0), "pos": (-8, 8), "size": (10, 10)}, [hgroup(padding=(5, 5, 5, 5), spacing=5), fitter(2, 2)])
    b.kids(grow, [(40, 30), (60, 50)])
    p = panel("F_GridRows", [])
    g = b.img("Cells", p, {"amin": (0, 1), "amax": (1, 1), "pivot": (0.5, 1), "pos": (0, -4), "size": (-8, 10)}, [grid(cell=(50, 22), spacing=(4, 4), padding=(4, 4, 4, 4)), fitter(0, 2)])
    b.kids(g, [(10, 10)] * 9)
    p = panel("F_Nested", [vgroup(padding=(6, 6, 6, 6), spacing=4, control=(True, True))])
    for r in range(2):
        rr = b.img("Row%d" % r, p, {"size": (10, 10)}, [hgroup(padding=(3, 3, 3, 3), spacing=3)])
        b.kids(rr, [(30 + 20 * r, 20), (40, 30 - 10 * r), (25, 25)])
    p = panel("F_ChildFitter", [vgroup(padding=(6, 6, 6, 6), spacing=4, align=1)])
    cf = b.img("FitsItself", p, {"size": (10, 10)}, [hgroup(padding=(3, 3, 3, 3), spacing=3), fitter(2, 2)])
    b.kids(cf, [(50, 20), (30, 30)])
    b.img("Plain", p, {"size": (80, 20)})
    # aspect ratio fitters
    p = panel("A_Modes", [])
    b.img("WidthControlsHeight", p, {"amin": (0, 1), "amax": (0, 1), "pivot": (0, 1), "pos": (5, -5), "size": (60, 10)}, [aspect(1, 2)])
    b.img("HeightControlsWidth", p, {"amin": (0, 0), "amax": (0, 0), "pivot": (0, 0), "pos": (5, 5), "size": (10, 40)}, [aspect(2, 1.5)])
    inner_fit = b.box("FitBox", p, {"amin": (1, 0.5), "amax": (1, 0.5), "pivot": (1, 0.5), "pos": (-5, 0), "size": (80, 100)})
    b.img("FitInParent", inner_fit, {"size": (10, 10)}, [aspect(3, 2)])
    p = panel("A_Envelope", [])
    inner_env = b.box("EnvelopeBox", p, {"pos": (0, 0), "size": (100, 60)})
    b.img("EnvelopeParent", inner_env, {"size": (10, 10), "pivot": (0, 1)}, [aspect(4, 1)])
    p = panel("A_StretchedWidth", [])
    b.img("Banner", p, {"amin": (0, 1), "amax": (1, 1), "pivot": (0.5, 1), "pos": (0, -5), "size": (-20, 10)}, [aspect(1, 4)])
    # a layout that only becomes active later keeps what is serialized
    p = panel("L_Inactive", [hgroup(padding=(10, 10, 5, 5), spacing=5)])
    p.active = False
    b.kids(p, three)

    # ---- Nested canvases ------------------------------------------------------------------------
    c = b.world_canvas("Nested", (-1.5, 3.0, 2), (600, 400))
    b.img("NestedBack", c, {"amin": (0, 0), "amax": (1, 1), "size": (0, 0)}, color=(0.1, 0.1, 0.14, 1))
    sub = f.node("InPlace", c, {"pos": (-180, 100), "size": (200, 120), "scale": (0.8, 0.8, 1)}, [canvas(2), raycaster(), renderer(), image(COLORS[2])])
    b.img("InPlaceChild", sub, {"amin": (0, 0), "amax": (0.5, 0.5), "size": (0, 0)})
    sub2 = f.node("InPlaceTilted", c, {"pos": (180, 100), "size": (200, 120), "rot": (0, 40, 0)}, [canvas(2), raycaster(), renderer(), image(COLORS[3])])
    b.img("InPlaceTiltedChild", sub2, {"amin": (0.5, 0.5), "amax": (1, 1), "size": (0, 0)})
    centre = [(board_ids["root"].t, "m_AnchorMin.x", 0.5), (board_ids["root"].t, "m_AnchorMin.y", 0.5), (board_ids["root"].t, "m_AnchorMax.x", 0.5), (board_ids["root"].t, "m_AnchorMax.y", 0.5),
              (board_ids["root"].t, "m_LocalScale.x", 0.5), (board_ids["root"].t, "m_LocalScale.y", 0.5), (board_ids["root"].t, "m_LocalScale.z", 0.5)]
    f.instance(board, c, "BoardFlat", centre + [(board_ids["root"].t, "m_AnchoredPosition.x", -150), (board_ids["root"].t, "m_AnchoredPosition.y", -100)])
    f.instance(board, c, "BoardTilted", centre + [(board_ids["root"].t, "m_AnchoredPosition.x", 150), (board_ids["root"].t, "m_AnchoredPosition.y", -100),
                                                  (board_ids["root"].t, "m_LocalRotation.x", euler_to_quat((30, 0, 0))[0]), (board_ids["root"].t, "m_LocalRotation.w", euler_to_quat((30, 0, 0))[3])])

    # ---- prefab instances with RectTransform overrides ------------------------------------------
    c = b.world_canvas("Cards", (1.5, 3.0, 2), (800, 500))
    b.img("CardsBack", c, {"amin": (0, 0), "amax": (1, 1), "size": (0, 0)}, color=(0.1, 0.12, 0.12, 1))
    rt = card_ids["root"].t
    f.instance(card, c, "CardPlain", [(rt, "m_AnchoredPosition.x", -280), (rt, "m_AnchoredPosition.y", 170)])
    f.instance(card, c, "CardResized", [(rt, "m_AnchoredPosition.x", 0), (rt, "m_AnchoredPosition.y", 150), (rt, "m_SizeDelta.x", 300), (rt, "m_SizeDelta.y", 160)])
    f.instance(card, c, "CardAnchored", [(rt, "m_AnchorMin.x", 1), (rt, "m_AnchorMin.y", 0), (rt, "m_AnchorMax.x", 1), (rt, "m_AnchorMax.y", 0), (rt, "m_Pivot.x", 1), (rt, "m_Pivot.y", 0), (rt, "m_AnchoredPosition.x", -10), (rt, "m_AnchoredPosition.y", 10)])
    f.instance(card, c, "CardScaledTurned", [(rt, "m_AnchoredPosition.x", -250), (rt, "m_AnchoredPosition.y", -120), (rt, "m_LocalScale.x", 0.6), (rt, "m_LocalScale.y", 0.6),
                                              (rt, "m_LocalRotation.z", euler_to_quat((0, 0, 25))[2]), (rt, "m_LocalRotation.w", euler_to_quat((0, 0, 25))[3])])
    f.instance(card, c, "CardChildMoved", [(rt, "m_AnchoredPosition.x", 0), (rt, "m_AnchoredPosition.y", -120),
                                            (card_ids["icon"].t, "m_AnchoredPosition.x", 150), (card_ids["icon"].t, "m_SizeDelta.y", 20),
                                            (card_ids["title"].t, "m_SizeDelta.y", 50), (card_ids["body"].t, "m_AnchorMax.x", 0.5)])
    f.instance(card, c, "CardStretched", [(rt, "m_AnchorMin.x", 0.7), (rt, "m_AnchorMin.y", 0.3), (rt, "m_AnchorMax.x", 0.98), (rt, "m_AnchorMax.y", 0.7), (rt, "m_AnchoredPosition.x", 0), (rt, "m_AnchoredPosition.y", 0), (rt, "m_SizeDelta.x", 0), (rt, "m_SizeDelta.y", 0)])
    lst = b.img("CardList", c, {"amin": (0.35, 0), "amax": (0.35, 0), "pivot": (0, 0), "pos": (0, 10), "size": (220, 100)}, [vgroup(padding=(5, 5, 5, 5), spacing=5, control=(True, False), expand=(True, False)), fitter(0, 2)])
    f.instance(card, lst, "CardInList0", [(rt, "m_SizeDelta.y", 60)])
    f.instance(card, lst, "CardInList1", [(rt, "m_SizeDelta.y", 40)])
    # a canvas prefab in the world, moved, turned and scaled by its overrides
    q = euler_to_quat((0, 30, 0))
    rt = board_ids["root"].t
    f.instance(board, None, "BoardInWorld", [(rt, "m_AnchoredPosition.x", 3), (rt, "m_AnchoredPosition.y", 1.2), (rt, "m_LocalPosition.z", 2.5), (rt, "m_LocalRotation.y", q[1]), (rt, "m_LocalRotation.w", q[3]),
                                               (rt, "m_SizeDelta.x", 500), (board_ids["lamp"].t, "m_AnchoredPosition.x", -40)])

    # ---- Placed: canvas placement under plain transforms ------------------------------------------
    rig = f.node("Rig", None, None, pos=(-3, 1, 2), rot=(0, 35, 0), scale=(1.5, 1.5, 1.5))
    arm = f.node("Arm", rig, None, pos=(0.2, 0.5, 0), rot=(20, 0, 10))
    c = b.world_canvas("Placed", (0.1, 0.2, -0.05), (300, 200), scale=0.002, pivot=(0, 1), parent=arm, rot=(0, 0, 15))
    b.img("PlacedBack", c, {"amin": (0, 0), "amax": (1, 1), "size": (0, 0)}, color=(0.14, 0.1, 0.1, 1))
    b.img("PlacedCorner", c, {"amin": (1, 0), "amax": (1, 0), "pivot": (1, 0), "pos": (0, 0), "size": (50, 50)})
    off = b.world_canvas("PivotOnly", (4.5, 1.5, 2), (400, 300), pivot=(1, 0.25))
    b.img("PivotBack", off, {"amin": (0, 0), "amax": (1, 1), "size": (0, 0)}, color=(0.1, 0.14, 0.1, 1))
    b.img("PivotMark", off, {"amin": (1, 0.25), "amax": (1, 0.25), "pos": (0, 0), "size": (30, 30)})
    empty = b.world_canvas("EmptyRoot", (6, 1.5, 2), (0, 0), scale=0.005)
    b.img("OffRoot", empty, {"pos": (40, 20), "size": (60, 30)})
    hidden = b.world_canvas("HiddenCanvas", (7, 1.5, 2), (200, 100))
    hidden.active = False
    b.img("HiddenCanvasChild", hidden, {"amin": (0, 0), "amax": (1, 1), "size": (0, 0)})

    # ---- screen-space canvases --------------------------------------------------------------------
    def screen(name, sc, order):
        cv = f.node(name, None, {"amin": (0, 0), "amax": (0, 0), "size": (0, 0), "scale": 0}, [canvas(0, order), sc, raycaster()])
        b.img("TL", cv, {"amin": (0, 1), "amax": (0, 1), "pivot": (0, 1), "pos": (10, -10), "size": (80, 40)})
        b.img("BR", cv, {"amin": (1, 0), "amax": (1, 0), "pivot": (1, 0), "pos": (-10, 10), "size": (80, 40)})
        b.img("Mid", cv, {"pos": (0, 0), "size": (100, 100)})
        b.img("Strip", cv, {"amin": (0, 0), "amax": (1, 0), "pivot": (0.5, 0), "pos": (0, 60), "size": (-200, 20)})
        return cv
    screen("ScreenConstant", scaler(0, 1), 0)
    screen("ScreenConstant2x", scaler(0, 2), 1)
    screen("ScreenMatchWidth", scaler(1, 1, (800, 600), 0, 0), 2)
    screen("ScreenMatchHeight", scaler(1, 1, (800, 600), 0, 1), 3)
    screen("ScreenMatchHalf", scaler(1, 1, (1920, 1080), 0, 0.5), 4)
    screen("ScreenExpand", scaler(1, 1, (800, 600), 1, 0), 5)
    screen("ScreenShrink", scaler(1, 1, (800, 600), 2, 0), 6)
    return f


META = "fileFormatVersion: 2\nguid: %s\n%s:\n  externalObjects: {}\n  userData: \n  assetBundleName: \n  assetBundleVariant: \n"


def main(argv):
    out = argv[1] if len(argv) > 1 else os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tests", "unity_ui", "UiCases")
    os.makedirs(out, exist_ok=True)
    card, card_ids = card_prefab()
    board, board_ids = board_prefab()
    scene = build_scene(card, card_ids, board, board_ids)
    for name, f, is_scene in (("Card.prefab", card, False), ("Board.prefab", board, False), ("UiCases.unity", scene, True)):
        with open(os.path.join(out, name), "w") as fh:
            fh.write(f.text(is_scene))
        with open(os.path.join(out, name + ".meta"), "w") as fh:
            fh.write(META % (f.guid, "DefaultImporter" if is_scene else "PrefabImporter"))
    print("wrote %s: %d scene objects, %d prefab instances" % (out, len(scene.objects), len(scene.instances)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
