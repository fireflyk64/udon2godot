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
  Sprites    Images that are not simply stretched: sliced (borders at their size, shrunk in a
             small rect, with a multiplier, without centre, on a Button), tiled, filled, sprites
             of a sheet, Unity's built-in sprites, and their preferred sizes in a layout group.
             The textures (Frame.png, Sheet.png, Bar.png) are written here too.
  Scroll     ScrollRects: content larger and smaller than the view on each axis, scrolled,
             outside the view (pulled back), scrollbars that stay, hide and make the viewport
             give way, a list laid out by a group with a fitter, scrollbars on their own
  Widgets    what one object does to another and what is drawn: Slider fill and handle rects by
             value and direction, Toggle check marks, Selectable colour tints, disabled graphics,
             masks, canvas groups, rich text (TextMeshPro and uGUI), an input field's text objects
  prefab instances with RectTransform overrides (Card.prefab, Board.prefab)
  Overrides  instances of Panel.prefab whose components are overridden: text, font size and
             colour, a disabled Image, Selectable colours and interactable, Toggle.isOn,
             Slider value and direction, layout group and layout element settings

Unity itself is not needed: tools/unity_ui_reference.py computes where Unity puts every rect
from these files, and the imported scene is compared with that (scripts/test_ui.sh).
"""
import hashlib
import math
import os
import struct
import sys
import zlib

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
    "TextMeshProUGUI": "f4688fdb7df04437aeb418b961361dc5",
    "ScrollRect": "1aa08ab6e0800fa44ae55d278d1423e3",
    "Dropdown": "0d1c2a8fe1a7b7a4d9edbdc6bf0d0d5b",
    "Scrollbar": "2a4db7a114972834c8e4117be1d82ba3",
    "RectMask2D": "3312d7739989d2b4e91e6319e9a96d76",
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
    """Unity's Quaternion.Euler: z, then x, then y (degrees). Four numbers are a quaternion."""
    if len(e) == 4:
        return tuple(e)
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
        kind, body = comp[0], comp[1]
        on = 1 if len(comp) < 3 or comp[2] else 0
        if kind == "CanvasGroup":
            o.components.append((cid, 225, "CanvasGroup", "  m_GameObject: {fileID: %d}\n  m_Enabled: 1\n%s" % (o.go, body)))
        elif kind == "Canvas":
            o.components.append((cid, 223, "Canvas", "  m_GameObject: {fileID: %d}\n  m_Enabled: 1\n%s" % (o.go, body)))
        elif kind == "Animator":
            o.components.append((cid, 95, "Animator", "  serializedVersion: 5\n  m_GameObject: {fileID: %d}\n  m_Enabled: 1\n  m_Avatar: {fileID: 0}\n  m_Controller: {fileID: 9100000, guid: %s, type: 2}\n  m_CullingMode: 0\n  m_UpdateMode: 0\n  m_ApplyRootMotion: 0\n  m_LinearVelocityBlending: 0\n  m_StabilizeFeet: 0\n  m_WarningMessage: \n  m_HasTransformHierarchy: 1\n  m_AllowConstantClipSamplingOptimization: 1\n  m_KeepAnimatorStateOnDisable: 0\n  m_WriteDefaultValuesOnDisable: 0\n" % (o.go, body)))
        elif kind == "CanvasRenderer":
            o.components.append((cid, 222, "CanvasRenderer", "  m_GameObject: {fileID: %d}\n  m_CullTransparentMesh: 1\n" % o.go))
        else:
            head = "  m_GameObject: {fileID: %d}\n  m_Enabled: %d\n  m_EditorHideFlags: 0\n  m_Script: {fileID: 11500000, guid: %s, type: 3}\n  m_Name: \n  m_EditorClassIdentifier: \n" % (o.go, on, GUID[kind])
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


def disable(comp):
    """The component, disabled (m_Enabled: 0)."""
    return (comp[0], comp[1], False)


def holders_turned_back(f, b, c):
    """vrcbce's desktop UI: plain Transforms turned out of the canvas plane (and scaled up) whose
    RectTransforms are turned back (and scaled down), so that everything is in the plane again."""
    flat = f.node("Flat", c, pos=(-200, 130, 0), rot=(-90, 0, 0), scale=(50, 50, 50))
    b.img("FlatImage", flat, {"pos": (0, 0), "size": (100, 60), "rot": (90, 0, 0), "scale": 0.02}, color=(0.9, 0.5, 0.1, 1))
    # local (1.5, 0, 0.4) in the turned holder: 75 to the right, 20 up
    b.img("FlatOffset", flat, {"pos": (1.5, 0), "z": 0.4, "size": (40, 40), "rot": (90, 0, 0), "scale": 0.02}, color=(0.1, 0.6, 0.9, 1))
    # a holder inside the holder (not turned itself), its image turned back
    hit = f.node("FlatHit", flat, pos=(-1, 0, -0.5))
    b.img("FlatHitImage", hit, {"pos": (0, 0), "size": (60, 60), "rot": (90, 0, 0), "scale": 0.01}, color=(0.9, 0.9, 0.9, 1))
    # turned about all three axes (120 degrees about (-1, 1, -1)), the bar turned back; what is
    # below the bar is laid out in it as usual
    swung = f.node("Swung", c, pos=(200, 130, 0), rot=(-0.5, 0.5, -0.5, 0.5), scale=(100, 100, 100))
    bar = b.img("SwungBar", swung, {"pos": (0, 0), "size": (20, 120), "rot": (0.5, -0.5, 0.5, 0.5), "scale": 0.01}, color=(0.3, 0.3, 0.35, 1))
    b.img("SwungInner", bar, {"pos": (0, 30), "size": (30, 10), "rot": (0, 0, 45)}, color=(0.9, 0.2, 0.2, 1))


def quoted(value):
    """A YAML scalar that may hold anything (Unity single-quotes such strings)."""
    return "'" + str(value).replace("'", "''") + "'"


def image(color=(1, 1, 1, 1), kind=0, sprite=None, center=True, fill=(4, 1, 0), multiplier=1):
    """kind: Image.Type (0 simple, 1 sliced, 2 tiled, 3 filled); sprite: (file id, guid) or None;
    fill: (method 0 horizontal / 1 vertical / 2 radial 90 / 3 radial 180 / 4 radial 360, amount,
    origin[, clockwise])."""
    ref = "{fileID: 0}" if sprite is None else "{fileID: %d, guid: %s, type: %d}" % (sprite[0], sprite[1], 0 if sprite[1] == BUILTIN else 3)
    return ("Image", _GRAPHIC % vec(color, "rgba") + "  m_Sprite: %s\n  m_Type: %d\n  m_PreserveAspect: 0\n  m_FillCenter: %d\n  m_FillMethod: %d\n  m_FillAmount: %s\n  m_FillClockwise: %d\n  m_FillOrigin: %d\n  m_UseSpriteMesh: 0\n  m_PixelsPerUnitMultiplier: %s\n" % (
        ref, kind, center, fill[0], num(fill[1]), fill[3] if len(fill) > 3 else 1, fill[2], num(multiplier)))


# ---- sprite textures ------------------------------------------------------------------------------

BUILTIN = "0000000000000000f000000000000000"          # Unity's built-in resources
UI_SPRITE, BACKGROUND, INPUT_BACKGROUND, KNOB, CHECKMARK = ((i, BUILTIN) for i in (10905, 10907, 10911, 10913, 10901))
FRAME = (21300000, "0c11ca5e0000000000000000000000a1")   # 64 x 64, border 16
BAR = (21300000, "0c11ca5e0000000000000000000000a2")     # 64 x 16, two halves
SHEET_GUID = "0c11ca5e0000000000000000000000a3"          # 64 x 32, two sprites
SHEET_LEFT = (7482667652216324301, SHEET_GUID)
SHEET_RIGHT = (-3219062469524436042, SHEET_GUID)

RED, GREEN, BLUE, YELLOW = (230, 60, 60, 255), (60, 200, 80, 255), (60, 90, 230, 255), (240, 220, 60, 255)
ORANGE, PURPLE, MAGENTA, CYAN = (240, 150, 40, 255), (150, 70, 200, 255), (220, 60, 200, 255), (60, 210, 220, 255)


def png(width, height, pixel):
    """An RGBA PNG; pixel(x, y) with y down → (r, g, b, a)."""
    raw = b"".join(b"\x00" + bytes(c for x in range(width) for c in pixel(x, y)) for y in range(height))

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")


def frame_pixel(x, y):
    """Corners red, top and bottom edges green, left and right edges blue, centre yellow."""
    ex, ey = x < 16 or x >= 48, y < 16 or y >= 48
    return RED if ex and ey else (BLUE if ex else (GREEN if ey else YELLOW))


TEXTURE_META = """fileFormatVersion: 2
guid: %(guid)s
TextureImporter:
  internalIDToNameTable:%(names)s
  externalObjects: {}
  serializedVersion: 12
  mipmaps:
    mipMapMode: 0
    enableMipMap: 0
    sRGBTexture: 1
    linearTexture: 0
    fadeOut: 0
    borderMipMap: 0
    mipMapsPreserveCoverage: 0
    alphaTestReferenceValue: 0.5
    mipMapFadeDistanceStart: 1
    mipMapFadeDistanceEnd: 3
  bumpmap:
    convertToNormalMap: 0
    externalNormalMap: 0
    heightScale: 0.25
    normalMapFilter: 0
    flipGreenChannel: 0
  isReadable: 0
  streamingMipmaps: 0
  streamingMipmapsPriority: 0
  vTOnly: 0
  ignoreMipmapLimit: 0
  grayScaleToAlpha: 0
  generateCubemap: 6
  cubemapConvolution: 0
  seamlessCubemap: 0
  textureFormat: 1
  maxTextureSize: 2048
  textureSettings:
    serializedVersion: 2
    filterMode: 0
    aniso: 1
    mipBias: 0
    wrapU: 1
    wrapV: 1
    wrapW: 0
  nPOTScale: 0
  lightmap: 0
  compressionQuality: 50
  spriteMode: %(mode)d
  spriteExtrude: 1
  spriteMeshType: 0
  alignment: 0
  spritePivot: {x: 0.5, y: 0.5}
  spritePixelsToUnits: %(ppu)s
  spriteBorder: %(border)s
  spriteGenerateFallbackPhysicsShape: 1
  alphaUsage: 1
  alphaIsTransparency: 1
  spriteTessellationDetail: -1
  textureType: 8
  textureShape: 1
  singleChannelComponent: 0
  flipbookRows: 1
  flipbookColumns: 1
  maxTextureSizeSet: 0
  compressionQualitySet: 0
  textureFormatSet: 0
  ignorePngGamma: 0
  applyGammaDecoding: 0
  swizzle: 50462976
  cookieLightType: 0
  platformSettings:
  - serializedVersion: 3
    buildTarget: DefaultTexturePlatform
    maxTextureSize: 2048
    resizeAlgorithm: 0
    textureFormat: -1
    textureCompression: 0
    compressionQuality: 50
    crunchedCompression: 0
    allowsAlphaSplitting: 0
    overridden: 0
    ignorePlatformSupport: 0
    androidETC2FallbackOverride: 0
    forceMaximumCompressionQuality_BC6H_BC7: 0
  spriteSheet:
    serializedVersion: 2
    sprites:%(sprites)s
    outline: []
    physicsShape: []
    bones: []
    spriteID: 5e97eb03825dee720800000000000000
    internalID: 0
    vertices: []
    indices: 
    edges: []
    weights: []
    secondaryTextures: []
    nameFileIdTable: {}
  mipmapLimitGroupName: 
  pSDRemoveMatte: 0
  userData: 
  assetBundleName: 
  assetBundleVariant: 
"""

SHEET_SPRITE = """
    - serializedVersion: 2
      name: %(name)s
      rect:
        serializedVersion: 2
        x: %(x)d
        y: %(y)d
        width: %(w)d
        height: %(h)d
      alignment: 0
      pivot: {x: 0.5, y: 0.5}
      border: {x: %(b)d, y: %(b)d, z: %(b)d, w: %(b)d}
      outline: []
      physicsShape: []
      tessellationDetail: -1
      bones: []
      spriteID: %(id)s
      internalID: %(internal)d
      vertices: []
      indices: 
      edges: []
      weights: []"""


def write_textures(out):
    """Frame.png (sliced), Bar.png (filled), Sheet.png (two sprites) and their import settings."""
    def write(name, data, meta):
        with open(os.path.join(out, name), "wb") as fh:
            fh.write(data)
        with open(os.path.join(out, name + ".meta"), "w") as fh:
            fh.write(meta)
    write("Frame.png", png(64, 64, frame_pixel), TEXTURE_META % {"guid": FRAME[1], "names": " []", "mode": 1, "ppu": 100, "border": "{x: 16, y: 16, z: 16, w: 16}", "sprites": " []"})
    write("Bar.png", png(64, 16, lambda x, y: ORANGE if x < 32 else PURPLE), TEXTURE_META % {"guid": BAR[1], "names": " []", "mode": 1, "ppu": 100, "border": "{x: 0, y: 0, z: 0, w: 0}", "sprites": " []"})
    names = "".join("\n  - first:\n      213: %d\n    second: %s" % (sp[0], nm) for sp, nm in ((SHEET_LEFT, "Sheet_0"), (SHEET_RIGHT, "Sheet_1")))
    # Unity's sprite rects have their origin at the bottom-left: the upper half of the left
    # sprite is magenta, its lower half cyan; the right sprite is the other way round
    sprites = "".join(SHEET_SPRITE % {"name": nm, "x": x, "y": 0, "w": 32, "h": 32, "b": 0, "id": "%032x" % (i + 1), "internal": sp[0]}
                      for i, (sp, nm, x) in enumerate(((SHEET_LEFT, "Sheet_0", 0), (SHEET_RIGHT, "Sheet_1", 32))))
    write("Sheet.png", png(64, 32, lambda x, y: (MAGENTA if (x < 32) == (y < 16) else CYAN)), TEXTURE_META % {"guid": SHEET_GUID, "names": names, "mode": 2, "ppu": 100, "border": "{x: 0, y: 0, z: 0, w: 0}", "sprites": sprites})


