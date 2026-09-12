#!/usr/bin/env python3
"""Convert a Unity project's ProjectSettings/ into Godot project settings for an imported world.

    scripts/unity_project_settings.py <UnityProject/ProjectSettings> <godot_project_dir>

Writes into <godot_project_dir>/project.godot:
  [layer_names]  3d_physics/layer_N and 3d_render/layer_N   from TagManager.asset (layers)
  [physics]      3d/default_gravity(_vector), common/physics_ticks_per_second
                 from DynamicsManager.asset (m_Gravity) and TimeManager.asset (Fixed Timestep)
  [udon]         collision_matrix (32 ints: Godot mask per Unity layer, from the layer
                 collision matrix in DynamicsManager.asset; udon_runtime applies it to bodies),
                 tags (from TagManager.asset)
  [input]        actions for InputManager.asset axes with keyboard bindings

VRChat asset packages usually have no ProjectSettings folder; the runtime then uses the VRChat
default layer table. Godot layers are 1-based in settings, Unity layers 0-based.
"""
import os
import re
import sys

KEY_MAP = {
    "space": "Space", "escape": "Escape", "enter": "Enter", "return": "Enter", "tab": "Tab",
    "left shift": "Shift", "right shift": "Shift", "left ctrl": "Ctrl", "right ctrl": "Ctrl",
    "left alt": "Alt", "right alt": "Alt", "up": "Up", "down": "Down", "left": "Left", "right": "Right",
    "backspace": "Backspace", "delete": "Delete", "mouse 0": "MOUSE_LEFT", "mouse 1": "MOUSE_RIGHT", "mouse 2": "MOUSE_MIDDLE",
}


def yaml_blocks(text):
    """Split a Unity YAML file into (class, body) blocks."""
    out = []
    for block in re.split(r"^--- !u!\d+ &\d+", text, flags=re.M)[1:]:
        m = re.match(r"\s*(\w+):", block)
        out.append((m.group(1) if m else "", block))
    return out


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def tag_manager(text):
    layers, tags = [], []
    m = re.search(r"^\s*layers:\n((?:\s*- .*\n)*)", text, flags=re.M)
    if m:
        for line in m.group(1).splitlines():
            layers.append(line.strip()[2:].strip())
    m = re.search(r"^\s*tags:\n((?:\s*- .*\n)*)", text, flags=re.M)
    if m:
        for line in m.group(1).splitlines():
            tags.append(line.strip()[2:].strip())
    return layers, tags


def dynamics_manager(text):
    gravity = None
    m = re.search(r"m_Gravity: \{x: ([-\d.e]+), y: ([-\d.e]+), z: ([-\d.e]+)\}", text)
    if m:
        gravity = tuple(float(v) for v in m.groups())
    matrix = []
    m = re.search(r"m_LayerCollisionMatrix: ([0-9a-fA-F]+)", text)
    if m:
        hexstr = m.group(1)
        # 32 little-endian uint32 values, one per layer
        for i in range(0, min(len(hexstr), 256), 8):
            chunk = hexstr[i:i + 8]
            b = bytes.fromhex(chunk)
            matrix.append(int.from_bytes(b, "little"))
    return gravity, matrix


def time_manager(text):
    m = re.search(r"Fixed Timestep: ([\d.e-]+)", text)
    return float(m.group(1)) if m else None


def input_manager(text):
    axes = []
    for block in re.finditer(r"- serializedVersion: 3\n((?:\s{4,}.*\n)+)", text):
        body = block.group(1)
        def get(key):
            mm = re.search(r"^\s*%s: (.*)$" % re.escape(key), body, flags=re.M)
            return mm.group(1).strip() if mm else ""
        axes.append({"name": get("m_Name"), "neg": get("negativeButton"), "pos": get("positiveButton"), "altneg": get("altNegativeButton"), "altpos": get("altPositiveButton"), "type": get("type"), "axis": get("axis")})
    return axes


