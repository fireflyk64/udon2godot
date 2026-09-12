#!/usr/bin/env bash
# Convert a Unity/VRChat asset folder into a runnable Godot project:
#   scripts/import_world.sh <unity_assets_dir> <out_project_dir> [extra udon2godot args]
# Steps: convert every UdonSharp .cs with udon2godot (scripts + manifest), assemble the project
# from godot_world_template + addons (udon_runtime, godot_sandbox, unidot_importer), then run
# unidot_importer headless inside the Godot editor. Diagnostics land in <out>/udon_import_report.json,
# <out>/unidot_import.log and <out>/udon2godot_report.txt.
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=$(realpath "$1"); OUT=$(realpath -m "$2"); shift 2
GODOT="${GODOT:-tools/Godot_v4.6.3-stable_linux.x86_64}"
BIN=target/release/udon2godot
cargo build --release -q || exit 1
mkdir -p "$OUT/addons" "$OUT/converted"
cp -n godot_world_template/project.godot "$OUT/project.godot" 2>/dev/null || true
cp godot_world_template/world_runner.gd "$OUT/world_runner.gd"
mkdir -p "$OUT/scenarios" && cp godot_world_template/scenarios/*.gd "$OUT/scenarios/"
mkdir -p "$OUT/tests" && cp godot_world_template/tests/*.gd "$OUT/tests/"
rm -rf "$OUT/addons/udon_runtime" "$OUT/addons/unidot_importer"
cp -r runtime/addons/udon_runtime "$OUT/addons/"
cp -r refs/unidot_importer "$OUT/addons/unidot_importer"
rm -rf "$OUT/addons/unidot_importer/.git"
[ -d "$OUT/addons/godot_sandbox" ] || cp -r godot_project/addons/godot_sandbox "$OUT/addons/"
# 1. scripts
FILES=$(find "$SRC" -name "*.cs" -not -path "*/Editor/*" -not -path "*/editor/*")
"$BIN" --report --manifest "$OUT/converted/udon_manifest.json" -o "$OUT/converted" --res-prefix res://converted "$@" $FILES > "$OUT/udon2godot_report.txt" 2>&1
CONV=$?
grep -E "class\(es\)|== totals" "$OUT/udon2godot_report.txt"
if [ $CONV -ne 0 ]; then echo "udon2godot failed; see $OUT/udon2godot_report.txt"; grep "error:" "$OUT/udon2godot_report.txt" | head; fi
# 2. register the sandbox extension before the first editor launch (otherwise scripts that use
#    its classes fail to parse on that launch), import once, then run the unidot import
mkdir -p "$OUT/.godot"
[ -f "$OUT/.godot/extension_list.cfg" ] || echo "res://addons/godot_sandbox/bin/godot-riscv.gdextension" > "$OUT/.godot/extension_list.cfg"
"$GODOT" --headless --editor --path "$OUT" --quit > "$OUT/godot_first_import.log" 2>&1
timeout "${IMPORT_TIMEOUT:-3600}" "$GODOT" --headless --editor --path "$OUT" -- --unidot-import "$SRC" --unidot-text-scenes --unidot-text-resources --unidot-log "$OUT/unidot_import.log" > "$OUT/unidot_stdout.log" 2>&1
CODE=$?
# the editor's exit code is not reliable; the driver prints a completion line
if grep -q "^\[unidot headless\] import finished" "$OUT/unidot_stdout.log"; then CODE=0; else echo "unidot import did not finish (exit $CODE); see $OUT/unidot_stdout.log"; CODE=1; fi
# Unity project settings (layers, gravity, fixed timestep, input axes) when available
PS="${PROJECT_SETTINGS:-$SRC/../ProjectSettings}"
[ -d "$PS" ] && python3 scripts/unity_project_settings.py "$PS" "$OUT"
grep -E "^\[unidot headless\]|udon_integration:" "$OUT/unidot_stdout.log" | tail -5
python3 - "$OUT/udon_import_report.json" <<'PY'
import json, sys
try:
    r = json.load(open(sys.argv[1]))
except Exception as e:
    print("no udon import report:", e); sys.exit(0)
print("scripts attached: %d, ui nodes: %d, events wired: %d, components: %s" % (r["scripts_attached"], r["ui_nodes"], r["events_wired"], r["components"]))
print("unknown scripts: %d, missing proxies: %d, unresolved refs: %d, missing resources: %d, unsupported fields: %d" % (len(r["unknown_scripts"]), len(r["missing_proxies"]), len(r["unresolved_references"]), len(r["missing_resources"]), len(r["unsupported_fields"])))
PY
echo "run:  $GODOT --headless --path $OUT -s world_runner.gd -- --scene res://<scene>.tscn --frames 120 --debug-scripts --dump-refs"
echo "shot: $GODOT --display-driver x11 --rendering-method gl_compatibility --path $OUT -s world_runner.gd -- --scene res://<scene>.tscn --frame . --shot out.png"
echo "diag: scripts/world_doctor.py $OUT"
exit $CODE