FONT_ASSET_YAML = """%%YAML 1.1
%%TAG !u! tag:unity3d.com,2011:
--- !u!114 &11400000
MonoBehaviour:
  m_ObjectHideFlags: 0
  m_CorrespondingSourceObject: {fileID: 0}
  m_PrefabInstance: {fileID: 0}
  m_PrefabAsset: {fileID: 0}
  m_GameObject: {fileID: 0}
  m_Enabled: 1
  m_EditorHideFlags: 0
  m_Script: {fileID: 11500000, guid: 71c1514a6bd24e1e882cebbe1904ce04, type: 3}
  m_Name: %(name)s
  m_EditorClassIdentifier: 
  hashCode: 841032664
  material: {fileID: 0}
  materialHashCode: 0
  m_Version: 1.1.0
  m_SourceFontFileGUID: %(source)s
  m_SourceFontFile_EditorRef: {fileID: 12800000, guid: %(source)s,
    type: 3}
  m_SourceFontFile: {fileID: 0}
  m_AtlasPopulationMode: 0
  m_FaceInfo:
    m_FaceIndex: 0
    m_FamilyName: %(family)s
    m_StyleName: Regular
    m_PointSize: 81
    m_Scale: 1
    m_LineHeight: 105.299995
    m_AscentLine: 81
    m_CapLine: 57
    m_MeanLine: 43
    m_Baseline: 0
    m_DescentLine: -24.3
    m_SuperscriptOffset: 81
    m_SuperscriptSize: 0.5
    m_SubscriptOffset: -24.3
    m_SubscriptSize: 0.5
    m_UnderlineOffset: -7.29
    m_UnderlineThickness: 8.262
    m_StrikethroughOffset: 17.2
    m_StrikethroughThickness: 8.262
    m_TabWidth: 15
  m_GlyphTable: []
  m_CharacterTable: []
  m_AtlasTextures: []
  m_AtlasTextureIndex: 0
  m_AtlasWidth: 1024
  m_AtlasHeight: 1024
  m_AtlasPadding: 9
  m_AtlasRenderMode: 4165
  m_FallbackFontAssetTable: []
  m_CreationSettings:
    sourceFontFileName: 
    sourceFontFileGUID: %(source)s
    pointSizeSamplingMode: 1
    pointSize: 81
    padding: 9
  fontWeights: []
  normalStyle: 0
  normalSpacingOffset: 0
  boldStyle: 0.75
  boldSpacing: 7
  italicStyle: 35
  tabSize: 10
"""
FONT_ASSET_META = "fileFormatVersion: 2\nguid: %s\nNativeFormatImporter:\n  externalObjects: {}\n  mainObjectFileID: 11400000\n  userData: \n  assetBundleName: \n  assetBundleVariant: \n"
FONT_FILE_META = ("fileFormatVersion: 2\nguid: %s\nTrueTypeFontImporter:\n  externalObjects: {}\n  serializedVersion: 4\n  fontSize: 16\n  forceTextureCase: -2\n  characterSpacing: 0\n"
                  "  characterPadding: 1\n  includeFontData: 1\n  fontName: Calistoga\n  fontNames:\n  - Calistoga\n  fallbackFontReferences: []\n  customCharacters: \n  fontRenderingMode: 0\n"
                  "  ascentCalculationMode: 1\n  useLegacyBoundsCalculation: 0\n  shouldRoundAdvanceValue: 1\n  userData: \n  assetBundleName: \n  assetBundleVariant: \n")


def write_fonts(out):
    """Fonts/: Calistoga.ttf (checked in, with its licence) gets its import settings, and two
    TextMeshPro font assets are written: one made from it, one whose source font is gone."""
    fonts = os.path.join(out, "Fonts")
    os.makedirs(fonts, exist_ok=True)
    if not os.path.exists(os.path.join(fonts, "Calistoga.ttf")):
        print("note: %s/Calistoga.ttf is missing; the font cases will fall back to the stand-in font" % fonts)

    def write(name, data):
        with open(os.path.join(fonts, name), "w") as fh:
            fh.write(data)
    with open(os.path.join(out, "Fonts.meta"), "w") as fh:
        fh.write("fileFormatVersion: 2\nguid: f3a7c1d2e3b44f5a8697a1b2c3d4e5f6\nfolderAsset: yes\nDefaultImporter:\n  externalObjects: {}\n  userData: \n  assetBundleName: \n  assetBundleVariant: \n")
    write("Calistoga.ttf.meta", FONT_FILE_META % FONT_FILE)
    write("OFL.txt.meta", "fileFormatVersion: 2\nguid: f4a7c1d2e3b44f5a8697a1b2c3d4e5f6\nTextScriptImporter:\n  externalObjects: {}\n  userData: \n  assetBundleName: \n  assetBundleVariant: \n")
    write("Calistoga SDF.asset", FONT_ASSET_YAML % {"name": "Calistoga SDF", "source": FONT_FILE, "family": "Calistoga"})
    write("Calistoga SDF.asset.meta", FONT_ASSET_META % FONT_ASSET)
    write("Lost SDF.asset", FONT_ASSET_YAML % {"name": "Lost SDF", "source": "f5a7c1d2e3b44f5a8697a1b2c3d4e5f6", "family": "Lost Family"})
    write("Lost SDF.asset.meta", FONT_ASSET_META % FONT_ASSET_LOST)


# ---- animation clips and a controller ---------------------------------------------------------
CLIP_LEFT = "a0a7c1d2e3b44f5a8697a1b2c3d4e5f6"
CLIP_RIGHT = "a1a7c1d2e3b44f5a8697a1b2c3d4e5f6"
CLIP_SLIDE = "a2a7c1d2e3b44f5a8697a1b2c3d4e5f6"
KNOB_CONTROLLER = "a3a7c1d2e3b44f5a8697a1b2c3d4e5f6"
CLIP_SHOW_REST = "a5a7c1d2e3b44f5a8697a1b2c3d4e5f6"
CLIP_SHOW_TURN = "a6a7c1d2e3b44f5a8697a1b2c3d4e5f6"
CLIP_SHOW_FADE = "a7a7c1d2e3b44f5a8697a1b2c3d4e5f6"
CLIP_SHOW_FRAMES = "a8a7c1d2e3b44f5a8697a1b2c3d4e5f6"
SHOW_CONTROLLER = "a9a7c1d2e3b44f5a8697a1b2c3d4e5f6"
CLIP_PRESS_NORMAL = "aaa7c1d2e3b44f5a8697a1b2c3d4e5f6"
CLIP_PRESS_OVER = "aba7c1d2e3b44f5a8697a1b2c3d4e5f6"
CLIP_PRESS_DOWN = "aca7c1d2e3b44f5a8697a1b2c3d4e5f6"
PRESS_CONTROLLER = "ada7c1d2e3b44f5a8697a1b2c3d4e5f6"


def _curve(path, attribute, keys, class_id=224, script=None):
    """A float curve of a clip: keys are (time, value); straight between them. `script`: the
    component kind of a MonoBehaviour curve (class id 114)."""
    out = "  - curve:\n      serializedVersion: 2\n      m_Curve:\n"
    for i, (t, v) in enumerate(keys):
        before = (v - keys[i - 1][1]) / (t - keys[i - 1][0]) if i > 0 else 0
        after = (keys[i + 1][1] - v) / (keys[i + 1][0] - t) if i + 1 < len(keys) else 0
        out += ("      - serializedVersion: 3\n        time: %s\n        value: %s\n        inSlope: %s\n        outSlope: %s\n        tangentMode: 69\n        weightedMode: 0\n        inWeight: 0.33333334\n        outWeight: 0.33333334\n"
                % (num(t), num(v), num(before), num(after)))
    ref = "{fileID: 0}" if script is None else "{fileID: 11500000, guid: %s, type: 3}" % GUID[script]
    out += "      m_PreInfinity: 2\n      m_PostInfinity: 2\n      m_RotationOrder: 4\n    attribute: %s\n    path: %s\n    classID: %d\n    script: %s\n" % (attribute, path, 114 if script else class_id, ref)
    return out


def _vcurve(path, keys):
    """A vector curve (m_EulerCurves, m_PositionCurves, m_ScaleCurves): keys are (time, (x, y, z))."""
    out = "  - curve:\n      serializedVersion: 2\n      m_Curve:\n"
    for i, (t, v) in enumerate(keys):
        before = tuple((v[k] - keys[i - 1][1][k]) / (t - keys[i - 1][0]) for k in range(3)) if i > 0 else (0, 0, 0)
        after = tuple((keys[i + 1][1][k] - v[k]) / (keys[i + 1][0] - t) for k in range(3)) if i + 1 < len(keys) else (0, 0, 0)
        third = "{x: 0.33333334, y: 0.33333334, z: 0.33333334}"
        out += ("      - serializedVersion: 3\n        time: %s\n        value: %s\n        inSlope: %s\n        outSlope: %s\n        tangentMode: 0\n        weightedMode: 0\n        inWeight: %s\n        outWeight: %s\n"
                % (num(t), vec(v, "xyz"), vec(before, "xyz"), vec(after, "xyz"), third, third))
    out += "      m_PreInfinity: 2\n      m_PostInfinity: 2\n      m_RotationOrder: 4\n    path: %s\n" % path
    return out


def _pptr(path, attribute, keys, script):
    """An object curve (m_PPtrCurves): keys are (time, (file id, guid))."""
    out = "  - curve:\n"
    for t, (fid, guid) in keys:
        out += "    - time: %s\n      value: {fileID: %d, guid: %s, type: 3}\n" % (num(t), fid, guid)
    return out + "    attribute: %s\n    path: %s\n    classID: 114\n    script: {fileID: 11500000, guid: %s, type: 3}\n" % (attribute, path, GUID[script])


def _clip(name, curves, length, euler=(), position=(), scale=(), pptr=()):
    def section(key, items):
        return "  %s:%s" % (key, ("\n" + "".join(items)) if items else " []\n")
    template = ("%%YAML 1.1\n%%TAG !u! tag:unity3d.com,2011:\n--- !u!74 &7400000\nAnimationClip:\n  m_ObjectHideFlags: 0\n  m_CorrespondingSourceObject: {fileID: 0}\n  m_PrefabInstance: {fileID: 0}\n  m_PrefabAsset: {fileID: 0}\n"
            "  m_Name: %s\n  serializedVersion: 6\n  m_Legacy: 0\n  m_Compressed: 0\n  m_UseHighQualityCurve: 1\n  m_RotationCurves: []\n  m_CompressedRotationCurves: []\n" + section("m_EulerCurves", euler).replace("%", "%%") + section("m_PositionCurves", position).replace("%", "%%") + section("m_ScaleCurves", scale).replace("%", "%%") +
            section("m_FloatCurves", curves).replace("%", "%%") + section("m_PPtrCurves", pptr).replace("%", "%%") + "  m_SampleRate: 60\n  m_WrapMode: 0\n  m_Bounds:\n    m_Center: {x: 0, y: 0, z: 0}\n    m_Extent: {x: 0, y: 0, z: 0}\n  m_ClipBindingConstant:\n    genericBindings: []\n    pptrCurveMapping: []\n"
            "  m_AnimationClipSettings:\n    serializedVersion: 2\n    m_AdditiveReferencePoseClip: {fileID: 0}\n    m_AdditiveReferencePoseTime: 0\n    m_StartTime: 0\n    m_StopTime: %s\n    m_OrientationOffsetY: 0\n    m_Level: 0\n    m_CycleOffset: 0\n"
            "    m_HasAdditiveReferencePose: 0\n    m_LoopTime: 0\n    m_LoopBlend: 0\n    m_LoopBlendOrientation: 0\n    m_LoopBlendPositionY: 0\n    m_LoopBlendPositionXZ: 0\n    m_KeepOriginalOrientation: 0\n    m_KeepOriginalPositionY: 1\n"
            "    m_KeepOriginalPositionXZ: 0\n    m_HeightFromFeet: 0\n    m_Mirror: 0\n  m_EditorCurves: []\n  m_EulerEditorCurves: []\n  m_HasGenericRootTransform: 0\n  m_HasMotionFloatCurves: 0\n  m_Events: []\n")
    return template % (name, num(length))