def key_event(name):
    n = name.lower()
    if n in KEY_MAP:
        k = KEY_MAP[n]
        if k.startswith("MOUSE_"):
            return 'Object(InputEventMouseButton,"button_index":%d)' % {"MOUSE_LEFT": 1, "MOUSE_RIGHT": 2, "MOUSE_MIDDLE": 3}[k]
        return 'Object(InputEventKey,"keycode":%d)' % keycode(k)
    if len(n) == 1 and n.isalnum():
        return 'Object(InputEventKey,"keycode":%d)' % keycode(n.upper())
    return None


def keycode(k):
    specials = {"Space": 32, "Escape": 4194305, "Enter": 4194309, "Tab": 4194306, "Shift": 4194325, "Ctrl": 4194326, "Alt": 4194328, "Up": 4194320, "Down": 4194322, "Left": 4194319, "Right": 4194321, "Backspace": 4194308, "Delete": 4194312}
    if k in specials:
        return specials[k]
    return ord(k)


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    src, dst = sys.argv[1], sys.argv[2]
    project = os.path.join(dst, "project.godot")
    text = read(project)
    if not text:
        print("no project.godot in " + dst)
        return 2
    sections = {}

    layers, tags = tag_manager(read(os.path.join(src, "TagManager.asset")))
    if layers:
        ln = []
        for i, name in enumerate(layers[:32]):
            if name:
                ln.append('3d_physics/layer_%d="%s"' % (i + 1, name.replace('"', "'")))
                ln.append('3d_render/layer_%d="%s"' % (i + 1, name.replace('"', "'")))
        sections["layer_names"] = ln
    gravity, matrix = dynamics_manager(read(os.path.join(src, "DynamicsManager.asset")))
    phys = []
    if gravity:
        g = gravity
        mag = (g[0] ** 2 + g[1] ** 2 + g[2] ** 2) ** 0.5
        phys.append("3d/default_gravity=%g" % mag)
        if mag > 0:
            # Unity → Godot (unidot convention mirrors X)
            phys.append("3d/default_gravity_vector=Vector3(%g, %g, %g)" % (-g[0] / mag, g[1] / mag, g[2] / mag))
    fixed = time_manager(read(os.path.join(src, "TimeManager.asset")))
    if fixed:
        phys.append("common/physics_ticks_per_second=%d" % round(1.0 / fixed))
    if phys:
        sections["physics"] = phys
    udon = []
    if matrix:
        udon.append("collision_matrix=PackedInt32Array(%s)" % ", ".join(str(v) for v in matrix))
    if tags:
        udon.append("tags=PackedStringArray(%s)" % ", ".join('"%s"' % t for t in tags))
    if udon:
        sections["udon"] = udon
    inputs = []
    for ax in input_manager(read(os.path.join(src, "InputManager.asset"))):
        if not ax["name"] or ax["type"] != "0":
            continue
        events = [e for e in (key_event(ax["pos"]), key_event(ax["altpos"])) if e]
        if events:
            inputs.append('%s={\n"deadzone": 0.5,\n"events": [%s]\n}' % (ax["name"], ", ".join(events)))
        neg = [e for e in (key_event(ax["neg"]), key_event(ax["altneg"])) if e]
        if neg:
            inputs.append('%s_negative={\n"deadzone": 0.5,\n"events": [%s]\n}' % (ax["name"], ", ".join(neg)))
    if inputs:
        sections["input"] = inputs

    for name, lines in sections.items():
        header = "[%s]" % name
        if header in text:
            # append missing keys to the existing section
            idx = text.index(header) + len(header)
            existing = text[idx:]
            add = [l for l in lines if l.split("=")[0] not in existing]
            text = text[:idx] + "\n\n" + "\n".join(add) + text[idx:]
        else:
            text = text.rstrip("\n") + "\n\n%s\n\n%s\n" % (header, "\n".join(lines))
    with open(project, "w", encoding="utf-8") as f:
        f.write(text)
    print("project settings: %s" % ", ".join("%s (%d)" % (k, len(v)) for k, v in sections.items()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
