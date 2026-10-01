#!/usr/bin/env python3
"""Reference rectangles for Unity UI, computed from the Unity files alone.

    tools/unity_ui_reference.py <assets dir> <scene or prefab> [--json out.json] [--survey]
    tools/unity_ui_reference.py <assets dir> <scene or prefab> --compare dump.json [--tolerance 0.002]

Reads a `.unity` / `.prefab` file, instantiates its nested prefabs (modifications, stripped
objects, objects added under instance nodes, removed components), and computes for every
RectTransform below a Canvas the rectangle Unity gives it: anchors, offsets, pivot, scale and
rotation, layout groups, content size fitters, layout elements and aspect ratio fitters.
The importer is not involved, so the result can be held against an imported world:
unidot's `test/ui_dump.gd` (`scenarios/canvas_dump.gd` in a world) writes the same structure from
the Godot side, following what is rendered, and `--compare` lists every node whose corners differ.

Corners are world positions (Unity space; window pixels with y up for screen-space canvases) in
the order of RectTransform.GetWorldCorners: bottom-left, top-left, top-right, bottom-right.

Besides the rectangles: what one object does to another (a Slider's fill and handle anchors
follow its value, a Selectable tints its target graphic, a Toggle shows its check mark), whether
and in which colour each Graphic is drawn (component enabled, CanvasRenderer colour, masks that
hide their graphic, canvas group alpha) and the characters a text shows (rich text tags removed).

What is not modelled: text metrics (a Text / TMP preferred size is unknown without the font; such
nodes are flagged `text_sized` and compared loosely) and anything scripts do at runtime.
"""
import copy
import json
import math
import os
import re
import sys

MASK63 = 0x7FFFFFFFFFFFFFFF

UI_SCRIPTS = {
    "fe87c0e1cc204ed48ad3b37840f39efc": "Image",
    "1344c3c82d62a2a41a3576d8abb8e3ea": "RawImage",
    "5f7201a12d95ffc409449d95f23cf332": "Text",
    "4e29b1a8efbd4b44bb3f3716e73f07ff": "Button",
    "9085046f02f69544eb97fd06b6048fe2": "Toggle",
    "67db9e8f0e2ae9c40bc1e2b64352a6b4": "Slider",
    "2a4db7a114972834c8e4117be1d82ba3": "Scrollbar",
    "d199490a83bb2b844b9695cbf13b01ef": "InputField",
    "0d1c2a8fe1a7b7a4d9edbdc6bf0d0d5b": "Dropdown",
    "1aa08ab6e0800fa44ae55d278d1423e3": "ScrollRect",
    "0cd44c1031e13a943bb63640046fad76": "CanvasScaler",
    "dc42784cf147c0c48a680349fa168899": "GraphicRaycaster",
    "31a19414c41e5ae4aae2af33fee712f6": "Mask",
    "3312d7739989d2b4e91e6319e9a96d76": "RectMask2D",
    "306cc8c2b49d7114eaa3623786fc2126": "LayoutElement",
    "30649d3a9faa99c48a7b1166b86bf2a0": "HorizontalLayoutGroup",
    "59f8146938fff824cb5fd77236b75775": "VerticalLayoutGroup",
    "8a8695521f0d02e499659fee002a26c2": "GridLayoutGroup",
    "3245ec927659c4140ac4f8d17403cc18": "ContentSizeFitter",
    "86710e43de46f6f4bac7c8e50813a599": "AspectRatioFitter",
    "e19747de3f5aca642ab2be37e372fb86": "Outline",
    "cfabb0440166ab443bba8876756fdfa9": "Shadow",
    "f4688fdb7df04437aeb418b961361dc5": "TextMeshProUGUI",
    "9541d86e2fd84c1d9990edf0852d74ab": "TextMeshPro",
    "2da0c512f12947e489f739169773d7ca": "TMP_InputField",
    "7b743370ac3e4ec2a1668f5455a8ef8a": "TMP_Dropdown",
}
VRCSDK3_DLL = "661092b4961be7145bfbe56e1e62337b"
VRCSDK3_CLASSES = {-1533785930: "VRC_UiShape"}


# --------------------------------------------------------------------------------------------
# Unity YAML (the subset Unity writes): block mappings and sequences, flow mappings and
# sequences that may wrap, plain / quoted scalars that may continue on deeper lines.
# --------------------------------------------------------------------------------------------

_KEY = re.compile(r"^(- )?([A-Za-z_][\w .\[\]-]*|'[^']*'|\"[^\"]*\"|\d+):( |$)")
_HEADER = re.compile(r"^--- !u!(\d+) &(-?\d+)( stripped)?")


def _open_flow(s):
    """Is a flow collection or a quoted scalar still open at the end of `s`?"""
    depth = 0
    quote = None
    i = 0
    while i < len(s):
        ch = s[i]
        if quote:
            if ch == "\\" and quote == '"':
                i += 1
            elif ch == quote:
                if quote == "'" and i + 1 < len(s) and s[i + 1] == "'":
                    i += 1
                else:
                    quote = None
        elif ch in "\"'" and (i == 0 or s[i - 1] in " {[,:-"):
            quote = ch
        elif ch in "{[":
            depth += 1
        elif ch in "}]":
            depth -= 1
        i += 1
    return depth > 0 or quote is not None


def _logical_lines(text):
    """[(indent, content)] with wrapped flow collections and scalars joined."""
    out = []
    pending = False
    for raw in text.split("\n"):
        if not raw.strip():
            if pending and out:
                out[-1][1] += "\n"
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        content = raw.strip()
        if out and pending:
            out[-1][1] += " " + content
            pending = _open_flow(_value_part(out[-1][1]))
            continue
        if out and not _KEY.match(content) and not content.startswith("- ") and content != "-" and indent > out[-1][0]:
            out[-1][1] += " " + content  # a plain scalar continued on a deeper line
            continue
        out.append([indent, content])
        pending = _open_flow(_value_part(content))
    return out


def _value_part(content):
    m = _KEY.match(content)
    if m:
        return content[m.end():]
    return content[2:] if content.startswith("- ") else content


def _scalar(s):
    s = s.strip()
    if s == "":
        return None
    if s[0] == "{":
        return _flow_map(s)
    if s[0] == "[":
        inner = s[1:-1].strip()
        return [_scalar(p) for p in _split_flow(inner)] if inner else []
    if s[0] == '"' and s[-1] == '"' and len(s) >= 2:
        try:
            return json.loads(s.replace("\n", "\\n"))
        except ValueError:
            return s[1:-1]
    if s[0] == "'" and s[-1] == "'" and len(s) >= 2:
        return s[1:-1].replace("''", "'")
    if re.fullmatch(r"-?\d+", s):
        return int(s)
    if re.fullmatch(r"-?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?", s):
        return float(s)
    return s


def _split_flow(s):
    parts, depth, quote, cur = [], 0, None, ""
    for ch in s:
        if quote:
            cur += ch
            if ch == quote:
                quote = None
            continue
        if ch in "\"'":
            quote = ch
        elif ch in "{[":
            depth += 1
        elif ch in "}]":
            depth -= 1
        elif ch == "," and depth == 0:
            parts.append(cur)
            cur = ""
            continue
        cur += ch
    if cur.strip():
        parts.append(cur)
    return parts


def _flow_map(s):
    out = {}
    for part in _split_flow(s.strip()[1:-1]):
        k, _, v = part.partition(":")
        out[k.strip()] = _scalar(v)
    return out


def _parse_block(lines, i, indent):
    """Parse the block starting at lines[i] whose items sit at `indent`. → (value, next i)"""
    if i >= len(lines):
        return None, i
    if lines[i][1].startswith("- ") or lines[i][1] == "-":
        seq = []
        while i < len(lines) and lines[i][0] == indent and (lines[i][1].startswith("- ") or lines[i][1] == "-"):
            item = lines[i][1][2:] if len(lines[i][1]) > 1 else ""
            if _KEY.match(item):
                # a mapping item: its first key is on the dash line, the rest two columns deeper
                lines[i] = [indent + 2, item]
                val, i = _parse_block(lines, i, indent + 2)
                seq.append(val)
            else:
                seq.append(_scalar(item))
                i += 1
        return seq, i
    mapping = {}
    while i < len(lines) and lines[i][0] == indent and not lines[i][1].startswith("- "):
        m = _KEY.match(lines[i][1])
        if not m:
            i += 1
            continue
        key = m.group(2).strip("'\"")
        rest = lines[i][1][m.end():]
        i += 1
        if rest.strip() != "":
            mapping[key] = _scalar(rest)
        elif i < len(lines) and (lines[i][0] > indent or (lines[i][0] == indent and lines[i][1].startswith("- "))):
            mapping[key], i = _parse_block(lines, i, lines[i][0])
        else:
            mapping[key] = None
    return mapping, i