def _state(fid, name, clip, transitions):
    return ("--- !u!1102 &%d\nAnimatorState:\n  serializedVersion: 5\n  m_ObjectHideFlags: 1\n  m_CorrespondingSourceObject: {fileID: 0}\n  m_PrefabInstance: {fileID: 0}\n  m_PrefabAsset: {fileID: 0}\n  m_Name: %s\n  m_Speed: 1\n  m_CycleOffset: 0\n"
            "  m_Transitions:%s  m_StateMachineBehaviours: []\n  m_Position: {x: 50, y: 50, z: 0}\n  m_IKOnFeet: 0\n  m_WriteDefaultValues: 1\n  m_Mirror: 0\n  m_SpeedParameterActive: 0\n  m_MirrorParameterActive: 0\n"
            "  m_CycleOffsetParameterActive: 0\n  m_TimeParameterActive: 0\n  m_Motion: {fileID: 7400000, guid: %s, type: 2}\n  m_Tag: \n  m_SpeedParameter: \n  m_MirrorParameter: \n  m_CycleOffsetParameter: \n  m_TimeParameter: \n"
            % (fid, name, ("\n" + "".join("  - {fileID: %d}\n" % t for t in transitions)) if transitions else " []\n", clip))


def _transition(fid, mode, parameter, to, duration):
    """mode: 1 if the bool is true, 2 if it is false."""
    return ("--- !u!1101 &%d\nAnimatorStateTransition:\n  m_ObjectHideFlags: 1\n  m_CorrespondingSourceObject: {fileID: 0}\n  m_PrefabInstance: {fileID: 0}\n  m_PrefabAsset: {fileID: 0}\n  m_Name: \n  m_Conditions:\n"
            "  - m_ConditionMode: %d\n    m_ConditionEvent: %s\n    m_EventTreshold: 0\n  m_DstStateMachine: {fileID: 0}\n  m_DstState: {fileID: %d}\n  m_Solo: 0\n  m_Mute: 0\n  m_IsExit: 0\n  serializedVersion: 3\n"
            "  m_TransitionDuration: %s\n  m_TransitionOffset: 0\n  m_ExitTime: 0.75\n  m_HasExitTime: 0\n  m_HasFixedDuration: 1\n  m_InterruptionSource: 0\n  m_OrderedInterruption: 1\n  m_CanTransitionToSelf: 1\n"
            % (fid, mode, parameter, to, num(duration)))


def write_animations(out):
    """Anim/: clips that animate the RectTransform "Knob" below the animator's object (as Unity
    records them: the anchored position, with the local position beside it), and a controller
    with two states switched by the bool "On" (vrcbce's slide toggles)."""
    folder = os.path.join(out, "Anim")
    os.makedirs(folder, exist_ok=True)

    def write(name, data, guid, importer="NativeFormatImporter", main=7400000):
        with open(os.path.join(folder, name), "w") as fh:
            fh.write(data)
        with open(os.path.join(folder, name + ".meta"), "w") as fh:
            fh.write("fileFormatVersion: 2\nguid: %s\n%s:\n  externalObjects: {}\n  mainObjectFileID: %d\n  userData: \n  assetBundleName: \n  assetBundleVariant: \n" % (guid, importer, main))
    with open(os.path.join(out, "Anim.meta"), "w") as fh:
        fh.write("fileFormatVersion: 2\nguid: a4a7c1d2e3b44f5a8697a1b2c3d4e5f6\nfolderAsset: yes\nDefaultImporter:\n  externalObjects: {}\n  userData: \n  assetBundleName: \n  assetBundleVariant: \n")

    def pose(x):
        return [_curve("Knob", "m_LocalPosition.x", [(0, x)]), _curve("Knob", "m_LocalPosition.y", [(0, 0)]), _curve("Knob", "m_LocalPosition.z", [(0, 0)]),
                _curve("Knob", "m_AnchoredPosition.x", [(0, x)]), _curve("Knob", "m_AnchoredPosition.y", [(0, 0)])]
    write("KnobLeft.anim", _clip("KnobLeft", pose(-70), 0), CLIP_LEFT)
    write("KnobRight.anim", _clip("KnobRight", pose(70), 0), CLIP_RIGHT)
    # one second: the knob crosses the track, grows from 40 x 40 to 60 x 40 and to twice its scale
    write("KnobSlide.anim", _clip("KnobSlide", [
        _curve("Knob", "m_AnchoredPosition.x", [(0, -70), (1, 70)]), _curve("Knob", "m_AnchoredPosition.y", [(0, 0), (1, 10)]),
        _curve("Knob", "m_SizeDelta.x", [(0, 40), (1, 60)]),
        _curve("Knob", "m_LocalScale.x", [(0, 1), (1, 2)]), _curve("Knob", "m_LocalScale.y", [(0, 1), (1, 2)]), _curve("Knob", "m_LocalScale.z", [(0, 1), (1, 1)]),
    ], 1), CLIP_SLIDE)
    controller = ("%YAML 1.1\n%TAG !u! tag:unity3d.com,2011:\n--- !u!91 &9100000\nAnimatorController:\n  m_ObjectHideFlags: 0\n  m_CorrespondingSourceObject: {fileID: 0}\n  m_PrefabInstance: {fileID: 0}\n  m_PrefabAsset: {fileID: 0}\n  m_Name: Knob\n  serializedVersion: 5\n"
                  "  m_AnimatorParameters:\n  - m_Name: On\n    m_Type: 4\n    m_DefaultFloat: 0\n    m_DefaultInt: 0\n    m_DefaultBool: 0\n    m_Controller: {fileID: 0}\n"
                  "  m_AnimatorLayers:\n  - serializedVersion: 5\n    m_Name: Base Layer\n    m_StateMachine: {fileID: 1107000000000000001}\n    m_Mask: {fileID: 0}\n    m_Motions: []\n    m_Behaviours: []\n    m_BlendingMode: 0\n    m_SyncedLayerIndex: -1\n"
                  "    m_DefaultWeight: 0\n    m_IKPass: 0\n    m_SyncedLayerAffectsTiming: 0\n    m_Controller: {fileID: 9100000}\n"
                  + _transition(1101000000000000001, 1, "On", 1102000000000000002, 0.25)     # Left → Right while On
                  + _transition(1101000000000000002, 2, "On", 1102000000000000001, 0.25)     # Right → Left while not
                  + _state(1102000000000000001, "Left", CLIP_LEFT, [1101000000000000001])
                  + _state(1102000000000000002, "Right", CLIP_RIGHT, [1101000000000000002])
                  + _state(1102000000000000003, "Slide", CLIP_SLIDE, [])                     # (reached by no transition: played by name)
                  + "--- !u!1107 &1107000000000000001\nAnimatorStateMachine:\n  serializedVersion: 5\n  m_ObjectHideFlags: 1\n  m_CorrespondingSourceObject: {fileID: 0}\n  m_PrefabInstance: {fileID: 0}\n  m_PrefabAsset: {fileID: 0}\n  m_Name: Base Layer\n"
                  "  m_ChildStates:\n  - serializedVersion: 1\n    m_State: {fileID: 1102000000000000001}\n    m_Position: {x: 288, y: 120, z: 0}\n  - serializedVersion: 1\n    m_State: {fileID: 1102000000000000002}\n    m_Position: {x: 552, y: 120, z: 0}\n  - serializedVersion: 1\n    m_State: {fileID: 1102000000000000003}\n    m_Position: {x: 552, y: 240, z: 0}\n"
                  "  m_ChildStateMachines: []\n  m_AnyStateTransitions: []\n  m_EntryTransitions: []\n  m_StateMachineTransitions: {}\n  m_StateMachineBehaviours: []\n  m_AnyStatePosition: {x: 50, y: 20, z: 0}\n  m_EntryPosition: {x: 50, y: 120, z: 0}\n"
                  "  m_ExitPosition: {x: 800, y: 120, z: 0}\n  m_ParentStateMachinePosition: {x: 800, y: 20, z: 0}\n  m_DefaultState: {fileID: 1102000000000000001}\n")
    write("Knob.controller", controller, KNOB_CONTROLLER, main=9100000)

    # "Show": clips on the objects of a panel, each in a state of its own (played by name)
    half = lambda a, b: [(0, a), (0.49, a), (0.51, b), (1, b)]   # a switch half way
    write("ShowRest.anim", _clip("ShowRest", [_curve("Dial", "m_SizeDelta.x", [(0, 60)])], 0), CLIP_SHOW_REST)
    # rotation, scale and position come in curve lists without a class id
    write("ShowTurn.anim", _clip("ShowTurn", [], 1,
                                 euler=[_vcurve("Dial", [(0, (0, 0, 0)), (1, (0, 0, 90))])],
                                 scale=[_vcurve("Dial", [(0, (1, 1, 1)), (1, (2, 2, 1))])],
                                 position=[_vcurve("Holder", [(0, (-80, 90, 0)), (1, (-40, 70, 0))])]), CLIP_SHOW_TURN)
    # fields of components
    write("ShowFade.anim", _clip("ShowFade", [
        _curve("Dial", "m_Color.a", [(0, 1), (1, 0)], script="Image"), _curve("Dial", "m_Color.r", [(0, 1), (1, 0.5)], script="Image"),
        _curve("Label", "m_fontColor.a", [(0, 1), (1, 0.5)], script="TextMeshProUGUI"), _curve("Label", "m_fontSize", [(0, 20), (1, 40)], script="TextMeshProUGUI"),
        _curve("Bar", "m_FillAmount", [(0, 0.25), (1, 0.75)], script="Image"),
        _curve("Group", "m_Alpha", [(0, 1), (1, 0.5)], class_id=225),
        _curve("Blink", "m_Enabled", half(1, 0), script="Image"),
        _curve("Hide", "m_IsActive", half(1, 0), class_id=1),
        _curve("Level", "m_Value", [(0, 0), (1, 1)], script="Slider"),
        _curve("Check", "m_IsOn", half(0, 1), script="Toggle"),
        _curve("Go", "m_Interactable", half(1, 0), script="Button"),
    ], 1), CLIP_SHOW_FADE)
    # the sprite of an Image, switched half way
    write("ShowFrames.anim", _clip("ShowFrames", [], 1, pptr=[_pptr("Icon", "m_Sprite", [(0, SHEET_LEFT), (0.5, SHEET_RIGHT)], "Image")]), CLIP_SHOW_FRAMES)
    states = [(1102000000000000011, "Rest", CLIP_SHOW_REST), (1102000000000000012, "Turn", CLIP_SHOW_TURN), (1102000000000000013, "Fade", CLIP_SHOW_FADE), (1102000000000000014, "Frames", CLIP_SHOW_FRAMES)]
    show = ("%YAML 1.1\n%TAG !u! tag:unity3d.com,2011:\n--- !u!91 &9100000\nAnimatorController:\n  m_ObjectHideFlags: 0\n  m_CorrespondingSourceObject: {fileID: 0}\n  m_PrefabInstance: {fileID: 0}\n  m_PrefabAsset: {fileID: 0}\n  m_Name: Show\n  serializedVersion: 5\n"
            "  m_AnimatorParameters: []\n"
            "  m_AnimatorLayers:\n  - serializedVersion: 5\n    m_Name: Base Layer\n    m_StateMachine: {fileID: 1107000000000000011}\n    m_Mask: {fileID: 0}\n    m_Motions: []\n    m_Behaviours: []\n    m_BlendingMode: 0\n    m_SyncedLayerIndex: -1\n"
            "    m_DefaultWeight: 0\n    m_IKPass: 0\n    m_SyncedLayerAffectsTiming: 0\n    m_Controller: {fileID: 9100000}\n"
            + "".join(_state(fid, name, clip, []) for fid, name, clip in states)
            + "--- !u!1107 &1107000000000000011\nAnimatorStateMachine:\n  serializedVersion: 5\n  m_ObjectHideFlags: 1\n  m_CorrespondingSourceObject: {fileID: 0}\n  m_PrefabInstance: {fileID: 0}\n  m_PrefabAsset: {fileID: 0}\n  m_Name: Base Layer\n"
            "  m_ChildStates:\n" + "".join("  - serializedVersion: 1\n    m_State: {fileID: %d}\n    m_Position: {x: 288, y: %d, z: 0}\n" % (fid, 120 * (i + 1)) for i, (fid, _n, _c) in enumerate(states))
            + "  m_ChildStateMachines: []\n  m_AnyStateTransitions: []\n  m_EntryTransitions: []\n  m_StateMachineTransitions: {}\n  m_StateMachineBehaviours: []\n  m_AnyStatePosition: {x: 50, y: 20, z: 0}\n  m_EntryPosition: {x: 50, y: 120, z: 0}\n"
            "  m_ExitPosition: {x: 800, y: 120, z: 0}\n  m_ParentStateMachinePosition: {x: 800, y: 20, z: 0}\n  m_DefaultState: {fileID: 1102000000000000011}\n")
    write("Show.controller", show, SHOW_CONTROLLER, main=9100000)

    # "Press": what Unity generates for a Selectable with an animation transition: a trigger and
    # a state for each selection state, reached from any state; the clips scale the object itself
    def scale(v):
        return [_curve("", "m_LocalScale.x", [(0, v)]), _curve("", "m_LocalScale.y", [(0, v)]), _curve("", "m_LocalScale.z", [(0, 1)])]
    write("PressNormal.anim", _clip("PressNormal", scale(1), 0), CLIP_PRESS_NORMAL)
    write("PressOver.anim", _clip("PressOver", scale(1.2), 0), CLIP_PRESS_OVER)
    write("PressDown.anim", _clip("PressDown", scale(0.9), 0), CLIP_PRESS_DOWN)
    press_states = [("Normal", CLIP_PRESS_NORMAL), ("Highlighted", CLIP_PRESS_OVER), ("Pressed", CLIP_PRESS_DOWN), ("Selected", CLIP_PRESS_OVER), ("Disabled", CLIP_PRESS_NORMAL)]
    press = ("%YAML 1.1\n%TAG !u! tag:unity3d.com,2011:\n--- !u!91 &9100000\nAnimatorController:\n  m_ObjectHideFlags: 0\n  m_CorrespondingSourceObject: {fileID: 0}\n  m_PrefabInstance: {fileID: 0}\n  m_PrefabAsset: {fileID: 0}\n  m_Name: Press\n  serializedVersion: 5\n"
             "  m_AnimatorParameters:\n" + "".join("  - m_Name: %s\n    m_Type: 9\n    m_DefaultFloat: 0\n    m_DefaultInt: 0\n    m_DefaultBool: 0\n    m_Controller: {fileID: 0}\n" % name for name, _c in press_states)
             + "  m_AnimatorLayers:\n  - serializedVersion: 5\n    m_Name: Base Layer\n    m_StateMachine: {fileID: 1107000000000000031}\n    m_Mask: {fileID: 0}\n    m_Motions: []\n    m_Behaviours: []\n    m_BlendingMode: 0\n    m_SyncedLayerIndex: -1\n"
             "    m_DefaultWeight: 0\n    m_IKPass: 0\n    m_SyncedLayerAffectsTiming: 0\n    m_Controller: {fileID: 9100000}\n"
             + "".join(_transition(1101000000000000031 + i, 1, name, 1102000000000000031 + i, 0.1) for i, (name, _c) in enumerate(press_states))
             + "".join(_state(1102000000000000031 + i, name, clip, []) for i, (name, clip) in enumerate(press_states))
             + "--- !u!1107 &1107000000000000031\nAnimatorStateMachine:\n  serializedVersion: 5\n  m_ObjectHideFlags: 1\n  m_CorrespondingSourceObject: {fileID: 0}\n  m_PrefabInstance: {fileID: 0}\n  m_PrefabAsset: {fileID: 0}\n  m_Name: Base Layer\n"
             "  m_ChildStates:\n" + "".join("  - serializedVersion: 1\n    m_State: {fileID: %d}\n    m_Position: {x: 288, y: %d, z: 0}\n" % (1102000000000000031 + i, 120 * (i + 1)) for i in range(len(press_states)))
             + "  m_ChildStateMachines: []\n  m_AnyStateTransitions:\n" + "".join("  - {fileID: %d}\n" % (1101000000000000031 + i) for i in range(len(press_states)))
             + "  m_EntryTransitions: []\n  m_StateMachineTransitions: {}\n  m_StateMachineBehaviours: []\n  m_AnyStatePosition: {x: 50, y: 20, z: 0}\n  m_EntryPosition: {x: 50, y: 120, z: 0}\n"
             "  m_ExitPosition: {x: 800, y: 120, z: 0}\n  m_ParentStateMachinePosition: {x: 800, y: 20, z: 0}\n  m_DefaultState: {fileID: 1102000000000000031}\n")
    write("Press.controller", press, PRESS_CONTROLLER, main=9100000)


