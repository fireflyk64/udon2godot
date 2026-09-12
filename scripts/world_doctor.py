#!/usr/bin/env python3
"""Diagnose an imported world project: what converted, what did not, and what to do about it.

    scripts/world_doctor.py <project_dir> [--json]

Reads the artefacts left by scripts/import_world.sh:
  udon2godot_report.txt     per-class API usage (unmapped / stubbed / unsupported members)
  udon_import_report.json   udon_integration plugin: unknown scripts, unresolved references, ...
  unidot_import.log         unidot_importer warnings and failures per asset
  *.tscn                    the imported scenes (which nodes carry converted scripts)
"""
import json
import os
import re
import sys
from collections import Counter, defaultdict


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def section(title):
    print()
    print("== " + title)


def conversion(project):
    txt = read(os.path.join(project, "udon2godot_report.txt"))
    out = {"classes": 0, "warnings": 0, "errors": 0, "unmapped": Counter(), "stubbed": Counter(), "stored": Counter(), "unsupported": Counter(), "warning_kinds": Counter(), "error_lines": []}
    m = re.search(r"(\d+) class\(es\), (\d+) warning\(s\), (\d+) error\(s\)", txt)
    if m:
        out["classes"], out["warnings"], out["errors"] = map(int, m.groups())
    mode = None
    for line in txt.splitlines():
        s = line.strip()
        if s.startswith("unmapped:"):
            mode = "unmapped"
        elif s.startswith("stubbed"):
            mode = "stubbed"
        elif s.startswith("stored"):
            mode = "stored"
        elif s.startswith("unsupported"):
            mode = "unsupported"
        elif s.startswith("==") or s.startswith("mapped API") or s.startswith("unresolved"):
            mode = None
        elif mode and re.match(r"^[\w.<>\[\]]+ x\d+", s):
            name, n = s.rsplit(" x", 1)
            out[mode][name] += int(n)
        if "warning:" in line:
            kind = re.sub(r"`[^`]*`", "`…`", line.split("warning:", 1)[1].strip())
            out["warning_kinds"][kind] += 1
        if "error:" in line and not line.startswith("error: cannot"):
            out["error_lines"].append(line.strip())
    return out


def import_report(project):
    txt = read(os.path.join(project, "udon_import_report.json"))
    if not txt:
        return None
    try:
        return json.loads(txt)
    except json.JSONDecodeError:
        return None


def unidot_log(project):
    txt = read(os.path.join(project, "unidot_import.log"))
    fails, warns = Counter(), Counter()
    per_asset = defaultdict(int)
    shaders = {}
    for line in txt.splitlines():
        asset, _, msg = line.partition(": ")
        m = re.search(r'custom shader "([^"]+)" has no Godot port \(expected (\S+) in', msg)
        if m:
            e = shaders.setdefault(m.group(1), {"file": m.group(2), "materials": set(), "approx": ""})
            e["materials"].add(asset.split(":")[0])
            a = re.search(r"StandardMaterial3D \((.*)\)", msg)
            if a:
                e["approx"] = a.group(1)
            continue
        kind = re.sub(r"\d+", "#", msg)[:110]
        if "FAIL" in msg[:40] or "fail" in msg[:20].lower():
            fails[kind] += 1
            per_asset[asset] += 1
        else:
            warns[kind] += 1
    return fails, warns, per_asset, shaders