class Obj:
    __slots__ = ("type_id", "file_id", "stripped", "kind", "data", "origin")

    def __init__(self, type_id, file_id, stripped, kind, data, origin=""):
        self.type_id = type_id
        self.file_id = file_id
        self.stripped = stripped
        self.kind = kind
        self.data = data
        self.origin = origin


def parse_unity_file(path):
    """→ {fileID: Obj}"""
    with open(path, encoding="utf-8", errors="replace") as f:
        text = f.read()
    docs = {}
    chunks = re.split(r"(?m)^(?=--- !u!)", text)
    for chunk in chunks:
        m = _HEADER.match(chunk)
        if not m:
            continue
        body = chunk.split("\n", 1)[1] if "\n" in chunk else ""
        lines = _logical_lines(body)
        parsed, _ = _parse_block(lines, 0, 0) if lines else ({}, 0)
        if not isinstance(parsed, dict) or not parsed:
            continue
        kind = next(iter(parsed))
        data = parsed[kind] if isinstance(parsed[kind], dict) else {}
        docs[int(m.group(2))] = Obj(int(m.group(1)), int(m.group(2)), m.group(3) is not None, kind, data, os.path.basename(path))
    return docs


# --------------------------------------------------------------------------------------------
# Prefab instantiation
# --------------------------------------------------------------------------------------------

class Assets:
    def __init__(self, root):
        self.root = root
        self.guid_to_path = {}
        self._files = {}
        self._flat = {}
        self.warnings = []
        for dirpath, _dirs, files in os.walk(root):
            for name in files:
                if name.endswith(".meta"):
                    try:
                        with open(os.path.join(dirpath, name), encoding="utf-8", errors="replace") as f:
                            head = f.read(400)
                    except OSError:
                        continue
                    m = re.search(r"(?m)^guid: ([0-9a-f]{32})", head)
                    if m:
                        self.guid_to_path[m.group(1)] = os.path.join(dirpath, name[:-5])

    def warn(self, msg):
        if msg not in self.warnings:
            self.warnings.append(msg)

    def file(self, path):
        path = os.path.abspath(path)
        if path not in self._files:
            self._files[path] = parse_unity_file(path)
        return self._files[path]

    def flatten(self, path):
        """Every object of the file with its nested prefab instances expanded, keyed by the
        fileID it has inside this file (instance contents: the stripped object's id when the file
        declares one, else instance id XOR source id)."""
        path = os.path.abspath(path)
        if path in self._flat:
            return self._flat[path]
        docs = self.file(path)
        model = {}
        stripped_alias = {}  # (instance id, source id) → id of the stripped stand-in
        for fid, o in docs.items():
            if o.stripped:
                src = _ref_id(o.data.get("m_CorrespondingSourceObject"))
                inst = _ref_id(o.data.get("m_PrefabInstance")) or _ref_id(o.data.get("m_PrefabInternal"))
                if src and inst:
                    stripped_alias[(inst, src)] = fid
            elif o.kind not in ("PrefabInstance", "Prefab"):
                model[fid] = Obj(o.type_id, o.file_id, False, o.kind, copy.deepcopy(o.data), o.origin)
        for fid, o in docs.items():
            if o.kind != "PrefabInstance":
                continue
            src_ref = o.data.get("m_SourcePrefab") or o.data.get("m_ParentPrefab") or {}
            guid = src_ref.get("guid") if isinstance(src_ref, dict) else None
            src_path = self.guid_to_path.get(guid or "")
            if not src_path or not src_path.endswith((".prefab", ".unity")):
                self.warn("prefab instance %d in %s: source %s is not a prefab in the assets (model or missing)" % (fid, os.path.basename(path), guid))
                continue
            inner = self.flatten(src_path)
            idmap = {}
            for iid in inner:
                idmap[iid] = stripped_alias.get((fid, iid), (fid ^ iid) & MASK63)
            mod = o.data.get("m_Modification") or {}
            removed = set()
            for r in mod.get("m_RemovedComponents") or []:
                rid = _ref_id(r)
                if rid:
                    removed.add(rid)
            copies = {}
            for iid, io in inner.items():
                if iid in removed:
                    continue
                data = _remap(copy.deepcopy(io.data), idmap)
                copies[iid] = Obj(io.type_id, idmap[iid], False, io.kind, data, io.origin)
            for m in mod.get("m_Modifications") or []:
                if not isinstance(m, dict):
                    continue
                tid = _ref_id(m.get("target"))
                target = copies.get(tid)
                if target is None:
                    continue
                ref = m.get("objectReference")
                value = m.get("value")
                if isinstance(ref, dict) and ref.get("fileID") not in (0, None):
                    value = ref
                _set_path(target.data, str(m.get("propertyPath", "")), value)
            parent = _ref_id(mod.get("m_TransformParent"))
            for iid, c in copies.items():
                if c.kind in ("Transform", "RectTransform") and not _ref_id(c.data.get("m_Father")):
                    c.data["m_Father"] = {"fileID": parent or 0}
                    c.data["_instance_root"] = True
                model[c.file_id] = c
        self._flat[path] = model
        return model


def _ref_id(ref):
    if isinstance(ref, dict):
        v = ref.get("fileID")
        return v if isinstance(v, int) else 0
    return 0


def _remap(value, idmap):
    """Rewrite references local to the source file ({fileID: n} without a guid)."""
    if isinstance(value, dict):
        if "fileID" in value and "guid" not in value:
            fid = value.get("fileID")
            if isinstance(fid, int) and fid in idmap:
                value["fileID"] = idmap[fid]
            return value
        for k in value:
            value[k] = _remap(value[k], idmap)
        return value
    if isinstance(value, list):
        return [_remap(v, idmap) for v in value]
    return value


def _set_path(data, path, value):
    parts = re.findall(r"[^.\[\]]+|\[\d+\]", path)
    cur = data
    for i, part in enumerate(parts):
        last = i == len(parts) - 1
        if part == "Array":
            continue
        if part == "size" and i > 0 and parts[i - 1] == "Array":
            if isinstance(cur, list) and isinstance(value, (int, float)):
                n = int(value)
                del cur[n:]
                while len(cur) < n:
                    cur.append(None)
            return
        if part == "data" and i + 1 < len(parts) and parts[i + 1].startswith("["):
            continue
        if part.startswith("["):
            idx = int(part[1:-1])
            if not isinstance(cur, list):
                return
            while len(cur) <= idx:
                cur.append(None)
            if last:
                cur[idx] = value
                return
            if cur[idx] is None:
                cur[idx] = {}
            cur = cur[idx]
            continue
        if not isinstance(cur, dict):
            return
        if last:
            cur[part] = value
            return
        nxt = cur.get(part)
        if nxt is None:
            nxt = [] if (i + 1 < len(parts) and parts[i + 1] == "Array") else {}
            cur[part] = nxt
        cur = nxt


# --------------------------------------------------------------------------------------------
# Scene graph
# --------------------------------------------------------------------------------------------

def _num(v, default=0.0):
    if isinstance(v, (int, float)):
        return float(v)
    if isinstance(v, str):
        try:
            return float(v)
        except ValueError:
            return default
    return default


def _vec(d, keys, default):
    if not isinstance(d, dict):
        return list(default)
    return [_num(d.get(k), default[i]) for i, k in enumerate(keys)]