def text(value, size=14, color=(0, 0, 0, 1), align=4, style=0, best_fit=False, sizes=(10, 40), rich=True, overflow=(0, 0)):
    return ("Text", _GRAPHIC % vec(color, "rgba") + "  m_FontData:\n    m_Font: {fileID: 10102, guid: 0000000000000000e000000000000000, type: 0}\n    m_FontSize: %d\n    m_FontStyle: %d\n    m_BestFit: %d\n    m_MinSize: %d\n    m_MaxSize: %d\n    m_Alignment: %d\n    m_AlignByGeometry: 0\n    m_RichText: %d\n    m_HorizontalOverflow: %d\n    m_VerticalOverflow: %d\n    m_LineSpacing: 1\n  m_Text: %s\n" % (
        size, style, best_fit, sizes[0], sizes[1], align, rich, overflow[0], overflow[1], quoted(value)))


TMP_DEFAULT_FONT = "8f586378b4e144a9851e7b34d9b748ee"   # LiberationSans SDF of TextMeshPro's essentials: not in the project
FONT_FILE = "f0a7c1d2e3b44f5a8697a1b2c3d4e5f6"          # Fonts/Calistoga.ttf (SIL Open Font License, Fonts/OFL.txt)
FONT_ASSET = "f1a7c1d2e3b44f5a8697a1b2c3d4e5f6"         # Fonts/Calistoga SDF.asset: a font asset made from it
FONT_ASSET_LOST = "f2a7c1d2e3b44f5a8697a1b2c3d4e5f6"    # Fonts/Lost SDF.asset: its source font is not in the project


def tmp(value, size=36, color=(1, 1, 1, 1), style=0, auto=False, sizes=(18, 72), wrap=True, overflow=0, halign=1, valign=256, rich=True, font=TMP_DEFAULT_FONT):
    """TextMeshProUGUI. style: 1 bold, 2 italic, 4 underline, 8 lower, 16 upper, 32 small caps;
    halign 1 left, 2 centre, 4 right; valign 256 top, 512 middle, 1024 bottom; font: guid of
    the font asset."""
    return ("TextMeshProUGUI", _GRAPHIC % vec((1, 1, 1, 1), "rgba") + (
        "  m_text: %s\n  m_isRightToLeft: 0\n  m_fontAsset: {fileID: 11400000, guid: " + font + ", type: 2}\n"
        "  m_sharedMaterial: {fileID: 2180264, guid: " + font + ", type: 2}\n  m_fontColor32:\n    serializedVersion: 2\n    rgba: 4294967295\n"
        "  m_fontColor: %s\n  m_enableVertexGradient: 0\n  m_fontSize: %s\n  m_fontSizeBase: %s\n  m_fontWeight: 400\n  m_enableAutoSizing: %d\n  m_fontSizeMin: %s\n  m_fontSizeMax: %s\n"
        "  m_fontStyle: %d\n  m_HorizontalAlignment: %d\n  m_VerticalAlignment: %d\n  m_textAlignment: 65535\n  m_characterSpacing: 0\n  m_lineSpacing: 0\n"
        "  m_enableWordWrapping: %d\n  m_overflowMode: %d\n  m_isRichText: %d\n  m_margin: {x: 0, y: 0, z: 0, w: 0}\n") % (
        quoted(value), vec(color, "rgba"), num(size), num(size), auto, num(sizes[0]), num(sizes[1]), style, halign, valign, wrap, overflow, rich))


def selectable(target=0, transition=1, normal=(1, 1, 1, 1), highlighted=(0.96, 0.96, 0.96, 1), pressed=(0.78, 0.78, 0.78, 1), selected=(0.96, 0.96, 0.96, 1), disabled=(0.78, 0.78, 0.78, 0.5), multiplier=1, interactable=True, sprites=None, fade=0.1):
    """The fields every Selectable serializes. target: file id of the target Graphic component;
    sprites: {state: (file id, guid)} of a sprite swap (states: Highlighted, Pressed, Selected,
    Disabled)."""
    def sprite(state):
        ref = (sprites or {}).get(state)
        return "{fileID: 0}" if ref is None else "{fileID: %d, guid: %s, type: 3}" % ref
    return ("  m_Navigation:\n    m_Mode: 3\n    m_WrapAround: 0\n    m_SelectOnUp: {fileID: 0}\n    m_SelectOnDown: {fileID: 0}\n    m_SelectOnLeft: {fileID: 0}\n    m_SelectOnRight: {fileID: 0}\n"
            "  m_Transition: %d\n  m_Colors:\n    m_NormalColor: %s\n    m_HighlightedColor: %s\n    m_PressedColor: %s\n    m_SelectedColor: %s\n    m_DisabledColor: %s\n    m_ColorMultiplier: %s\n    m_FadeDuration: %s\n"
            "  m_SpriteState:\n    m_HighlightedSprite: %s\n    m_PressedSprite: %s\n    m_SelectedSprite: %s\n    m_DisabledSprite: %s\n"
            "  m_AnimationTriggers:\n    m_NormalTrigger: Normal\n    m_HighlightedTrigger: Highlighted\n    m_PressedTrigger: Pressed\n    m_SelectedTrigger: Selected\n    m_DisabledTrigger: Disabled\n"
            "  m_Interactable: %d\n  m_TargetGraphic: {fileID: %d}\n") % (
        transition, vec(normal, "rgba"), vec(highlighted, "rgba"), vec(pressed, "rgba"), vec(selected, "rgba"), vec(disabled, "rgba"), num(multiplier), num(fade),
        sprite("Highlighted"), sprite("Pressed"), sprite("Selected"), sprite("Disabled"), interactable, target)


def button(**sel):
    return ("Button", selectable(**sel) + "  m_OnClick:\n    m_PersistentCalls:\n      m_Calls: []\n")


def toggle(on=False, graphic=0, **sel):
    return ("Toggle", selectable(**sel) + "  toggleTransition: 1\n  graphic: {fileID: %d}\n  m_Group: {fileID: 0}\n  onValueChanged:\n    m_PersistentCalls:\n      m_Calls: []\n  m_IsOn: %d\n" % (graphic, 1 if on else 0))


def slider(value=0.5, direction=0, fill=0, handle=0, lo=0, hi=1, whole=False, **sel):
    """fill / handle: file ids of RectTransforms."""
    return ("Slider", selectable(**sel) + "  m_FillRect: {fileID: %d}\n  m_HandleRect: {fileID: %d}\n  m_Direction: %d\n  m_MinValue: %s\n  m_MaxValue: %s\n  m_WholeNumbers: %d\n  m_Value: %s\n  m_OnValueChanged:\n    m_PersistentCalls:\n      m_Calls: []\n" % (
        fill, handle, direction, num(lo), num(hi), whole, num(value)))


def input_field(value="", text_component=0, placeholder=0, **sel):
    return ("InputField", selectable(**sel) + "  m_TextComponent: {fileID: %d}\n  m_Placeholder: {fileID: %d}\n  m_ContentType: 0\n  m_InputType: 0\n  m_AsteriskChar: 42\n  m_KeyboardType: 0\n  m_LineType: 0\n  m_HideMobileInput: 0\n  m_CharacterValidation: 0\n  m_CharacterLimit: 0\n  m_OnSubmit:\n    m_PersistentCalls:\n      m_Calls: []\n  m_OnDidEndEdit:\n    m_PersistentCalls:\n      m_Calls: []\n  m_OnValueChanged:\n    m_PersistentCalls:\n      m_Calls: []\n  m_CaretColor: {r: 0.2, g: 0.2, b: 0.2, a: 1}\n  m_CustomCaretColor: 0\n  m_SelectionColor: {r: 0.66, g: 0.81, b: 1, a: 0.75}\n  m_Text: %s\n  m_CaretBlinkRate: 0.85\n  m_CaretWidth: 1\n  m_ReadOnly: 0\n  m_ShouldActivateOnSelect: 1\n" % (
        text_component, placeholder, value))


def scroll_rect(content, viewport=0, hbar=0, vbar=0, horizontal=True, vertical=True, movement=1, visibility=(2, 2), spacing=(-3, -3)):
    """content / viewport: RectTransform file ids; hbar / vbar: Scrollbar component file ids;
    movement 0 unrestricted, 1 elastic, 2 clamped; visibility 0 permanent, 1 auto hide,
    2 auto hide and expand the viewport."""
    return ("ScrollRect", "  m_Content: {fileID: %d}\n  m_Horizontal: %d\n  m_Vertical: %d\n  m_MovementType: %d\n  m_Elasticity: 0.1\n  m_Inertia: 1\n  m_DecelerationRate: 0.135\n  m_ScrollSensitivity: 1\n  m_Viewport: {fileID: %d}\n  m_HorizontalScrollbar: {fileID: %d}\n  m_VerticalScrollbar: {fileID: %d}\n  m_HorizontalScrollbarVisibility: %d\n  m_VerticalScrollbarVisibility: %d\n  m_HorizontalScrollbarSpacing: %s\n  m_VerticalScrollbarSpacing: %s\n  m_OnValueChanged:\n    m_PersistentCalls:\n      m_Calls: []\n" % (
        content, horizontal, vertical, movement, viewport, hbar, vbar, visibility[0], visibility[1], num(spacing[0]), num(spacing[1])))


def scrollbar(handle=0, direction=0, value=0, size=0.2, steps=0, **sel):
    """direction 0 left to right, 1 right to left, 2 bottom to top, 3 top to bottom."""
    return ("Scrollbar", selectable(**sel) + "  m_HandleRect: {fileID: %d}\n  m_Direction: %d\n  m_Value: %s\n  m_Size: %s\n  m_NumberOfSteps: %d\n  m_OnValueChanged:\n    m_PersistentCalls:\n      m_Calls: []\n" % (handle, direction, num(value), num(size), steps))