def scenes(project):
    found = []
    for root, _dirs, files in os.walk(project):
        if "/.godot" in root or "/addons/" in root:
            continue
        for f in files:
            if f.endswith(".tscn"):
                p = os.path.join(root, f)
                t = read(p)
                nodes = t.count("\n[node ")
                scripts = len(re.findall(r'script = ExtResource\("', t))
                sgd = len(re.findall(r'\.sgd"', t))
                found.append((os.path.relpath(p, project), nodes, scripts, sgd))
    return sorted(found)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    project = sys.argv[1]
    as_json = "--json" in sys.argv
    conv = conversion(project)
    rep = import_report(project)
    fails, warns, per_asset, shaders = unidot_log(project)
    scn = scenes(project)
    if as_json:
        print(json.dumps({"conversion": {k: (dict(v) if isinstance(v, Counter) else v) for k, v in conv.items()}, "import": rep, "unidot_fails": dict(fails), "unidot_warnings": dict(warns), "shaders_without_ports": {k: {"file": v["file"], "materials": sorted(v["materials"]), "approximation": v["approx"]} for k, v in shaders.items()}, "scenes": scn}, indent=2))
        return 0

    print("World doctor: " + project)
    section("Script conversion (udon2godot)")
    print("  %d classes, %d warnings, %d errors" % (conv["classes"], conv["warnings"], conv["errors"]))
    for e in conv["error_lines"][:10]:
        print("  ERROR " + e)
    for kind, items in [("unmapped API members (not implemented; add a catalog mapping)", conv["unmapped"]), ("stubbed API members (no-ops; runtime behaviour may differ)", conv["stubbed"]), ("stored API members (values round-trip, no engine effect)", conv["stored"]), ("unsupported API members", conv["unsupported"])]:
        if items:
            print("  " + kind + ":")
            for name, n in items.most_common(15):
                print("    %5d  %s" % (n, name))
    if conv["warning_kinds"]:
        print("  warning kinds:")
        for k, n in conv["warning_kinds"].most_common(8):
            print("    %5d  %s" % (n, k))

    section("Scene import (unidot_importer + udon_integration)")
    if rep is None:
        print("  no udon_import_report.json: the headless import did not finish (see unidot_stdout.log)")
    else:
        print("  scripts attached: %d, UI nodes: %d, UI events wired: %d" % (rep.get("scripts_attached", 0), rep.get("ui_nodes", 0), rep.get("events_wired", 0)))
        comps = rep.get("components", {})
        if comps:
            print("  VRC components: " + ", ".join("%s x%d" % kv for kv in sorted(comps.items())))
        unknown = rep.get("unknown_scripts", {})
        if unknown:
            print("  unknown MonoBehaviour scripts (%d): not converted, not an SDK/UI component we recognise" % len(unknown))
            for guid, info in sorted(unknown.items(), key=lambda kv: -kv[1].get("count", 0))[:15]:
                print("    %s x%-4d %s fields=%s" % (guid, info.get("count", 0), info.get("script_path") or "(script not in package)", ",".join(info.get("fields", [])[:8])))
            print("    → if a field list looks like an UdonSharp class, add its .cs to the conversion; SDK components can be mapped with the project setting udon/component_guids")
        mp = rep.get("missing_proxies", [])
        if mp:
            print("  UdonBehaviours without their UdonSharp proxy component (%d): script attached by program name, fields keep defaults" % len(mp))
            for e in mp[:10]:
                print("    %s on node %s" % (e.get("class"), e.get("node")))
        ur = rep.get("unresolved_references", [])
        if ur:
            print("  unresolved references (%d): the referenced object was not imported or is outside the scene" % len(ur))
            for e in ur[:15]:
                print("    " + ", ".join("%s=%s" % kv for kv in e.items()))
        mr = rep.get("missing_resources", [])
        if mr:
            print("  missing resources (%d): asset not imported (unsupported type or outside the package)" % len(mr))
            for e in mr[:15]:
                print("    " + ", ".join("%s=%s" % kv for kv in e.items()))
        uf = rep.get("unsupported_fields", [])
        if uf:
            print("  fields kept as raw data (%d)" % len(uf))
            for e in uf[:10]:
                print("    " + ", ".join("%s=%s" % kv for kv in e.items()))

    section("Custom shaders")
    if not shaders:
        print("  every material uses a built-in shader or a ported one")
    else:
        print("  %d custom shader(s) approximated with StandardMaterial3D (add a port to unidot/shader_ports to render them faithfully):" % len(shaders))
        for name, e in sorted(shaders.items(), key=lambda kv: -len(kv[1]["materials"])):
            print("    %-40s %2d material(s)  %-45s %s" % (name, len(e["materials"]), e["file"], e["approx"]))

    section("Asset import (unidot_importer log)")
    if not fails and not warns:
        print("  no warnings or failures logged")
    for k, n in fails.most_common(15):
        print("  FAIL %5d  %s" % (n, k))
    for k, n in warns.most_common(10):
        print("  warn %5d  %s" % (n, k))
    if per_asset:
        print("  assets with failures:")
        for a, n in sorted(per_asset.items(), key=lambda kv: -kv[1])[:10]:
            print("    %5d  %s" % (n, a))

    section("Scenes")
    if not scn:
        print("  no .tscn files (import scenes as text with --unidot-text-scenes to inspect them)")
    for rel, nodes, scripts, sgd in scn[:40]:
        print("  %-60s %5d nodes, %3d scripted, %3d udon" % (rel, nodes, scripts, sgd))
    return 0


if __name__ == "__main__":
    sys.exit(main())