class Node:
    def __init__(self, tid, tobj, gobj):
        self.tid = tid
        self.t = tobj
        self.go = gobj
        self.name = str(gobj.data.get("m_Name", "")) if gobj else "?"
        self.active = _num(gobj.data.get("m_IsActive", 1), 1) != 0 if gobj else True
        self.is_rect = tobj.kind == "RectTransform"
        self.parent = None
        self.children = []
        self.components = []   # [(name, data)]
        self.component_ids = []   # file ids, parallel to components
        self.renderer_color = [1.0, 1.0, 1.0, 1.0]   # CanvasRenderer colour (Selectable tint, Toggle fade)
        self.field_text = False   # the text or placeholder object of an input field
        d = tobj.data
        self.local_position = _vec(d.get("m_LocalPosition"), "xyz", (0, 0, 0))
        self.local_rotation = _vec(d.get("m_LocalRotation"), "xyzw", (0, 0, 0, 1))
        self.local_scale = _vec(d.get("m_LocalScale"), "xyz", (1, 1, 1))
        self.anchor_min = _vec(d.get("m_AnchorMin"), "xy", (0.5, 0.5))
        self.anchor_max = _vec(d.get("m_AnchorMax"), "xy", (0.5, 0.5))
        self.anchored_position = _vec(d.get("m_AnchoredPosition"), "xy", (0, 0))
        self.size_delta = _vec(d.get("m_SizeDelta"), "xy", (0, 0))
        self.pivot = _vec(d.get("m_Pivot"), "xy", (0.5, 0.5))
        self.root_order = int(_num(d.get("m_RootOrder", -1), -1))
        # layout results (parent space, y up)
        self.size = [0.0, 0.0]
        self.pos = [0.0, 0.0]       # pivot position in the parent's local space
        self.text_sized = False
        self.driven = False
        self.laid = False          # size / pos computed by the layout
        self.screen_space = False
        self.scale_factor = 1.0

    def comp(self, name):
        for n, d in self.components:
            if n == name:
                return d
        return None

    def has(self, name):
        return self.comp(name) is not None

    def path(self, stop=None):
        parts = []
        n = self
        while n is not None and n is not stop:
            parts.append(n.name)
            n = n.parent
        return "/".join(reversed(parts))


def build_graph(model, assets):
    gos = {fid: o for fid, o in model.items() if o.kind == "GameObject"}
    nodes = {}
    for fid, o in model.items():
        if o.kind in ("Transform", "RectTransform"):
            go = gos.get(_ref_id(o.data.get("m_GameObject")))
            nodes[fid] = Node(fid, o, go)
    by_go = {n.go.file_id: n for n in nodes.values() if n.go is not None}
    # components: the GameObject's own list first (order matters for layout), then added ones
    comps_of = {}
    for fid, o in model.items():
        if o.kind in ("GameObject", "Transform", "RectTransform"):
            continue
        gid = _ref_id(o.data.get("m_GameObject"))
        if gid in by_go:
            comps_of.setdefault(gid, {})[fid] = o
    for gid, comps in comps_of.items():
        node = by_go[gid]
        order = []
        for c in node.go.data.get("m_Component") or []:
            cid = _ref_id(c.get("component")) if isinstance(c, dict) else 0
            if cid in comps:
                order.append(cid)
        order += [cid for cid in comps if cid not in order]
        for cid in order:
            o = comps[cid]
            name = o.kind
            if o.kind == "MonoBehaviour":
                script = o.data.get("m_Script") or {}
                guid = script.get("guid", "") if isinstance(script, dict) else ""
                name = UI_SCRIPTS.get(guid, "")
                if guid == VRCSDK3_DLL:
                    name = VRCSDK3_CLASSES.get(script.get("fileID"), "VRCSDK")
                if name == "":
                    p = assets.guid_to_path.get(guid, "")
                    name = os.path.splitext(os.path.basename(p))[0] if p else "script:" + str(guid)[:8]
            node.components.append((name, o.data))
            node.component_ids.append(cid)
    roots = []
    for fid, n in nodes.items():
        pid = _ref_id(n.t.data.get("m_Father"))
        if pid in nodes:
            n.parent = nodes[pid]
            n.parent.children.append(n)
        else:
            roots.append(n)
    for n in nodes.values():
        listed = [_ref_id(c) for c in (n.t.data.get("m_Children") or [])]
        index = {cid: i for i, cid in enumerate(listed)}

        def key(c, index=index):
            if c.tid in index and not c.t.data.get("_instance_root"):
                return (0, index[c.tid])
            if c.root_order >= 0:
                return (0, c.root_order)
            if c.tid in index:
                return (0, index[c.tid])
            return (1, 0)
        n.children.sort(key=key)
    return nodes, roots


# --------------------------------------------------------------------------------------------
# Small 3D maths (column vectors, 4x4 row-major lists)
# --------------------------------------------------------------------------------------------

def mat_identity():
    return [[1.0 if i == j else 0.0 for j in range(4)] for i in range(4)]


def mat_mul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(4)) for j in range(4)] for i in range(4)]


def mat_trs(t, q, s):
    x, y, z, w = q
    n = math.sqrt(x * x + y * y + z * z + w * w) or 1.0
    x, y, z, w = x / n, y / n, z / n, w / n
    r = [
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
    ]
    m = mat_identity()
    for i in range(3):
        for j in range(3):
            m[i][j] = r[i][j] * s[j]
        m[i][3] = t[i]
    return m


def mat_point(m, p):
    return [m[i][0] * p[0] + m[i][1] * p[1] + m[i][2] * p[2] + m[i][3] for i in range(3)]


# --------------------------------------------------------------------------------------------
# Unity UI layout
# --------------------------------------------------------------------------------------------

def enabled(d):
    return d is not None and _num(d.get("m_Enabled", 1), 1) != 0


def is_layout_ignored(n):
    le = n.comp("LayoutElement")
    return enabled(le) and _num(le.get("m_IgnoreLayout", 0)) != 0


def layout_group_of(n):
    for name in ("HorizontalLayoutGroup", "VerticalLayoutGroup", "GridLayoutGroup"):
        d = n.comp(name)
        if enabled(d):
            return name, d
    return None, None