def dropdown(options, value=0, template=0, caption=0, item_text=0, **sel):
    """template: RectTransform file id; caption / item_text: Text component file ids."""
    opts = "".join("    - m_Text: %s\n      m_Image: {fileID: 0}\n" % quoted(o) for o in options)
    return ("Dropdown", selectable(**sel) + "  m_Template: {fileID: %d}\n  m_CaptionText: {fileID: %d}\n  m_CaptionImage: {fileID: 0}\n  m_ItemText: {fileID: %d}\n  m_ItemImage: {fileID: 0}\n  m_Value: %d\n  m_Options:\n    m_Options:\n%s  m_OnValueChanged:\n    m_PersistentCalls:\n      m_Calls: []\n  m_AlphaFadeSpeed: 0.15\n" % (
        template, caption, item_text, value, opts))


def rect_mask():
    return ("RectMask2D", "  m_Padding: {x: 0, y: 0, z: 0, w: 0}\n  m_Softness: {x: 0, y: 0}\n")


def mask(show=True):
    return ("Mask", "  m_ShowMaskGraphic: %d\n" % show)


def canvas_group(alpha=1.0, interactable=True, blocks=True, ignore_parents=False):
    return ("CanvasGroup", "  m_Alpha: %s\n  m_Interactable: %d\n  m_BlocksRaycasts: %d\n  m_IgnoreParentGroups: %d\n" % (num(alpha), interactable, blocks, ignore_parents))


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


def panel_prefab():
    """A UI prefab with one of each component an instance may override."""
    f = UnityFile("0c11ca5e000000000000000000000003")
    b = Builder(f)
    root = b.img("Panel", None, {"size": (260, 170)}, color=(0.2, 0.22, 0.28, 1))
    title = f.node("Title", root, {"amin": (0, 1), "amax": (1, 1), "pivot": (0.5, 1), "pos": (0, -4), "size": (-8, 28)}, [renderer(), tmp("Title", 20, halign=2, valign=512)])
    note = f.node("Note", root, {"amin": (0, 1), "amax": (1, 1), "pivot": (0.5, 1), "pos": (0, -34), "size": (-8, 22)}, [renderer(), text("note", 14, (1, 1, 1, 1))])
    icon = b.img("Icon", root, {"amin": (0, 0), "amax": (0, 0), "pivot": (0, 0), "pos": (8, 8), "size": (36, 36)}, color=(0.2, 0.7, 0.9, 1))
    go = f.node("Go", root, {"amin": (1, 0), "amax": (1, 0), "pivot": (1, 0), "pos": (-8, 8), "size": (70, 26)}, [renderer(), image((1, 1, 1, 1))])
    f.node("Label", go, {"amin": (0, 0), "amax": (1, 1), "size": (0, 0)}, [renderer(), text("Go", 12, (0, 0, 0, 1))])
    go_button = f.add(go, button(target=go.components[1][0]))
    check = b.box("Check", root, {"amin": (0, 0), "amax": (0, 0), "pivot": (0, 0), "pos": (52, 8), "size": (24, 24)})
    back = b.img("Background", check, {"amin": (0, 0), "amax": (1, 1), "size": (0, 0)}, color=(0.9, 0.9, 0.9, 1))
    mark = b.img("Checkmark", back, {"amin": (0, 0), "amax": (1, 1), "size": (-8, -8)}, color=(0.1, 0.1, 0.1, 1))
    check_toggle = f.add(check, toggle(False, mark.components[1][0], target=back.components[1][0]))
    level = b.box("Level", root, {"amin": (0, 0), "amax": (1, 0), "pivot": (0.5, 0), "pos": (0, 50), "size": (-16, 14)})
    b.img("Background", level, {"amin": (0, 0), "amax": (1, 1), "size": (0, 0)}, color=(0.3, 0.3, 0.3, 1))
    area = b.box("Fill Area", level, {"amin": (0, 0), "amax": (1, 1), "size": (-10, -4)})
    fill = b.img("Fill", area, {"amin": (0, 0), "amax": (0.5, 1), "size": (0, 0)}, color=(0.3, 0.8, 0.4, 1))
    harea = b.box("Handle Slide Area", level, {"amin": (0, 0), "amax": (1, 1), "size": (-10, 0)})
    knob = b.img("Handle", harea, {"amin": (0.5, 0), "amax": (0.5, 1), "size": (10, 0)}, color=(0.95, 0.95, 0.95, 1))
    level_slider = f.add(level, slider(0.5, 0, fill.t, knob.t, target=knob.components[1][0]))
    row = b.box("Row", root, {"amin": (0, 0), "amax": (1, 0), "pivot": (0.5, 0), "pos": (0, 72), "size": (-16, 30)})
    row_group = f.add(row, hgroup(padding=(2, 2, 2, 2), spacing=4, control=(True, True), expand=(False, True)))
    cell_a = b.img("A", row, {"size": (10, 10)}, color=(0.9, 0.3, 0.3, 1))
    cell_a_element = f.add(cell_a, element(pref=(40, -1)))
    cell_b = b.img("B", row, {"size": (10, 10)}, color=(0.3, 0.4, 0.9, 1))
    f.add(cell_b, element(pref=(60, -1)))
    ids = {"root": root, "title": title.components[1][0], "note": note.components[1][0], "icon": icon.components[1][0], "go_image": go.components[1][0], "go": go_button,
           "check": check_toggle, "level": level_slider, "row": row_group, "cell_a": cell_a_element}
    return f, ids


def board_prefab():
    """A prefab whose root is a world canvas (400 x 200 at scale 0.002)."""
    f = UnityFile("0c11ca5e000000000000000000000002")
    b = Builder(f)
    root = f.node("Board", None, {"size": (400, 200), "scale": 0.002, "amin": (0, 0), "amax": (0, 0)}, [canvas(2), scaler(), raycaster()])
    b.img("Back", root, {"amin": (0, 0), "amax": (1, 1), "size": (0, 0)}, color=(0.15, 0.2, 0.3, 1))
    b.img("Lamp", root, {"amin": (1, 1), "amax": (1, 1), "pivot": (1, 1), "pos": (-10, -10), "size": (50, 50)}, color=(1, 0.9, 0.3, 1))
    b.f.node("Go", root, {"pos": (0, -40), "size": (160, 50)}, [renderer(), image((0.3, 0.8, 0.4, 1)), button()])
    return f, {"root": root, "lamp": f.objects[2]}