class Layout:
    """Unity's layout rebuild (LayoutRebuilder): on each axis the sizes components ask for are
    gathered bottom-up, then applied top-down (an object's own fitters first, then its layout
    group, then its children); the horizontal axis for the whole tree, then the vertical one.
    Layout groups write their children's anchors, anchored position and size delta, as in Unity,
    and every rect is then computed from those values."""

    def __init__(self, sprite_size=None):
        # (node, Image data) → the size the Image asks for (Image.preferredWidth / Height), or None
        self.sprite_size = sprite_size or (lambda n, img: None)
        self._inputs = {}  # (node id, axis) → (min, preferred, flexible)

    # --- plain RectTransform geometry -------------------------------------------------------
    def place(self, n, axis):
        """Size and pivot position of `n` on one axis from its anchors, offsets and parent rect."""
        p = n.parent
        if p is not None and p.is_rect:
            psize, ppivot = p.size[axis], p.pivot[axis]
        else:
            psize, ppivot = 0.0, 0.0   # no parent rect: the anchored position is the local position
        amin, amax = n.anchor_min[axis], n.anchor_max[axis]
        n.size[axis] = (amax - amin) * psize + n.size_delta[axis]
        n.pos[axis] = psize * (amin - ppivot + n.pivot[axis] * (amax - amin)) + n.anchored_position[axis]
        n.laid = True

    def set_size_with_current_anchors(self, n, axis, size):
        psize = n.parent.size[axis] if (n.parent is not None and n.parent.is_rect) else 0.0
        n.size_delta[axis] = size - psize * (n.anchor_max[axis] - n.anchor_min[axis])
        self.place(n, axis)

    def set_child(self, c, axis, pos, size, scale):
        """LayoutGroup.SetChildAlongAxisWithScale: anchors to the top-left, the anchored position
        from the inset; `size` None keeps the size delta."""
        c.anchor_min = [0.0, 1.0]
        c.anchor_max = [0.0, 1.0]
        if size is not None:
            c.size_delta[axis] = size
        s = c.size_delta[axis]
        if axis == 0:
            c.anchored_position[0] = pos + s * c.pivot[0] * scale
        else:
            c.anchored_position[1] = -pos - s * (1.0 - c.pivot[1]) * scale
        c.driven = True

    # --- ILayoutElement values --------------------------------------------------------------
    def rect_children(self, n):
        return [c for c in n.children if c.is_rect and c.active and not is_layout_ignored(c)]

    def inputs(self, n, axis):
        """(min, preferred, flexible) as LayoutUtility reads them: per property the component
        with the highest layoutPriority that gives a value >= 0 wins (LayoutElement 1 by default,
        everything else 0; among equals the larger value)."""
        key = (id(n), axis)
        if key in self._inputs:
            return self._inputs[key]
        cands = [[], [], []]
        le = n.comp("LayoutElement")
        if enabled(le):
            prio = int(_num(le.get("m_LayoutPriority", 1), 1))
            names = [("m_MinWidth", "m_PreferredWidth", "m_FlexibleWidth"), ("m_MinHeight", "m_PreferredHeight", "m_FlexibleHeight")][axis]
            for i, nm in enumerate(names):
                cands[i].append((prio, _num(le.get(nm, -1), -1)))
        kind, cfg = layout_group_of(n)
        if kind is not None:
            for i, v in enumerate(self.group_inputs(n, kind, cfg, axis)):
                cands[i].append((0, v))
        img = n.comp("Image")
        if enabled(img):
            sz = self.sprite_size(n, img)
            cands[0].append((0, 0.0))
            cands[1].append((0, sz[axis] if sz else 0.0))
            cands[2].append((0, -1.0))
        for tname in ("Text", "TextMeshProUGUI"):
            if enabled(n.comp(tname)):
                n.text_sized = True   # the preferred size needs the font: unknown here
                cands[0].append((0, 0.0))
                cands[1].append((0, 0.0))
                cands[2].append((0, -1.0))
        res = []
        for i in range(3):
            best_p, best_v = None, 0.0
            for prio, v in cands[i]:
                if best_p is not None and prio < best_p:
                    continue
                if v < 0:
                    continue
                if best_p is None or prio > best_p:
                    best_p, best_v = prio, v
                elif v > best_v:
                    best_v = v
            res.append(best_v)
        res[1] = max(res[0], res[1])
        self._inputs[key] = tuple(res)
        return self._inputs[key]

    def child_sizes(self, c, axis, control, force_expand):
        if not control:
            mn = c.size_delta[axis]
            pref, flex = mn, 0.0
        else:
            mn, pref, flex = self.inputs(c, axis)
        if force_expand:
            flex = max(flex, 1.0)
        return mn, pref, flex

    @staticmethod
    def _padding(cfg):
        pad = cfg.get("m_Padding") or {}
        return tuple(_num(pad.get(k)) for k in ("m_Left", "m_Right", "m_Top", "m_Bottom"))

    def group_inputs(self, n, kind, cfg, axis):
        left, right, top, bottom = self._padding(cfg)
        padding = (left + right) if axis == 0 else (top + bottom)
        kids = self.rect_children(n)
        if kind == "GridLayoutGroup":
            cell = _vec(cfg.get("m_CellSize"), "xy", (100, 100))
            gap = _vec(cfg.get("m_Spacing"), "xy", (0, 0))
            constraint = int(_num(cfg.get("m_Constraint", 0)))
            count = max(int(_num(cfg.get("m_ConstraintCount", 2), 2)), 1)
            if axis == 0:
                if constraint == 1:
                    min_cols = pref_cols = count
                elif constraint == 2:
                    min_cols = pref_cols = math.ceil(len(kids) / count - 0.001)
                else:
                    min_cols = 1
                    pref_cols = math.ceil(math.sqrt(len(kids)))
                return (padding + (cell[0] + gap[0]) * min_cols - gap[0], padding + (cell[0] + gap[0]) * pref_cols - gap[0], -1.0)
            if constraint == 1:
                min_rows = math.ceil(len(kids) / count - 0.001)
            elif constraint == 2:
                min_rows = count
            else:
                cols = max(1, math.floor((n.size[0] - (left + right) + gap[0] + 0.001) / (cell[0] + gap[0])))
                min_rows = math.ceil(len(kids) / cols)
            v = padding + (cell[1] + gap[1]) * min_rows - gap[1]
            return (v, v, -1.0)
        vertical = kind == "VerticalLayoutGroup"
        other = vertical != (axis == 1)
        control = _num(cfg.get("m_ChildControlWidth" if axis == 0 else "m_ChildControlHeight", 1), 1) != 0
        use_scale = _num(cfg.get("m_ChildScaleWidth" if axis == 0 else "m_ChildScaleHeight", 0)) != 0
        expand = _num(cfg.get("m_ChildForceExpandWidth" if axis == 0 else "m_ChildForceExpandHeight", 1), 1) != 0
        spacing = _num(cfg.get("m_Spacing", 0))
        total_min = total_pref = float(padding)
        total_flex = 0.0
        for c in kids:
            mn, pref, flex = self.child_sizes(c, axis, control, expand)
            if use_scale:
                sf = c.local_scale[axis]
                mn, pref, flex = mn * sf, pref * sf, flex * sf
            if other:
                total_min = max(mn + padding, total_min)
                total_pref = max(pref + padding, total_pref)
                total_flex = max(flex, total_flex)
            else:
                total_min += mn + spacing
                total_pref += pref + spacing
                total_flex += flex
        if not other and kids:
            total_min -= spacing
            total_pref -= spacing
        total_pref = max(total_min, total_pref)
        return (total_min, total_pref, total_flex)

    # --- ILayoutController ------------------------------------------------------------------
    def start_offset(self, n, cfg, axis, required_without_padding):
        left, right, top, bottom = self._padding(cfg)
        required = required_without_padding + ((left + right) if axis == 0 else (top + bottom))
        align = int(_num(cfg.get("m_ChildAlignment", 0)))
        frac = (align % 3) * 0.5 if axis == 0 else (align // 3) * 0.5
        return (left if axis == 0 else top) + (n.size[axis] - required) * frac

    def linear(self, n, kind, cfg, axis):
        vertical = kind == "VerticalLayoutGroup"
        other = vertical != (axis == 1)
        left, right, top, bottom = self._padding(cfg)
        pad_total = (left + right) if axis == 0 else (top + bottom)
        control = _num(cfg.get("m_ChildControlWidth" if axis == 0 else "m_ChildControlHeight", 1), 1) != 0
        use_scale = _num(cfg.get("m_ChildScaleWidth" if axis == 0 else "m_ChildScaleHeight", 0)) != 0
        expand = _num(cfg.get("m_ChildForceExpandWidth" if axis == 0 else "m_ChildForceExpandHeight", 1), 1) != 0
        spacing = _num(cfg.get("m_Spacing", 0))
        align = int(_num(cfg.get("m_ChildAlignment", 0)))
        align_frac = (align % 3) * 0.5 if axis == 0 else (align // 3) * 0.5
        size = n.size[axis]
        kids = self.rect_children(n)
        if _num(cfg.get("m_ReverseArrangement", 0)) != 0:
            kids = list(reversed(kids))
        if other:
            inner = size - pad_total
            for c in kids:
                mn, pref, flex = self.child_sizes(c, axis, control, expand)
                sf = c.local_scale[axis] if use_scale else 1.0
                hi = size if flex > 0 else pref
                required = max(mn, min(inner, hi)) if hi >= mn else hi   # Mathf.Clamp(inner, min, hi)
                start = self.start_offset(n, cfg, axis, required * sf)
                if control:
                    self.set_child(c, axis, start, required, sf)
                else:
                    self.set_child(c, axis, start + (required - c.size_delta[axis]) * align_frac, None, sf)
            return
        mn_t, pref_t, flex_t = self.group_inputs(n, kind, cfg, axis)
        pos = left if axis == 0 else top
        flex_mult = 0.0
        surplus = size - pref_t
        if surplus > 0:
            if flex_t == 0:
                pos = self.start_offset(n, cfg, axis, pref_t - pad_total)
            elif flex_t > 0:
                flex_mult = surplus / flex_t
        lerp = 0.0
        if mn_t != pref_t:
            lerp = min(max((size - mn_t) / (pref_t - mn_t), 0.0), 1.0)
        for c in kids:
            mn, pref, flex = self.child_sizes(c, axis, control, expand)
            sf = c.local_scale[axis] if use_scale else 1.0
            child_size = mn + (pref - mn) * lerp + flex * flex_mult
            if control:
                self.set_child(c, axis, pos, child_size, sf)
            else:
                self.set_child(c, axis, pos + (child_size - c.size_delta[axis]) * align_frac, None, sf)
            pos += child_size * sf + spacing

    def grid(self, n, cfg, axis):
        kids = self.rect_children(n)
        left, right, top, bottom = self._padding(cfg)
        cell = _vec(cfg.get("m_CellSize"), "xy", (100, 100))
        gap = _vec(cfg.get("m_Spacing"), "xy", (0, 0))
        if axis == 0:
            # the horizontal pass only sizes the cells
            for c in kids:
                c.anchor_min = [0.0, 1.0]
                c.anchor_max = [0.0, 1.0]
                c.size_delta = [cell[0], cell[1]]
                c.driven = True
            return
        width, height = n.size
        constraint = int(_num(cfg.get("m_Constraint", 0)))
        count = max(int(_num(cfg.get("m_ConstraintCount", 2), 2)), 1)
        total = len(kids)
        cols = rows = 1
        if constraint == 1:
            cols = count
            if total > cols:
                rows = total // cols + (1 if total % cols > 0 else 0)
        elif constraint == 2:
            rows = count
            if total > rows:
                cols = total // rows + (1 if total % rows > 0 else 0)
        else:
            cols = 2 ** 31 - 1 if cell[0] + gap[0] <= 0 else max(1, math.floor((width - left - right + gap[0] + 0.001) / (cell[0] + gap[0])))
            rows = 2 ** 31 - 1 if cell[1] + gap[1] <= 0 else max(1, math.floor((height - top - bottom + gap[1] + 0.001) / (cell[1] + gap[1])))
        corner = int(_num(cfg.get("m_StartCorner", 0)))
        clamp = lambda v, lo, hi: max(lo, min(v, hi))
        if int(_num(cfg.get("m_StartAxis", 0))) == 0:
            per_main = cols
            actual_x = clamp(cols, 1, total)
            actual_y = clamp(rows, 1, math.ceil(total / per_main))
            horizontal = True
        else:
            per_main = rows
            actual_y = clamp(rows, 1, total)
            actual_x = clamp(cols, 1, math.ceil(total / per_main))
            horizontal = False
        required = (actual_x * cell[0] + (actual_x - 1) * gap[0], actual_y * cell[1] + (actual_y - 1) * gap[1])
        start = (self.start_offset(n, cfg, 0, required[0]), self.start_offset(n, cfg, 1, required[1]))
        for i, c in enumerate(kids):
            px, py = (i % per_main, i // per_main) if horizontal else (i // per_main, i % per_main)
            if corner % 2 == 1:
                px = actual_x - 1 - px
            if corner // 2 == 1:
                py = actual_y - 1 - py
            self.set_child(c, 0, start[0] + (cell[0] + gap[0]) * px, cell[0], 1.0)
            self.set_child(c, 1, start[1] + (cell[1] + gap[1]) * py, cell[1], 1.0)

    def aspect(self, n, arf):
        """AspectRatioFitter.UpdateRect (it reacts to size changes, not to the layout passes)."""
        mode = int(_num(arf.get("m_AspectMode", 0)))
        ratio = min(max(_num(arf.get("m_AspectRatio", 1), 1), 0.001), 1000.0)
        if mode == 1:      # WidthControlsHeight
            self.set_size_with_current_anchors(n, 1, n.size[0] / ratio)
        elif mode == 2:    # HeightControlsWidth
            self.set_size_with_current_anchors(n, 0, n.size[1] * ratio)
        elif mode in (3, 4):   # FitInParent, EnvelopeParent
            psize = n.parent.size if (n.parent is not None and n.parent.is_rect) else [0.0, 0.0]
            n.anchor_min = [0.0, 0.0]
            n.anchor_max = [1.0, 1.0]
            n.anchored_position = [0.0, 0.0]
            n.size_delta = [0.0, 0.0]
            if (psize[1] * ratio < psize[0]) != (mode == 3):
                n.size_delta[1] = psize[0] / ratio - psize[1]
            else:
                n.size_delta[0] = psize[1] * ratio - psize[0]
            self.place(n, 0)
            self.place(n, 1)
        if mode != 0:
            n.driven = True

    def set_axis(self, n, axis, shown):
        """PerformLayoutControl for one axis: this object's fitters, its group, then the children
        (whose rects follow from the values just written). Inactive objects are not laid out."""
        if shown:
            fitter = n.comp("ContentSizeFitter")
            if enabled(fitter):
                mode = int(_num(fitter.get("m_HorizontalFit" if axis == 0 else "m_VerticalFit", 0)))
                if mode != 0:
                    mn, pref, _flex = self.inputs(n, axis)
                    self.set_size_with_current_anchors(n, axis, mn if mode == 1 else pref)
                    n.driven = True
            kind, cfg = layout_group_of(n)
            if kind == "GridLayoutGroup":
                self.grid(n, cfg, axis)
            elif kind is not None:
                self.linear(n, kind, cfg, axis)
        for c in n.children:
            if not c.is_rect:
                continue
            self.place(c, axis)
            arf = c.comp("AspectRatioFitter")
            if axis == 1 and shown and c.active and enabled(arf):
                self.aspect(c, arf)
            self.set_axis(c, axis, shown and c.active)

    # --- driver -----------------------------------------------------------------------------
    def layout_canvas(self, canvas, screen):
        cv = canvas.comp("Canvas")
        mode = int(_num(cv.get("m_RenderMode", 0)))
        canvas.screen_space = mode != 2 and (canvas.parent is None or not canvas.parent.is_rect)
        if canvas.screen_space:
            # the canvas rect is the screen divided by the scale factor, pivot in the middle
            factor = canvas_scale_factor(canvas, screen)
            canvas.scale_factor = factor
            canvas.pivot = [0.5, 0.5]
        # the vertical pass can change what the horizontal one saw (aspect fitters, wrapped grids):
        # Unity rebuilds again on the next frame, so run the passes until nothing moves
        for _round in range(3):
            for axis in (0, 1):
                self._inputs = {}
                if canvas.screen_space:
                    canvas.size[axis] = screen[axis] / canvas.scale_factor
                    canvas.pos[axis] = 0.0
                    canvas.laid = True
                else:
                    self.place(canvas, axis)
                self.set_axis(canvas, axis, canvas.active)


# --------------------------------------------------------------------------------------------
# Selectables, graphics and text
# --------------------------------------------------------------------------------------------

SELECTABLES = ("Button", "Toggle", "Slider", "Scrollbar", "InputField", "Dropdown", "TMP_InputField", "TMP_Dropdown")
GRAPHICS = ("Image", "RawImage", "Text", "TextMeshProUGUI")


def _color(d, default=(1.0, 1.0, 1.0, 1.0)):
    if not isinstance(d, dict):
        return list(default)
    return [_num(d.get(k), default[i]) for i, k in enumerate("rgba")]


def apply_selectables(nodes):
    """What a Selectable writes to other objects when it is enabled (Selectable.OnEnable →
    DoStateTransition, Toggle.PlayEffect, Slider.UpdateVisuals), before any input."""
    owner = {}
    for n in nodes.values():
        for cid in n.component_ids:
            owner[cid] = n
    for n in nodes.values():
        for name, d in n.components:
            if name not in SELECTABLES or not enabled(d):
                continue
            # colour tint: the target graphic's CanvasRenderer colour is the state's colour
            target = owner.get(_ref_id(d.get("m_TargetGraphic")))
            if target is not None and int(_num(d.get("m_Transition", 1), 1)) == 1:
                block = d.get("m_Colors") or {}
                interactable = _num(d.get("m_Interactable", 1), 1) != 0
                tint = _color(block.get("m_NormalColor" if interactable else "m_DisabledColor"))
                mul = _num(block.get("m_ColorMultiplier", 1), 1)
                target.renderer_color = [min(max(x * mul, 0.0), 1.0) for x in tint]
            if name == "Toggle":
                mark = owner.get(_ref_id(d.get("graphic")))
                if mark is not None:
                    mark.renderer_color = mark.renderer_color[:3] + [1.0 if _num(d.get("m_IsOn", 0)) != 0 else 0.0]
            if name in ("InputField", "TMP_InputField"):
                for key in ("m_TextComponent", "m_Placeholder"):
                    part = owner.get(_ref_id(d.get(key)))
                    if part is not None:
                        part.field_text = True
            if name == "Slider":
                lo, hi = _num(d.get("m_MinValue", 0)), _num(d.get("m_MaxValue", 1), 1)
                value = min(max(_num(d.get("m_Value", 0)), lo), hi)
                if _num(d.get("m_WholeNumbers", 0)) != 0:
                    value = round(value)
                t = (value - lo) / (hi - lo) if hi > lo else 0.0
                direction = int(_num(d.get("m_Direction", 0)))
                axis = 0 if direction < 2 else 1
                reverse = direction in (1, 3)
                fill = nodes.get(_ref_id(d.get("m_FillRect")))
                if fill is not None and fill.parent is not None and fill.parent.is_rect:
                    amin, amax = [0.0, 0.0], [1.0, 1.0]
                    img = fill.comp("Image")
                    if not (img is not None and int(_num(img.get("m_Type", 0))) == 3):
                        if reverse:
                            amin[axis] = 1.0 - t
                        else:
                            amax[axis] = t
                    fill.anchor_min, fill.anchor_max = amin, amax
                handle = nodes.get(_ref_id(d.get("m_HandleRect")))
                if handle is not None and handle.parent is not None and handle.parent.is_rect:
                    amin, amax = [0.0, 0.0], [1.0, 1.0]
                    amin[axis] = amax[axis] = (1.0 - t) if reverse else t
                    handle.anchor_min, handle.anchor_max = amin, amax


def graphic_of(n):
    for name, d in n.components:
        if name in GRAPHICS:
            return name, d
    return None, None


def drawn_color(n, group_alpha):
    """The colour a node's Graphic is drawn with: its own colour × the CanvasRenderer colour,
    alpha × the canvas groups above; alpha 0 when the component is disabled or a Mask hides it."""
    name, d = graphic_of(n)
    if name is None:
        return None
    own = _color(d.get("m_fontColor") if name == "TextMeshProUGUI" else d.get("m_Color"))
    c = [own[i] * n.renderer_color[i] for i in range(4)]
    c[3] *= group_alpha
    m = n.comp("Mask")
    if not enabled(d) or (enabled(m) and _num(m.get("m_ShowMaskGraphic", 1), 1) == 0):
        c[3] = 0.0
    return c


_TMP_TAGS = ("b", "i", "u", "s", "strikethrough", "br", "color", "size", "align", "mark", "uppercase", "allcaps", "smallcaps", "lowercase",
             "nobr", "font", "material", "line-height", "line-indent", "indent", "margin", "margin-left", "margin-right", "pos", "voffset",
             "cspace", "mspace", "gradient", "link", "style", "width", "sprite", "quad", "rotate", "page", "space", "font-weight", "alpha",
             "sup", "sub", "noparse")
_UGUI_TAGS = ("b", "i", "size", "color", "material", "quad")
_TAG = re.compile(r"<(/?)([A-Za-z-]+|#[0-9A-Fa-f]{3,8})(?:[= ][^<>]*)?>")


def shown_text(n):
    """The characters a Text / TextMeshProUGUI shows: rich text tags removed (only the tags the
    component knows: anything else in angle brackets is text), cased by the font style."""
    name, d = graphic_of(n)
    if name == "TextMeshProUGUI":
        raw, rich, style, tags = d.get("m_text"), _num(d.get("m_isRichText", 1), 1) != 0, int(_num(d.get("m_fontStyle", 0))), _TMP_TAGS
    elif name == "Text":
        fd = d.get("m_FontData") or {}
        raw, rich, style, tags = d.get("m_Text"), _num(fd.get("m_RichText", 1), 1) != 0, 0, _UGUI_TAGS
    else:
        return None
    raw = "" if raw is None else str(raw)
    case = [1 if style & (16 | 32) else 0, 1 if style & 8 else 0]   # upper, lower

    def cased(t):
        return t.upper() if case[0] > 0 else (t.lower() if case[1] > 0 else t)
    if not rich:
        return cased(raw)
    out = []
    pos = 0
    for m in _TAG.finditer(raw):
        tag = m.group(2).lower()
        if tag.startswith("#"):
            tag = "color" if name == "TextMeshProUGUI" else ""
        if tag not in tags:
            continue
        out.append(cased(raw[pos:m.start()]))
        pos = m.end()
        closing = m.group(1) == "/"
        if tag == "br":
            out.append("\n")
        elif tag in ("uppercase", "allcaps", "smallcaps"):
            case[0] = max(case[0] + (-1 if closing else 1), 0)
        elif tag == "lowercase":
            case[1] = max(case[1] + (-1 if closing else 1), 0)
    out.append(cased(raw[pos:]))
    return "".join(out)


def font_size(n):
    """The font size of a text that is not auto-sized."""
    name, d = graphic_of(n)
    if name == "TextMeshProUGUI":
        return None if _num(d.get("m_enableAutoSizing", 0)) != 0 else _num(d.get("m_fontSize", 36), 36)
    if name == "Text":
        fd = d.get("m_FontData") or {}
        return None if _num(fd.get("m_BestFit", 0)) != 0 else _num(fd.get("m_FontSize", 14), 14)
    return None


# Unity's built-in UI sprites: file id → (pixel size, border); 200 pixels per unit
BUILTIN_GUID = "0000000000000000f000000000000000"
BUILTIN_SPRITES = {10901: (40, 0), 10905: (32, 10), 10907: (32, 10), 10911: (32, 10), 10913: (40, 0), 10915: (40, 0), 10917: (32, 10)}


def _image_size(path):
    """Pixel size of a PNG or PSD file, from its header."""
    try:
        with open(path, "rb") as fh:
            head = fh.read(26)
    except OSError:
        return None
    if head[:8] == b"\x89PNG\r\n\x1a\n":
        return (int.from_bytes(head[16:20], "big"), int.from_bytes(head[20:24], "big"))
    if head[:4] == b"8BPS":
        return (int.from_bytes(head[18:22], "big"), int.from_bytes(head[14:18], "big"))
    return None


class Sprites:
    """What an Image asks for in a layout: the size of its sprite in canvas units (sprite pixels
    × canvas reference pixels per unit / sprite pixels per unit), or the sum of its borders when
    it is sliced or tiled (Image.preferredWidth). Read from the texture file and its .meta."""

    def __init__(self, assets):
        self.assets = assets
        self._info = {}

    def info(self, ref):
        """→ (width, height, [left, bottom, right, top], pixels per unit) or None."""
        if not isinstance(ref, dict) or not _ref_id(ref):
            return None
        guid, fid = ref.get("guid", ""), _ref_id(ref)
        if guid == BUILTIN_GUID:
            b = BUILTIN_SPRITES.get(fid)
            return (b[0], b[0], [b[1]] * 4, 200.0) if b else None
        key = (guid, fid)
        if key in self._info:
            return self._info[key]
        out = None
        path = self.assets.guid_to_path.get(guid)
        size = _image_size(path) if path else None
        if size is not None:
            try:
                meta = open(path + ".meta", errors="replace").read()
            except OSError:
                meta = ""
            m = re.search(r"^\s*spritePixelsToUnits:\s*([-\d.e]+)", meta, re.M)
            ppu = float(m.group(1)) if m else 100.0
            border = [0.0] * 4
            m = re.search(r"^  spriteBorder:\s*\{x:\s*([-\d.e]+),\s*y:\s*([-\d.e]+),\s*z:\s*([-\d.e]+),\s*w:\s*([-\d.e]+)\}", meta, re.M)
            if m:
                border = [float(x) for x in m.groups()]
            w, h = size
            # a sprite of a sheet: its own rect and border
            for block in re.split(r"\n    - serializedVersion: \d+\n", meta)[1:]:
                if re.search(r"^\s*internalID:\s*%d\s*$" % fid, block, re.M):
                    r = re.search(r"rect:\s*\n\s*serializedVersion: \d+\s*\n\s*x:\s*([-\d.e]+)\s*\n\s*y:\s*([-\d.e]+)\s*\n\s*width:\s*([-\d.e]+)\s*\n\s*height:\s*([-\d.e]+)", block)
                    if r:
                        w, h = float(r.group(3)), float(r.group(4))
                    bm = re.search(r"border:\s*\{x:\s*([-\d.e]+),\s*y:\s*([-\d.e]+),\s*z:\s*([-\d.e]+),\s*w:\s*([-\d.e]+)\}", block)
                    if bm:
                        border = [float(x) for x in bm.groups()]
                    break
            out = (float(w), float(h), border, ppu)
        self._info[key] = out
        return out

    def preferred(self, n, img):
        info = self.info(img.get("m_Sprite"))
        if info is None:
            return None
        w, h, border, ppu = info
        unit = reference_ppu(n) / max(ppu, 1e-4)
        if int(_num(img.get("m_Type", 0))) in (1, 2):
            return ((border[0] + border[2]) * unit, (border[1] + border[3]) * unit)
        return (w * unit, h * unit)


def reference_ppu(n):
    """CanvasScaler.referencePixelsPerUnit of the canvas a node is on (100 without a scaler)."""
    cur = n
    while cur is not None:
        if cur.has("Canvas"):
            sc = cur.comp("CanvasScaler")
            if enabled(sc):
                return _num(sc.get("m_ReferencePixelsPerUnit", 100), 100)
            if cur.parent is None or not cur.parent.is_rect:
                return 100.0
        cur = cur.parent
    return 100.0


def canvas_scale_factor(canvas, screen):
    scaler = canvas.comp("CanvasScaler")
    if not enabled(scaler):
        return 1.0
    mode = int(_num(scaler.get("m_UiScaleMode", 0)))
    if mode == 0:
        return max(_num(scaler.get("m_ScaleFactor", 1), 1), 1e-6)
    if mode == 1:
        ref = _vec(scaler.get("m_ReferenceResolution"), "xy", (800, 600))
        match_mode = int(_num(scaler.get("m_ScreenMatchMode", 0)))
        if match_mode == 0:
            match = min(max(_num(scaler.get("m_MatchWidthOrHeight", 0)), 0.0), 1.0)
            lw = math.log2(screen[0] / ref[0])
            lh = math.log2(screen[1] / ref[1])
            return 2 ** (lw + (lh - lw) * match)
        if match_mode == 1:
            return min(screen[0] / ref[0], screen[1] / ref[1])
        return max(screen[0] / ref[0], screen[1] / ref[1])
    return 96.0 / max(_num(scaler.get("m_DefaultSpriteDPI", 96), 96), 1.0)   # constant physical size at 96 dpi


# --------------------------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------------------------

def find_canvases(roots):
    out = []

    def walk(n, inside):
        is_canvas = n.has("Canvas")
        if is_canvas and not inside:
            out.append(n)
        for c in n.children:
            walk(c, inside or is_canvas)
    for r in roots:
        walk(r, False)
    return out


def local_matrix(n):
    """Node local space → parent local space (a laid-out rect's origin is its pivot)."""
    if n.is_rect and n.laid:
        return mat_trs([n.pos[0], n.pos[1], n.local_position[2]], n.local_rotation, n.local_scale)
    return mat_trs(n.local_position, n.local_rotation, n.local_scale)


def world_matrix(n, screen=(0.0, 0.0)):
    chain = []
    cur = n
    while cur is not None:
        chain.append(cur)
        if getattr(cur, "screen_space", False):
            break
        cur = cur.parent
    m = mat_identity()
    for c in reversed(chain):
        if getattr(c, "screen_space", False):
            # Unity puts a screen canvas's pivot at the screen centre and scales it by the factor
            f = c.scale_factor
            m = mat_trs([screen[0] * 0.5, screen[1] * 0.5, 0.0], [0, 0, 0, 1], [f, f, f])
        else:
            m = mat_mul(m, local_matrix(c))
    return m


def corners_of(n, m):
    w, h = n.size
    px, py = n.pivot
    return [mat_point(m, [lx, ly, 0.0]) for lx, ly in ((-px * w, -py * h), (-px * w, (1 - py) * h), ((1 - px) * w, (1 - py) * h), ((1 - px) * w, -py * h))]


def describe_canvas(canvas, layout, screen):
    layout.layout_canvas(canvas, screen)
    cv = canvas.comp("Canvas")
    wm = world_matrix(canvas, screen)
    scale = [math.sqrt(sum(wm[i][j] ** 2 for i in range(3))) for j in range(3)]
    entry = {
        "path": canvas.path(),
        "mode": "overlay" if canvas.screen_space else "world",
        "size": canvas.size[:],
        "pivot": canvas.pivot[:],
        "world_scale": scale,
        "world_position": [wm[0][3], wm[1][3], wm[2][3]],
        "active": canvas.active,
        "nodes": [],
    }

    def group_alpha(n):
        g = n.comp("CanvasGroup")
        return min(max(_num(g.get("m_Alpha", 1), 1), 0.0), 1.0) if enabled(g) else 1.0

    def walk(n, parent_m, shown, negative, alpha):
        for c in n.children:
            if not c.is_rect:
                continue
            m = mat_mul(parent_m, local_matrix(c))
            calpha = alpha * group_alpha(c)
            q = c.local_rotation
            e = {
                "path": c.path(canvas),
                "corners": corners_of(c, m),
                "size": c.size[:],
                "active": c.active,
                "shown": shown and c.active,
                "components": [name for name, _d in c.components if name != "CanvasRenderer"],
            }
            if abs(q[0]) > 1e-4 or abs(q[1]) > 1e-4:
                e["rotated_3d"] = True
            if abs(c.local_position[2]) > 1e-6:
                e["z"] = c.local_position[2]
            if c.text_sized and c.driven:
                e["text_sized"] = True
            if c.driven:
                e["driven"] = True
            if negative or c.size[0] < 0 or c.size[1] < 0:
                # Unity lays children out against a negative-size rect; a Control cannot be negative
                e["negative_size"] = True
            color = drawn_color(c, calpha)
            if color is not None:
                e["graphic"] = color
            text = shown_text(c)
            if text is not None:
                e["text"] = text
                if font_size(c) is not None:
                    e["font_size"] = font_size(c)
            if c.field_text:
                e["field_text"] = True   # drawn by the input field itself
            entry["nodes"].append(e)
            walk(c, m, shown and c.active, negative or c.size[0] < 0 or c.size[1] < 0, calpha)
    walk(canvas, wm, canvas.active, False, group_alpha(canvas))
    return entry


def reference(assets_dir, target, screen=(1152.0, 648.0)):
    assets = Assets(assets_dir)
    model = assets.flatten(target)
    nodes, roots = build_graph(model, assets)
    layout = Layout(Sprites(assets).preferred)
    apply_selectables(nodes)
    out = [describe_canvas(c, layout, screen) for c in find_canvases(roots)]
    return out, assets.warnings, nodes


# --------------------------------------------------------------------------------------------
# Compare with a dump of the imported world (unidot's test/ui_dump.gd)
# --------------------------------------------------------------------------------------------

def godot_name(name):
    """Godot's node-name sanitising: . : @ / " % are replaced by underscores."""
    return re.sub(r'[.:@/"%]', "_", name).strip()


def _tree(nodes):
    root = {"children": [], "entry": None}
    index = {"": root}
    for e in nodes:
        parent, _, _leaf = e["path"].rpartition("/")
        node = {"children": [], "entry": e}
        index[e["path"]] = node
        index.get(parent, root)["children"].append(node)
    return root


def _same_name(want, got):
    return got == want or re.fullmatch(re.escape(want) + r"_?\d+", got) is not None or re.fullmatch("@?" + re.escape(want) + r"@\d+", got) is not None


def compare(ref, dump, tolerance, rel, check_active=False):
    """→ (matched, problems). Corners are compared in world space: metres for world canvases
    (tolerance + rel × the rect's diagonal), window pixels for screen canvases (250 × tolerance)."""
    problems = []
    matched = 0
    canvases = dump["canvases"] if isinstance(dump, dict) else dump
    used = set()
    for rc in ref:
        want_path = "/".join(godot_name(p) for p in rc["path"].split("/"))
        dc = None
        for i, cand in enumerate(canvases):
            if i in used:
                continue
            if cand["path"] == want_path or cand["path"].endswith("/" + want_path) or want_path.endswith("/" + cand["path"]):
                dc = cand
                used.add(i)
                break
        if dc is None:
            problems.append("canvas %s: not in the imported scene" % rc["path"])
            continue
        if dc.get("mode") != rc["mode"]:
            problems.append("canvas %s: imported as %s, Unity render mode is %s" % (rc["path"], dc.get("mode"), rc["mode"]))
        tol = tolerance if rc["mode"] == "world" else tolerance * 250.0
        for i in range(2):
            if abs(dc["size"][i] - rc["size"][i]) > max(1e-4, abs(rc["size"][i]) * rel):
                problems.append("canvas %s: size %s, Unity %s" % (rc["path"], _fmt(dc["size"]), _fmt(rc["size"])))
                break

        def walk(rnode, dnode):
            nonlocal matched
            taken = set()
            for rch in rnode["children"]:
                e = rch["entry"]
                want = godot_name(e["path"].split("/")[-1])
                found = None
                for i, dch in enumerate(dnode["children"]) if dnode else []:
                    if i not in taken and _same_name(want, dch["entry"]["path"].split("/")[-1]):
                        found = i
                        break
                if found is None:
                    problems.append("%s :: %s: missing in the imported canvas" % (rc["path"], e["path"]))
                    walk(rch, None)
                    continue
                taken.add(found)
                dch = dnode["children"][found]
                matched += 1
                d = dch["entry"]
                diag = math.dist(e["corners"][0], e["corners"][2])
                limit = tol + diag * rel
                worst = max(math.dist(a, b) if all(math.isfinite(x) for x in b) else float("inf") for a, b in zip(e["corners"], d["corners"]))
                if worst > limit and not e.get("negative_size"):
                    note = "  [text-sized: needs the font]" if e.get("text_sized") else ""
                    if not e.get("text_sized") or worst > limit * 20:
                        problems.append("%s :: %s: off by %.4g (limit %.3g)  Unity %s, imported %s%s%s" % (rc["path"], e["path"], worst, limit, _corners(e["corners"]), _corners(d["corners"]), "" if e["shown"] else "  [hidden]", note))
                if check_active and bool(d.get("active", True)) != bool(e["active"]):
                    problems.append("%s :: %s: active %s, Unity %s" % (rc["path"], e["path"], d.get("active"), e["active"]))
                problems.extend("%s :: %s: %s" % (rc["path"], e["path"], p) for p in _drawn_problems(e, d))
                walk(rch, dch)
        walk(_tree(rc["nodes"]), _tree(dc["nodes"]))
    return matched, problems


def _drawn_problems(e, d):
    """What is drawn: the graphic's colour (or that nothing is drawn), the text and its size."""
    out = []
    if e.get("field_text"):
        return out
    if "graphic" in e:
        want = e["graphic"]
        got = d.get("graphic")
        if got is None:
            if want[3] > 0.02:
                out.append("draws no graphic, Unity draws %s" % _fmt(want))
        elif abs(want[3] - got[3]) > 0.02 or (want[3] > 0.02 and max(abs(a - b) for a, b in zip(want[:3], got[:3])) > 0.02):
            out.append("drawn colour %s, Unity %s" % (_fmt(got), _fmt(want)))
    if "text" in e and "text" in d:
        want_t, got_t = " ".join(e["text"].split()), " ".join(str(d["text"]).split())
        if want_t != got_t:
            out.append("text %r, Unity shows %r" % (got_t[:80], want_t[:80]))
    if "font_size" in e and "font_size" in d and abs(e["font_size"] - d["font_size"]) > 0.51:
        out.append("font size %s, Unity %s" % (d["font_size"], e["font_size"]))
    return out


def _fmt(v):
    return "(" + ", ".join("%.5g" % x for x in v) + ")"


def _corners(c):
    return "bl %s tr %s" % (_fmt(c[0]), _fmt(c[2]))


# --------------------------------------------------------------------------------------------

def survey(ref, nodes):
    print("%d root canvases" % len(ref))
    for c in ref:
        print("\n== %s  [%s]  size %s pivot %s world scale %s  %s" % (c["path"], c["mode"], _fmt(c["size"]), _fmt(c["pivot"]), _fmt(c["world_scale"]), "" if c["active"] else "INACTIVE"))
        for e in c["nodes"]:
            depth = e["path"].count("/")
            flags = []
            if not e["active"]:
                flags.append("inactive")
            for k in ("rotated_3d", "driven", "text_sized", "negative_size"):
                if e.get(k):
                    flags.append(k)
            if "z" in e:
                flags.append("z=%g" % e["z"])
            print("  %s%-28s %-58s size %-18s %s %s" % ("  " * depth, e["path"].split("/")[-1][:28], _corners(e["corners"]), _fmt(e["size"]), ",".join(e["components"]), " ".join(flags)))
    # the distinct RectTransform cases, counted over every UI node
    stats = {}

    def bump(k):
        stats[k] = stats.get(k, 0) + 1
    for n in nodes.values():
        if not n.is_rect:
            continue
        bump("rect transforms")
        stretched = [n.anchor_min[i] != n.anchor_max[i] for i in range(2)]
        bump("anchors: point" if not any(stretched) else ("anchors: stretch both" if all(stretched) else "anchors: stretch one axis"))
        if not any(stretched) and (n.anchor_min != [0.5, 0.5]):
            bump("anchors: point not at the centre")
        if n.pivot != [0.5, 0.5]:
            bump("pivot not centred")
        if any(abs(s - 1.0) > 1e-6 for s in n.local_scale[:2]):
            bump("scaled")
        if abs(n.local_scale[0] - n.local_scale[1]) > 1e-6:
            bump("scaled non-uniformly")
        if any(s < 0 for s in n.local_scale[:2]):
            bump("negative scale")
        q = n.local_rotation
        if abs(q[2]) > 1e-6 and abs(q[0]) < 1e-6 and abs(q[1]) < 1e-6:
            bump("rotated about z")
        if abs(q[0]) > 1e-6 or abs(q[1]) > 1e-6:
            bump("rotated about x / y")
        if abs(n.local_position[2]) > 1e-6:
            bump("z offset")
        if n.size[0] < 0 or n.size[1] < 0:
            bump("negative size")
        if n.size[0] == 0 or n.size[1] == 0:
            bump("zero size")
        if n.has("Canvas"):
            bump("canvas (root or nested)")
        if n.parent is not None and not n.parent.is_rect and not n.has("Canvas"):
            bump("rect transform under a plain transform, no canvas")
        if any(not c.is_rect for c in n.children):
            bump("plain transform child under a rect transform")
        for name, _d in n.components:
            if name in UI_SCRIPTS.values() or name in ("Canvas", "CanvasGroup", "VRC_UiShape"):
                bump("component: " + name)
    print("\n== cases")
    for k in sorted(stats):
        print("  %-52s %d" % (k, stats[k]))


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    assets_dir, target = argv[1], argv[2]
    args = argv[3:]

    def opt(name, default=None):
        if name in args:
            i = args.index(name)
            return args[i + 1] if i + 1 < len(args) else default
        return default
    screen = tuple(float(x) for x in str(opt("--screen", "1152x648")).split("x"))
    dump = None
    if "--compare" in args:
        with open(opt("--compare")) as f:
            dump = json.load(f)
        if isinstance(dump, dict) and dump.get("screen") and dump["screen"][0] > 0:
            screen = tuple(float(x) for x in dump["screen"])   # the window the dump was taken in
    ref, warnings, nodes = reference(assets_dir, target, screen)
    for w in warnings:
        print("note: " + w, file=sys.stderr)
    if "--json" in args:
        with open(opt("--json"), "w") as f:
            json.dump(ref, f, indent=1)
    if "--survey" in args:
        survey(ref, nodes)
    if dump is not None:
        matched, problems = compare(ref, dump, float(opt("--tolerance", "0.002")), float(opt("--relative", "0.01")), "--active" in args)
        total = sum(len(c["nodes"]) for c in ref)
        for p in problems:
            print("  MISMATCH " + p)
        print("UI reference: %d canvases, %d of %d nodes matched, %d problem(s)" % (len(ref), matched, total, len(problems)))
        return 1 if problems else 0
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