def build_scene(card, card_ids, board, board_ids, widgets, widget_ids):
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
    # a container of 100 x 100 metres (a RectTransform's default size on a canvas of scale 1) with
    # scaled-down items at fractions of a metre: an engine that rounds control origins to whole
    # units of the parent draws them up to half a metre away
    menu = b.box("Menu", c, {"pos": (0.31, -0.07), "size": (100, 100)})
    b.img("MenuItem", menu, {"pos": (0, 0), "size": (300, 100), "scale": 0.0005}, color=(0.9, 0.2, 0.6, 1))
    b.img("MenuItemLeft", menu, {"pos": (-0.2, 0.04), "size": (200, 100), "scale": 0.0004}, color=(0.2, 0.9, 0.6, 1))
    f.node("MenuButton", menu, {"pos": (0.16, 0.03), "size": (250, 100), "scale": 0.0004}, [renderer(), image((0.6, 0.6, 0.2, 1)), button()])

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
    # ---- Overrides: components of prefab instances, overridden --------------------------------
    c = b.world_canvas("Overrides", (5.0, 3.0, 2), (900, 400))
    b.img("Back", c, {"amin": (0, 0), "amax": (1, 1), "size": (0, 0)}, color=(0.1, 0.1, 0.12, 1))
    rt = widget_ids["root"].t
    f.instance(widgets, c, "PanelPlain", [(rt, "m_AnchoredPosition.x", -300), (rt, "m_AnchoredPosition.y", 0)])
    f.instance(widgets, c, "PanelChanged", [
        (rt, "m_AnchoredPosition.x", 0), (rt, "m_AnchoredPosition.y", 0),
        (widget_ids["title"], "m_text", "<b>Changed</b> title"), (widget_ids["title"], "m_fontSize", 24), (widget_ids["title"], "m_fontColor.g", 0.5), (widget_ids["title"], "m_fontStyle", 16),
        (widget_ids["note"], "m_Text", "another note"), (widget_ids["note"], "m_FontData.m_FontSize", 18), (widget_ids["note"], "m_Color.b", 0),
        (widget_ids["icon"], "m_Color.r", 1), (widget_ids["icon"], "m_Color.a", 0.5),
        (widget_ids["go"], "m_Colors.m_NormalColor.a", 0),
        (widget_ids["check"], "m_IsOn", 1),
        (widget_ids["level"], "m_Value", 0.9),
        (widget_ids["row"], "m_Spacing", 20), (widget_ids["row"], "m_Padding.m_Left", 10), (widget_ids["cell_a"], "m_PreferredWidth", 100),
    ])
    f.instance(widgets, c, "PanelOff", [
        (rt, "m_AnchoredPosition.x", 300), (rt, "m_AnchoredPosition.y", 0),
        (widget_ids["title"], "m_Enabled", 0),
        (widget_ids["note"], "m_Enabled", 0),
        (widget_ids["icon"], "m_Enabled", 0),
        (widget_ids["go"], "m_Interactable", 0), (widget_ids["go"], "m_Colors.m_DisabledColor.r", 1), (widget_ids["go"], "m_Colors.m_DisabledColor.a", 1),
        (widget_ids["check"], "m_Interactable", 0), (widget_ids["check"], "m_IsOn", 1),
        (widget_ids["level"], "m_Direction", 1), (widget_ids["level"], "m_Value", 0.25),
        (widget_ids["row"], "m_ChildAlignment", 5), (widget_ids["cell_a"], "m_IgnoreLayout", 1),
    ])

    # ---- Sprites: Images that are not simply stretched ------------------------------------------
    c = b.world_canvas("Sprites", (6.2, 3.0, 2), (900, 600))
    b.img("Back", c, {"amin": (0, 0), "amax": (1, 1), "size": (0, 0)}, color=(0.12, 0.14, 0.12, 1))

    def sprite(name, pos, size, comps=(), **kw):
        return f.node(name, c, {"pos": pos, "size": size}, [renderer(), image(**kw)] + list(comps))
    sprite("Simple", (-380, 240), (64, 64), sprite=FRAME)                                  # the whole sprite, stretched
    sprite("SimpleWide", (-270, 240), (128, 64), sprite=FRAME)
    sprite("Sliced", (-100, 240), (200, 100), kind=1, sprite=FRAME)                        # 16 unit borders
    sprite("SlicedSmall", (60, 240), (20, 80), kind=1, sprite=FRAME)                       # the x borders shrink to 10
    sprite("SlicedTiny", (110, 240), (24, 24), kind=1, sprite=FRAME)                       # both shrink
    sprite("SlicedMultiplier", (240, 240), (160, 60), kind=1, sprite=FRAME, multiplier=2)  # 8 unit borders
    sprite("SlicedHollow", (-100, 110), (200, 100), kind=1, sprite=FRAME, center=False)    # no centre
    sprite("SlicedTinted", (120, 110), (160, 60), kind=1, sprite=FRAME, color=(0.5, 0.5, 1, 1))
    sliced_button = sprite("SlicedButton", (320, 110), (160, 60), kind=1, sprite=FRAME)
    f.node("Label", sliced_button, {"amin": (0, 0), "amax": (1, 1), "size": (0, 0)}, [renderer(), text("sliced", 14, (0, 0, 0, 1))])
    f.add(sliced_button, button(target=sliced_button.components[1][0]))
    sprite("SlicedNoBorder", (-380, 130), (64, 100), kind=1, sprite=BAR)                   # sliced without borders: stretched
    sprite("Tiled", (-300, -20), (150, 90), kind=2, sprite=FRAME)                          # borders, the centre tiled 3.7 x 1.8 times from the bottom-left
    sprite("TiledPlain", (-300, -95), (160, 40), kind=2, sprite=BAR)                       # no borders: 2.5 x 2.5 copies
    sprite("TiledHollow", (-180, -95), (60, 40), kind=2, sprite=FRAME, center=False)       # only the border pieces
    sprite("FillLeft", (-100, 10), (128, 32), kind=3, sprite=BAR, fill=(0, 0.25, 0))       # the left quarter
    sprite("FillRight", (-100, -40), (128, 32), kind=3, sprite=BAR, fill=(0, 0.75, 1))     # the right three quarters
    sprite("FillBottom", (20, -20), (64, 96), kind=3, sprite=FRAME, fill=(1, 0.5, 0))      # the lower half
    sprite("FillTop", (100, -20), (64, 96), kind=3, sprite=FRAME, fill=(1, 0.25, 1))       # the upper quarter
    sprite("FillFull", (180, -20), (64, 96), kind=3, sprite=FRAME, fill=(0, 1, 0))
    # radial fills: the angle is swept in the rect's own proportions, from the origin
    # (360: bottom, right, top, left; 180: bottom, left, top, right; 90: the corners from the
    # bottom-left, clockwise), clockwise or not
    for i, (method, amount, origin, clockwise) in enumerate([
            (4, 0.25, 0, 1), (4, 0.6, 1, 1), (4, 0.4, 2, 0), (4, 0.875, 3, 0), (4, 0.1, 0, 0),
            (3, 0.3, 0, 1), (3, 0.75, 1, 1), (3, 0.5, 2, 0), (3, 0.6, 3, 0),
            (2, 0.5, 0, 1), (2, 0.3, 1, 1), (2, 0.7, 2, 0), (2, 0.4, 3, 1)]):
        sprite("Radial%d_%d%s" % ({4: 360, 3: 180, 2: 90}[method], origin, "" if clockwise else "ccw"),
               (-400 + 66 * i, -240), (56, 80 if i % 2 else 56), kind=3, sprite=FRAME, fill=(method, amount, origin, clockwise))
    sprite("RadialNoSprite", (250, -150), (56, 40), kind=3, fill=(4, 0.3, 0, 1), color=(0.9, 0.6, 0.2, 1))   # no sprite: the whole rect
    sprite("RadialFull", (320, -150), (56, 40), kind=3, sprite=FRAME, fill=(4, 1, 2, 0))
    sprite("RadialEmpty", (390, -150), (56, 40), kind=3, sprite=FRAME, fill=(3, 0, 0, 1))                    # nothing
    sprite("SheetLeft", (280, -20), (64, 64), sprite=SHEET_LEFT)
    sprite("SheetRight", (360, -20), (64, 64), sprite=SHEET_RIGHT)
    # Unity's built-in sprites, 200 pixels per unit: a 10 pixel border is 5 units
    sprite("BuiltinButton", (-340, -150), (160, 30), kind=1, sprite=UI_SPRITE)
    sprite("BuiltinField", (-160, -150), (160, 30), kind=1, sprite=INPUT_BACKGROUND)
    sprite("BuiltinBox", (-50, -150), (20, 20), kind=1, sprite=BACKGROUND)
    sprite("BuiltinCheck", (-20, -150), (20, 20), sprite=CHECKMARK)
    sprite("BuiltinKnob", (10, -150), (20, 20), sprite=KNOB)
    # what an Image asks for in a layout: its sprite's size in units, its borders when sliced
    row = b.box("Preferred", c, {"pos": (200, -160), "size": (400, 80)}, [hgroup(padding=(4, 4, 4, 4), spacing=6, control=(True, True), expand=(False, False))])
    f.node("WholeSprite", row, {"size": (10, 10)}, [renderer(), image(sprite=FRAME)])            # 64 x 64
    f.node("Borders", row, {"size": (10, 10)}, [renderer(), image(kind=1, sprite=FRAME)])        # 32 x 32
    f.node("Knob", row, {"size": (10, 10)}, [renderer(), image(sprite=KNOB)])                    # 20 x 20
    f.node("SheetHalf", row, {"size": (10, 10)}, [renderer(), image(sprite=SHEET_LEFT)])         # 32 x 32
    f.node("NoSprite", row, {"size": (10, 10)}, [renderer(), image()])                           # 0 x 0

    # ---- Fonts: TextMeshPro font assets --------------------------------------------------------
    # a font asset is an atlas made from a font file; where that file is in the project the
    # texts are drawn with it, otherwise with the stand-in family
    c = b.world_canvas("Fonts", (9.2, 3.0, 2), (700, 400))
    b.img("Back", c, {"amin": (0, 0), "amax": (1, 1), "size": (0, 0)}, color=(0.1, 0.1, 0.16, 1))
    f.node("FontRegular", c, {"pos": (0, 150), "size": (660, 50)}, [renderer(), tmp("Calistoga: 8-Ball Break", 36, font=FONT_ASSET)])
    f.node("FontBold", c, {"pos": (0, 90), "size": (660, 50)}, [renderer(), tmp("Bold from the same file", 36, style=1, font=FONT_ASSET)])
    f.node("FontItalic", c, {"pos": (0, 30), "size": (660, 50)}, [renderer(), tmp("Italic <b>and bold</b> by tags", 36, style=2, font=FONT_ASSET)])
    f.node("FontAuto", c, {"pos": (0, -30), "size": (660, 50)}, [renderer(), tmp("Auto sized in the font of the asset, as wide as its rect allows it to be", 60, auto=True, sizes=(8, 60), halign=2, valign=512, font=FONT_ASSET)])
    f.node("FontLost", c, {"pos": (0, -90), "size": (660, 50)}, [renderer(), tmp("A font asset without its font file", 36, font=FONT_ASSET_LOST)])
    f.node("FontDefault", c, {"pos": (0, -150), "size": (660, 50)}, [renderer(), tmp("The default font asset", 36)])

    # ---- Plain: plain Transforms inside a canvas --------------------------------------------------
    # an object without a RectTransform below a canvas has no rect: the RectTransforms below it
    # are still UI of that canvas, laid out against no parent rect, so their anchored position
    # is their local position (vrcbce's in-game UI hangs below a Transform that turns to the
    # player)
    c = b.world_canvas("Plain", (9.2, 1.5, 2), (600, 400))
    b.img("Back", c, {"amin": (0, 0), "amax": (1, 1), "size": (0, 0)}, color=(0.14, 0.12, 0.1, 1))
    holder = f.node("Holder", c, pos=(100, 50, 0))
    b.img("HeldImage", holder, {"pos": (0, 0), "size": (80, 40)}, color=(0.9, 0.3, 0.2, 1))
    # (anchors against no rect: stretching adds nothing, the pivot decides where it lies)
    f.node("HeldText", holder, {"amin": (0, 0), "amax": (1, 1), "pos": (0, -40), "size": (160, 30)}, [renderer(), tmp("below a plain Transform", 14, halign=2, valign=512)])
    b.img("HeldCorner", holder, {"amin": (1, 1), "amax": (1, 1), "pivot": (0, 0), "pos": (50, 10), "size": (30, 30)}, color=(0.2, 0.7, 0.9, 1))
    turned = f.node("Turned", c, pos=(-150, 50, 0), rot=(0, 0, 30), scale=(2, 2, 2))
    b.img("TurnedImage", turned, {"pivot": (0, 0), "pos": (0, 0), "size": (50, 30)}, color=(0.3, 0.8, 0.3, 1))
    tilted = f.node("Tilted", c, pos=(-150, -100, 0), rot=(40, 0, 0))
    b.img("TiltedImage", tilted, {"pos": (0, 0), "size": (60, 40)}, color=(0.8, 0.8, 0.2, 1))
    deep = f.node("Deep", c, pos=(150, -100, 0))
    deeper = f.node("Deeper", deep, pos=(20, 10, 0))
    deep_image = b.img("DeepImage", deeper, {"pos": (0, 0), "size": (90, 60)}, color=(0.6, 0.3, 0.8, 1))
    inner = f.node("Inner", deep_image, pos=(10, 0, 0))
    b.img("InnerImage", inner, {"pos": (0, 0), "size": (30, 20)}, color=(1, 1, 1, 1))
    hidden_holder = f.node("HiddenHolder", c, pos=(0, 150, 0), active=False)
    b.img("HiddenImage", hidden_holder, {"pos": (0, 0), "size": (60, 30)}, color=(1, 0, 0, 1))
    f.node("Only3D", c, pos=(0, -150, 0))   # nothing of the UI below it: an object in space as before
    holders_turned_back(f, b, c)
    # a holder in front of the canvas (vrcbce's timer hangs 0.338 above a canvas that lies flat):
    # what is below it is as far from the plane as the holder
    lifted = f.node("Lifted", c, pos=(0, -60, -80), scale=(0.5, 0.5, 0.5))
    b.img("LiftedImage", lifted, {"pos": (0, 0), "size": (100, 40)}, color=(0.2, 0.9, 0.7, 1))
    f.node("LiftedText", lifted, {"amin": (0, 0), "amax": (1, 1), "pos": (0, -50), "size": (200, 30)}, [renderer(), tmp("in front of the canvas", 20, halign=2, valign=512)])

    # ---- Animated: an Animator that moves a RectTransform ---------------------------------------
    c = b.world_canvas("Animated", (10.2, 3.0, 2), (400, 200))
    b.img("Back", c, {"amin": (0, 0), "amax": (1, 1), "size": (0, 0)}, color=(0.1, 0.12, 0.14, 1))
    track = b.img("Track", c, {"pos": (0, 40), "size": (200, 40)}, [("Animator", KNOB_CONTROLLER)], color=(0.3, 0.3, 0.35, 1))
    b.img("Knob", track, {"pos": (-70, 0), "size": (40, 40)}, color=(0.95, 0.95, 0.95, 1))
    # the same controller on a second object: its knob is its own
    other = b.img("OtherTrack", c, {"pos": (0, -40), "size": (200, 40)}, [("Animator", KNOB_CONTROLLER)], color=(0.3, 0.35, 0.3, 1))
    b.img("Knob", other, {"pos": (-70, 0), "size": (40, 40)}, color=(0.95, 0.95, 0.6, 1))

    # ---- AnimatedUi: clips on rotation / scale / position, on fields of components, on a sprite ---
    c = b.world_canvas("AnimatedUi", (11.4, 3.0, 2), (500, 300))
    b.img("Back", c, {"amin": (0, 0), "amax": (1, 1), "size": (0, 0)}, color=(0.1, 0.12, 0.1, 1))
    show = f.node("Show", c, {"amin": (0, 0), "amax": (1, 1), "size": (0, 0)}, [("Animator", SHOW_CONTROLLER)])
    b.img("Dial", show, {"pos": (-180, 90), "size": (60, 60)}, color=(1, 0.6, 0.2, 1))
    held = f.node("Holder", show, pos=(-80, 90, 0))
    b.img("Held", held, {"pos": (0, 0), "size": (40, 40)}, color=(0.4, 0.8, 1, 1))
    f.node("Label", show, {"pos": (40, 90), "size": (140, 44)}, [renderer(), tmp("label", 20)])
    f.node("Bar", show, {"pos": (170, 90), "size": (128, 32)}, [renderer(), image(kind=3, sprite=BAR, fill=(0, 0.25, 0))])
    group = f.node("Group", show, {"pos": (-180, 0), "size": (80, 40)}, [canvas_group()])
    b.img("GroupImage", group, {"amin": (0, 0), "amax": (1, 1), "size": (0, 0)}, color=(0.9, 0.9, 0.3, 1))
    b.img("Blink", show, {"pos": (-80, 0), "size": (40, 40)}, color=(0.9, 0.3, 0.3, 1))
    b.img("Hide", show, {"pos": (-20, 0), "size": (40, 40)}, color=(0.3, 0.9, 0.3, 1))
    level = b.img("Level", show, {"pos": (110, 0), "size": (160, 20)}, color=(0.3, 0.3, 0.3, 1))
    f.add(level, slider(value=0, target=level.components[1][0]))
    check = b.img("Check", show, {"pos": (-180, -90), "size": (30, 30)}, color=(1, 1, 1, 1))
    mark = b.img("Mark", check, {"amin": (0, 0), "amax": (1, 1), "size": (-10, -10)}, color=(0.1, 0.1, 0.1, 1))
    f.add(check, toggle(on=False, graphic=mark.components[1][0], target=check.components[1][0]))
    go = b.img("Go", show, {"pos": (-80, -90), "size": (100, 30)}, color=(1, 1, 1, 1))
    f.add(go, button(target=go.components[1][0]))
    f.node("Icon", show, {"pos": (60, -90), "size": (64, 64)}, [renderer(), image(sprite=SHEET_LEFT)])

    # ---- Cut: TextMeshPro texts that do not fit their rects ------------------------------------
    # Ellipsis (overflow mode 1) ends the text in an ellipsis where it is cut, Truncate (3)
    # just cuts; a wrapped text is cut by lines, a line that is not wrapped at the rect's width
    c = b.world_canvas("Cut", (10.2, 1.5, 2), (500, 260))
    b.img("Back", c, {"amin": (0, 0), "amax": (1, 1), "size": (0, 0)}, color=(0.13, 0.1, 0.13, 1))
    for i, (name, value, size, kw) in enumerate([
            ("EllipsisLines", "first line<br>second line<br>third line<br>fourth line", (220, 58), {"overflow": 1}),
            ("EllipsisWide", "A player name that is much too long for its column", (220, 30), {"overflow": 1, "wrap": False}),
            ("TruncateWide", "A player name that is much too long for its column", (220, 30), {"overflow": 3, "wrap": False}),
            ("EllipsisFits", "Fits", (220, 30), {"overflow": 1, "wrap": False}),
            ("EllipsisRich", "<b>Bold</b> and <color=#ffd700>gold words</color> that run on and on", (220, 30), {"overflow": 1, "wrap": False})]):
        frame = b.img(name + "Frame", c, {"pos": (-125 + 250 * (i % 2), 90 - 70 * (i // 2)), "size": size}, color=(0.25, 0.22, 0.3, 1))
        f.node(name, frame, {"amin": (0, 0), "amax": (1, 1), "size": (0, 0)}, [renderer(), tmp(value, 20, **kw)])

    # ---- Transitions: what a Selectable does over time --------------------------------------------
    c = b.world_canvas("Transitions", (12.3, 3.0, 2), (400, 200))
    b.img("Back", c, {"amin": (0, 0), "amax": (1, 1), "size": (0, 0)}, color=(0.12, 0.1, 0.14, 1))
    # sprite swap: the sprite of the state in place of the Image's own
    swap = f.node("BtnSwap", c, {"pos": (-140, 50), "size": (64, 64)}, [renderer(), image(sprite=SHEET_LEFT)])
    f.add(swap, button(target=swap.components[1][0], transition=2, sprites={"Highlighted": SHEET_RIGHT, "Disabled": SHEET_RIGHT}))
    swap_off = f.node("BtnSwapOff", c, {"pos": (-60, 50), "size": (64, 64)}, [renderer(), image(sprite=SHEET_LEFT)])
    f.add(swap_off, button(target=swap_off.components[1][0], transition=2, sprites={"Highlighted": SHEET_RIGHT, "Disabled": SHEET_RIGHT}, interactable=False))
    # colour tint: fades over fadeDuration
    fade = f.node("BtnFade", c, {"pos": (60, 50), "size": (100, 30)}, [renderer(), image((1, 1, 1, 1))])
    f.add(fade, button(target=fade.components[1][0], highlighted=(1, 0, 0, 1), fade=0.2))
    # animation: triggers to the Animator of the button itself
    anim = f.node("BtnAnim", c, {"pos": (-100, -50), "size": (100, 30)}, [renderer(), image((0.6, 0.8, 1, 1)), ("Animator", PRESS_CONTROLLER)])
    f.add(anim, button(target=anim.components[1][0], transition=3))
    # a Toggle's check mark fades
    tf = b.box("ToggleFade", c, {"pos": (60, -50), "size": (120, 24)})
    tf_back = b.img("Background", tf, {"amin": (0, 0.5), "amax": (0, 0.5), "pos": (12, 0), "size": (20, 20)}, color=(0.9, 0.9, 0.9, 1))
    tf_mark = b.img("Checkmark", tf_back, {"size": (16, 16)}, color=(0.1, 0.1, 0.1, 1))
    f.add(tf, toggle(False, tf_mark.components[1][0], target=tf_back.components[1][0]))

    # ---- Scroll: ScrollRects and Scrollbars --------------------------------------------------------
    c = b.world_canvas("Scroll", (7.6, 3.0, 2), (1440, 640))
    b.img("Back", c, {"amin": (0, 0), "amax": (1, 1), "size": (0, 0)}, color=(0.13, 0.12, 0.15, 1))

    def make_bar(parent, name, vertical, direction=None, value=0, size=0.2, rect=None, steps=0):
        """A Scrollbar as Unity's menu builds it: 20 thick along an edge, a sliding area with
        insets of 10 and a handle that overhangs them by 10 (so it spans the bar)."""
        if rect is None:
            rect = {"amin": (1, 0), "amax": (1, 1), "pivot": (1, 1), "size": (20, 0)} if vertical else {"amin": (0, 0), "amax": (1, 0), "pivot": (0, 0), "size": (0, 20)}
        bar = f.node(name, parent, rect, [renderer(), image((0.25, 0.25, 0.3, 1))])
        area = b.box("Sliding Area", bar, {"amin": (0, 0), "amax": (1, 1), "size": (-20, -20)})
        handle = b.img("Handle", area, {"amin": (0, 0), "amax": (0.2, 1) if not vertical else (1, 0.2), "size": (20, 20)}, color=(0.8, 0.8, 0.85, 1))
        comp = f.add(bar, scrollbar(handle.t, (2 if vertical else 0) if direction is None else direction, value, size, steps, target=handle.components[1][0]))
        return bar, comp

    def make_scroll(name, pos, size, content_size, content_pos=(0, 0), content_pivot=(0, 1), bars=(True, True), items=0, group=False, steps=0, **kw):
        """Unity's Scroll View: the ScrollRect, a masked viewport stretched over it (pivot top-left),
        the content anchored to the viewport's top (stretched along x unless it has a width)."""
        root = f.node(name, c, {"pos": pos, "size": size}, [renderer(), image((0.2, 0.2, 0.24, 1))])
        view = f.node("Viewport", root, {"amin": (0, 0), "amax": (1, 1), "pivot": (0, 1), "size": (0, 0)}, [rect_mask()])
        if content_size[0] is None:
            crect = {"amin": (0, 1), "amax": (1, 1), "pivot": content_pivot, "pos": content_pos, "size": (0, content_size[1])}
        else:
            crect = {"amin": (0, 1), "amax": (0, 1), "pivot": content_pivot, "pos": content_pos, "size": content_size}
        comps = [vgroup(padding=(4, 4, 4, 4), spacing=4, control=(True, False), expand=(True, False)), fitter(0, 2)] if group else []
        content = b.box("Content", view, crect, comps)
        for i in range(items):
            b.img("Item%d" % i, content, {"amin": (0, 1), "amax": (1, 1), "pivot": (0.5, 1), "pos": (0, -8 - i * 44), "size": (-16, 36)} if not group else {"size": (10, 36)})
        hbar = make_bar(root, "Scrollbar Horizontal", False) if bars[0] else (None, 0)
        vbar = make_bar(root, "Scrollbar Vertical", True, steps=steps) if bars[1] else (None, 0)
        f.add(root, scroll_rect(content.t, view.t, hbar[1], vbar[1], **kw))
        return root
    make_scroll("Tall", (-380, 190), (200, 200), (None, 500), items=6)                                     # scrolls vertically: the view gives way to the bar
    make_scroll("TallScrolled", (-160, 190), (200, 200), (None, 500), content_pos=(0, 150), items=6)       # half way down
    make_scroll("Short", (60, 190), (200, 200), (None, 120), items=2)                                      # fits: no bars, no scrolling
    make_scroll("Wide", (280, 190), (200, 200), (500, 120), items=0)                                       # scrolls horizontally
    make_scroll("Both", (-380, -30), (200, 200), (500, 500), items=0)                                      # both bars: each leaves the corner free
    make_scroll("Outside", (-160, -30), (200, 200), (None, 500), content_pos=(0, 700), items=6)            # scrolled past the end: pulled back
    make_scroll("OutsideFree", (60, -30), (200, 200), (None, 500), content_pos=(0, 700), items=6, movement=0)   # unrestricted: stays
    make_scroll("Permanent", (280, -30), (200, 200), (None, 120), items=2, visibility=(0, 0))              # bars stay, the view keeps its size
    make_scroll("AutoHide", (-380, -250), (200, 200), (None, 120), items=2, visibility=(1, 1))             # bars hide, the view keeps its size
    make_scroll("AutoHideNeeded", (-160, -250), (200, 200), (None, 500), items=6, visibility=(1, 1))
    make_scroll("List", (60, -250), (200, 200), (None, 10), items=7, group=True)                           # the content's height comes from its group
    make_scroll("ListShort", (280, -250), (200, 200), (None, 10), items=2, group=True)
    make_scroll("BottomPivot", (-600, 190), (200, 200), (None, 120), content_pivot=(0, 0), items=0, bars=(False, False))   # smaller content: padded by its pivot
    # scrollbars on their own: the handle spans `size` of the sliding area, moved by the value
    make_bar(c, "BarLeftToRight", False, 0, 0.5, 0.4, {"pos": (-600, -40), "size": (160, 20)})
    make_bar(c, "BarRightToLeft", False, 1, 0.25, 0.4, {"pos": (-600, -80), "size": (160, 20)})
    make_bar(c, "BarBottomToTop", True, 2, 1, 0.25, {"pos": (-660, -220), "size": (20, 160)})
    make_bar(c, "BarTopToBottom", True, 3, 0.25, 0.5, {"pos": (-620, -220), "size": (20, 160)})
    make_bar(c, "BarFull", True, 2, 0.3, 1, {"pos": (-580, -220), "size": (20, 160)})
    # a Scrollbar with steps takes the nearest one: 0.4 of four steps is 1/3; the content of a
    # ScrollRect follows its bar (300 hidden, 120 down is 0.6 from the bottom: the step is 0.5)
    make_bar(c, "BarStepped", False, 0, 0.4, 0.25, {"pos": (500, -40), "size": (160, 20)}, steps=4)
    make_scroll("Stepped", (500, 190), (200, 200), (None, 500), content_pos=(0, 120), items=6, steps=5)

    # ---- Widgets: what one object does to another, and what is drawn ---------------------------
    c = b.world_canvas("Widgets", (3.5, 3.0, 2), (800, 600))
    b.img("Back", c, {"amin": (0, 0), "amax": (1, 1), "size": (0, 0)}, color=(0.12, 0.12, 0.16, 1))

    def graphic_id(o):
        """File id of the object's Graphic component (after its CanvasRenderer)."""
        return o.components[1][0]

    def make_slider(name, pos, value, direction, lo=0, hi=1, whole=False, filled=False, handle=True, **sel):
        vertical = direction >= 2
        root = b.box(name, c, {"pos": pos, "size": (20, 160) if vertical else (160, 20)})
        b.img("Background", root, {"amin": (0, 0.25), "amax": (1, 0.75), "size": (0, 0)}, color=(0.3, 0.3, 0.3, 1))
        # the anchors in the file are stale on purpose: Unity sets them from the value
        area = b.box("Fill Area", root, {"amin": (0, 0.25), "amax": (1, 0.75), "pos": (-5, 0), "size": (-20, 0)})
        fill = f.node("Fill", area, {"amin": (0, 0), "amax": (0.9, 0.8), "size": (10, 0)}, [renderer(), image((0.3, 0.8, 0.4, 1), 3 if filled else 0)])
        knob = None
        if handle:
            harea = b.box("Handle Slide Area", root, {"amin": (0, 0), "amax": (1, 1), "size": (-20, 0)})
            knob = b.img("Handle", harea, {"amin": (0.9, 0.1), "amax": (0.9, 0.9), "size": (20, 0)}, color=(0.95, 0.95, 0.95, 1))
        f.add(root, slider(value, direction, fill.t, knob.t if knob else 0, lo, hi, whole, target=graphic_id(knob) if knob else 0, **sel))
        return root
    make_slider("SliderLTR", (-300, 260), 0.25, 0)
    make_slider("SliderRTL", (-300, 220), 0.25, 1)
    make_slider("SliderRange", (-300, 180), 0, 0, lo=-10, hi=30)
    make_slider("SliderWhole", (-300, 140), 3, 0, lo=0, hi=10, whole=True)
    make_slider("SliderFilled", (-300, 100), 0.4, 0, filled=True)
    make_slider("SliderNoHandle", (-300, 60), 0.8, 1, handle=False)
    make_slider("SliderDisabled", (-300, 20), 1, 0, interactable=False)
    make_slider("SliderBTT", (-160, 180), 0.6, 2)
    # an Image on the Slider's own object (its background)
    own = f.node("SliderOwnImage", c, {"pos": (-300, -20), "size": (160, 20)}, [renderer(), image((0.5, 0.3, 0.6, 1))])
    own_fill = b.img("Fill", own, {"amin": (0, 0.25), "amax": (0.5, 0.75), "size": (0, 0)}, color=(0.3, 0.8, 0.4, 1))
    f.add(own, slider(0.5, 0, own_fill.t, 0))
    make_slider("SliderTTB", (-120, 180), 0.6, 3)

    def make_toggle(name, pos, on, **sel):
        root = b.box(name, c, {"pos": pos, "size": (120, 24)})
        back = b.img("Background", root, {"amin": (0, 0.5), "amax": (0, 0.5), "pos": (12, 0), "size": (20, 20)}, color=(0.9, 0.9, 0.9, 1))
        mark = b.img("Checkmark", back, {"size": (16, 16)}, color=(0.1, 0.1, 0.1, 1))
        f.node("Label", root, {"amin": (0, 0), "amax": (1, 1), "pos": (12, 0), "size": (-28, 0)}, [renderer(), text(name, 12, (1, 1, 1, 1))])
        f.add(root, toggle(on, graphic_id(mark), target=graphic_id(back), **sel))
        return root
    make_toggle("ToggleOn", (0, 260), True)
    make_toggle("ToggleOff", (0, 230), False)
    make_toggle("ToggleOnDisabled", (0, 200), True, interactable=False)

    def make_button(name, pos, color, own_image=True, child_target=False, image_on=True, **sel):
        comps = [renderer(), image(color) if image_on else disable(image(color))] if own_image else []
        root = f.node(name, c, {"pos": pos, "size": (140, 30)}, comps)
        target = graphic_id(root) if own_image else 0
        if child_target:
            target = graphic_id(b.img("Face", root, {"amin": (0, 0), "amax": (1, 1), "size": (-6, -6)}, color=color))
        f.node("Label", root, {"amin": (0, 0), "amax": (1, 1), "size": (0, 0)}, [renderer(), text(name, 12, (0, 0, 0, 1))])
        f.add(root, button(target=target if sel.pop("targeted", True) else 0, **sel))
        return root
    make_button("BtnPlain", (200, 260), (1, 1, 1, 1))
    make_button("BtnClear", (200, 225), (1, 1, 1, 1), normal=(1, 1, 1, 0))                 # invisible until hovered
    make_button("BtnTint", (200, 190), (0.5, 0.5, 1, 1), normal=(1, 0.5, 0.5, 1))
    make_button("BtnDisabled", (200, 155), (1, 1, 1, 1), interactable=False)
    make_button("BtnMultiplier", (200, 120), (1, 1, 1, 1), normal=(0.4, 0.4, 0.4, 1), multiplier=2)
    make_button("BtnNoTransition", (200, 85), (0.2, 0.6, 0.9, 1), transition=0, normal=(1, 0, 0, 0.2))
    make_button("BtnChildTarget", (200, 50), (1, 1, 1, 1), own_image=False, child_target=True, normal=(0.2, 1, 0.2, 1))
    make_button("BtnNoTarget", (200, 15), (0.9, 0.6, 0.2, 1), normal=(1, 1, 1, 0), targeted=False)
    make_button("BtnImageOff", (200, -20), (1, 1, 1, 1), image_on=False)                    # a disabled Image draws nothing

    # graphics that are not drawn while their objects and children stay
    hidden_img = f.node("ImageOff", c, {"pos": (0, 150), "size": (100, 40)}, [renderer(), disable(image((1, 0, 0, 1)))])
    b.img("Kid", hidden_img, {"size": (40, 20)}, color=(0.2, 0.9, 0.2, 1))
    masked = f.node("MaskHidden", c, {"pos": (0, 100), "size": (100, 40)}, [renderer(), image((1, 0, 0, 1)), mask(False)])
    b.img("Kid", masked, {"size": (40, 20)}, color=(0.2, 0.9, 0.2, 1))
    shown = f.node("MaskShown", c, {"pos": (0, 50), "size": (100, 40)}, [renderer(), image((0.5, 0.2, 0.2, 1)), mask(True)])
    b.img("Kid", shown, {"size": (40, 20)}, color=(0.2, 0.9, 0.2, 1))
    group = b.box("Group", c, {"pos": (0, 0), "size": (100, 40)}, [canvas_group(0.5)])
    b.img("Half", group, {"amin": (0, 0), "amax": (0.5, 1), "size": (0, 0)}, color=(1, 1, 1, 1))
    inner = b.box("Inner", group, {"amin": (0.5, 0), "amax": (1, 1), "size": (0, 0)}, [canvas_group(0.5)])
    b.img("Quarter", inner, {"amin": (0, 0), "amax": (1, 1), "size": (0, 0)}, color=(1, 1, 1, 0.8))
    f.node("TextOff", c, {"pos": (0, -40), "size": (100, 20)}, [renderer(), disable(text("not drawn", 12, (1, 1, 1, 1)))])
    # a group that is not interactable: the buttons below are in their disabled state, except
    # below a group that ignores its parents
    locked = b.box("Locked", c, {"pos": (-60, -60), "size": (300, 34)}, [canvas_group(1, interactable=False)])
    lb = f.node("LockedButton", locked, {"amin": (0, 0), "amax": (0.3, 1), "size": (-4, -4)}, [renderer(), image((1, 1, 1, 1))])
    f.add(lb, button(target=lb.components[1][0], disabled=(0.4, 0.4, 0.4, 0.5)))
    free = b.box("Free", locked, {"amin": (0.35, 0), "amax": (0.65, 1), "size": (0, 0)}, [canvas_group(1, ignore_parents=True)])
    fb = f.node("FreeButton", free, {"amin": (0, 0), "amax": (1, 1), "size": (-4, -4)}, [renderer(), image((1, 1, 1, 1))])
    f.add(fb, button(target=fb.components[1][0], disabled=(0.4, 0.4, 0.4, 0.5)))
    ghost = b.box("Ghost", locked, {"amin": (0.7, 0), "amax": (1, 1), "size": (0, 0)}, [canvas_group(0.5, blocks=False, ignore_parents=True)])
    gb = f.node("GhostButton", ghost, {"amin": (0, 0), "amax": (1, 1), "size": (-4, -4)}, [renderer(), image((1, 1, 1, 1))])
    f.add(gb, button(target=gb.components[1][0]))

    # text
    f.node("TmpTags", c, {"pos": (-200, -100), "size": (380, 30)}, [renderer(), tmp("<b>Bold</b> <color=#FFD700>gold</color> <size=13>small</size> 1<<2 <unknown> <#00ff00>green</color> end", 20)])
    f.node("TmpSmallCaps", c, {"pos": (-200, -140), "size": (380, 30)}, [renderer(), tmp("Small Caps Text", 20, style=35)])
    f.node("TmpUpper", c, {"pos": (-200, -180), "size": (380, 30)}, [renderer(), tmp("upper <lowercase>LOWER</lowercase> case", 20, style=16)])
    f.node("TmpNoRich", c, {"pos": (-200, -220), "size": (380, 30)}, [renderer(), tmp("<b>raw</b> text", 20, rich=False)])
    f.node("TmpAuto", c, {"pos": (-200, -260), "size": (380, 30)}, [renderer(), tmp("Auto sized text that has to shrink to fit its rect", 60, auto=True, sizes=(8, 60), halign=2, valign=512)])
    f.node("TmpCentre", c, {"pos": (200, -100), "size": (300, 30)}, [renderer(), tmp("centred<br>two lines", 12, color=(1, 0.8, 0.2, 1), halign=2, valign=512)])
    f.node("UguiRich", c, {"pos": (200, -140), "size": (300, 30)}, [renderer(), text("<b>bold</b> <color=red>red</color> <size=20>big</size> <u>plain</u>", 14, (1, 1, 1, 1))])
    f.node("UguiBold", c, {"pos": (200, -180), "size": (300, 30)}, [renderer(), text("bold italic", 14, (1, 1, 1, 1), style=3)])
    f.node("UguiBestFit", c, {"pos": (200, -220), "size": (300, 30)}, [renderer(), text("Best fit text that is far too long for its rect at forty", 40, (1, 1, 1, 1), best_fit=True, sizes=(6, 40))])

    # text higher than its rect: Unity draws every line, around the alignment point
    for name, y, valign in (("TmpOverTop", 0, 256), ("TmpOverMiddle", -60, 512), ("TmpOverBottom", -120, 1024)):
        frame = b.img(name, c, {"pos": (330, 100 + y), "size": (120, 20)}, color=(0.25, 0.25, 0.35, 1))
        f.node("Text", frame, {"amin": (0, 0), "amax": (1, 1), "size": (0, 0)}, [renderer(), tmp("first<br>second<br>third", 14, halign=2, valign=valign)])
    frame = b.img("UguiOver", c, {"pos": (330, -80), "size": (120, 20)}, color=(0.25, 0.25, 0.35, 1))
    f.node("Text", frame, {"amin": (0, 0), "amax": (1, 1), "size": (0, 0)}, [renderer(), text("first second third fourth fifth sixth", 14, (1, 1, 1, 1), align=4, overflow=(0, 1))])
    frame = b.img("UguiCut", c, {"pos": (330, -140), "size": (120, 20)}, color=(0.25, 0.25, 0.35, 1))
    f.node("Text", frame, {"amin": (0, 0), "amax": (1, 1), "size": (0, 0)}, [renderer(), text("first second third fourth fifth sixth", 14, (1, 1, 1, 1), align=4)])

    # Dropdowns as Unity's menu builds them: caption, arrow and the (inactive) template of the list
    def make_dropdown(name, pos, options, value):
        root = f.node(name, c, {"pos": pos, "size": (160, 30)}, [renderer(), image((1, 1, 1, 1), 1, UI_SPRITE)])
        label = f.node("Label", root, {"amin": (0, 0), "amax": (1, 1), "pos": (-7.5, -0.5), "size": (-35, -13)}, [renderer(), text("caption", 14, (0.2, 0.2, 0.2, 1), align=3)])
        f.node("Arrow", root, {"amin": (1, 0.5), "amax": (1, 0.5), "pos": (-15, 0), "size": (20, 20)}, [renderer(), image((1, 1, 1, 1), 0, (10915, BUILTIN))])
        template = f.node("Template", root, {"amin": (0, 0), "amax": (1, 0), "pivot": (0.5, 1), "pos": (0, 2), "size": (0, 150)}, [renderer(), image((1, 1, 1, 1), 1, UI_SPRITE)], active=False)
        view = f.node("Viewport", template, {"amin": (0, 0), "amax": (1, 1), "pivot": (0, 1), "size": (-18, 0)}, [rect_mask()])
        content = b.box("Content", view, {"amin": (0, 1), "amax": (1, 1), "pivot": (0.5, 1), "size": (0, 28)})
        item = b.box("Item", content, {"amin": (0, 0.5), "amax": (1, 0.5), "size": (0, 20)})
        back = f.node("Item Background", item, {"amin": (0, 0), "amax": (1, 1), "size": (0, 0)}, [renderer(), image((0.96, 0.96, 0.96, 1))])
        mark = f.node("Item Checkmark", item, {"amin": (0, 0.5), "amax": (0, 0.5), "pos": (10, 0), "size": (20, 20)}, [renderer(), image((1, 1, 1, 1), 0, CHECKMARK)])
        item_label = f.node("Item Label", item, {"amin": (0, 0), "amax": (1, 1), "pos": (5, -0.5), "size": (-30, -3)}, [renderer(), text("Option A", 14, (0.2, 0.2, 0.2, 1), align=3)])
        f.add(item, toggle(True, mark.components[1][0], target=back.components[1][0]))
        bar, bar_comp = make_list_bar(template)
        f.add(template, scroll_rect(content.t, view.t, 0, bar_comp, horizontal=False, movement=2, visibility=(0, 2), spacing=(0, -3)))
        f.add(root, dropdown(options, value, template.t, label.components[1][0], item_label.components[1][0], target=root.components[1][0]))
        return root

    def make_list_bar(parent):
        bar = f.node("Scrollbar", parent, {"amin": (1, 0), "amax": (1, 1), "pivot": (1, 1), "size": (20, 0)}, [renderer(), image((0.8, 0.8, 0.8, 1))])
        area = b.box("Sliding Area", bar, {"amin": (0, 0), "amax": (1, 1), "size": (-20, -20)})
        handle = b.img("Handle", area, {"amin": (0, 0), "amax": (1, 0.2), "size": (20, 20)}, color=(0.5, 0.5, 0.5, 1))
        return bar, f.add(bar, scrollbar(handle.t, 2, 0, 0.2, target=handle.components[1][0]))
    make_dropdown("Dropdown", (-300, -50), ["Option A", "Option B", "Option C"], 1)      # the list opens below: 3 items
    make_dropdown("DropdownLong", (-120, -50), ["One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten"], 0)   # more items than fit: scrolls
    make_dropdown("DropdownLow", (20, -285), ["Up A", "Up B"], 0)                        # at the canvas's lower edge: the list flips above

    # an input field draws its text and placeholder objects itself
    field = f.node("Field", c, {"pos": (200, -265), "size": (200, 30)}, [renderer(), image((1, 1, 1, 1))])
    hint = f.node("Placeholder", field, {"amin": (0, 0), "amax": (1, 1), "size": (-20, -10)}, [renderer(), text("Enter text...", 14, (0.2, 0.2, 0.2, 0.5), style=2)])
    shown_text = f.node("Text", field, {"amin": (0, 0), "amax": (1, 1), "size": (-20, -10)}, [renderer(), text("typed", 14, (0.2, 0.2, 0.2, 1))])
    f.add(field, input_field("typed", graphic_id(shown_text), graphic_id(hint), target=graphic_id(field)))

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
    # plain Transforms that hold UI on a screen canvas: drawn without perspective, so what is
    # turned back into the plane is whole and what stays tilted is shortened
    holders = f.node("ScreenHolders", None, {"amin": (0, 0), "amax": (0, 0), "size": (0, 0), "scale": 0}, [canvas(0, 7), scaler(0, 1), raycaster()])
    holders_turned_back(f, b, holders)
    turned = f.node("Turned", holders, pos=(-300, -100, 0), rot=(0, 0, 30), scale=(2, 2, 2))
    b.img("TurnedImage", turned, {"pivot": (0, 0), "pos": (0, 0), "size": (50, 30)}, color=(0.3, 0.8, 0.3, 1))
    tilted = f.node("Tilted", holders, pos=(0, -150, 0), rot=(60, 0, 0))
    b.img("TiltedImage", tilted, {"pos": (0, 0), "size": (100, 100)}, color=(0.8, 0.8, 0.2, 1))   # half as high on the screen
    return f


META = "fileFormatVersion: 2\nguid: %s\n%s:\n  externalObjects: {}\n  userData: \n  assetBundleName: \n  assetBundleVariant: \n"


def main(argv):
    out = argv[1] if len(argv) > 1 else os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tests", "unity_ui", "UiCases")
    os.makedirs(out, exist_ok=True)
    card, card_ids = card_prefab()
    board, board_ids = board_prefab()
    panel, panel_ids = panel_prefab()
    write_textures(out)
    write_fonts(out)
    write_animations(out)
    scene = build_scene(card, card_ids, board, board_ids, panel, panel_ids)
    for name, f, is_scene in (("Card.prefab", card, False), ("Board.prefab", board, False), ("Panel.prefab", panel, False), ("UiCases.unity", scene, True)):
        with open(os.path.join(out, name), "w") as fh:
            fh.write(f.text(is_scene))
        with open(os.path.join(out, name + ".meta"), "w") as fh:
            fh.write(META % (f.guid, "DefaultImporter" if is_scene else "PrefabImporter"))
    print("wrote %s: %d scene objects, %d prefab instances" % (out, len(scene.objects), len(scene.instances)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
