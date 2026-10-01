#!/usr/bin/env bash
# Unity UI import without any scripting: canvases, RectTransforms and layout groups.
#   scripts/test_ui.sh [out_dir]        (REIMPORT=1 forces a fresh import; UNIDOT=<checkout> tests
#                                        another checkout of unidot, e.g. its UI-only branch)
# 1. unit tests of unidot's runtime/rect_transform.gd (no importer involved)
# 2. tests/unity_ui (written by tools/gen_ui_fixture.py: every RectTransform case, every layout
#    group mode, nested and screen-space canvases, prefab overrides) is imported by unidot alone:
#    the project has no udon_runtime, no sandbox and no udon_integration plugin
# 3. the imported scene is run and every UI node's drawn world position, colour and text are
#    compared with what Unity shows (tools/unity_ui_reference.py, computed from the Unity files)
# 4. on a display: every canvas is rendered (PNG in <out>/shots) and the pixels are compared
#    with the transforms (test/ui_shots.gd --check)
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=${1:-/tmp/udon2godot_worlds/ui}
UNIDOT=${UNIDOT:-refs/unidot_importer}
. scripts/_godot_env.sh   # GODOT → scripts/godot.sh (memory and lifetime caps)
SCENE=unity_ui/UiCases/UiCases.tscn
CODE=0
python3 tools/gen_ui_fixture.py > /dev/null || exit 1
STALE=$(find tests/unity_ui "$UNIDOT" -name "*.gd" -newer "$OUT/$SCENE" -type f 2>/dev/null | head -1)
[ -z "$STALE" ] && STALE=$(find tests/unity_ui -newer "$OUT/$SCENE" -type f 2>/dev/null | head -1)
if [ ! -f "$OUT/$SCENE" ] || [ -n "$STALE" ] || [ "${REIMPORT:-0}" = 1 ]; then
  rm -rf "$OUT"
  mkdir -p "$OUT/addons"
  cat > "$OUT/project.godot" <<'PROJ'
config_version=5

[application]

config/name="unidot_ui_test"
config/features=PackedStringArray("4.7")

[editor_plugins]

enabled=PackedStringArray("res://addons/unidot_importer/plugin.cfg", "res://addons/unidot_importer/headless/plugin.cfg")

[rendering]

renderer/rendering_method="gl_compatibility"
renderer/rendering_method.mobile="gl_compatibility"
PROJ
  cp -r "$UNIDOT" "$OUT/addons/unidot_importer"
  rm -rf "$OUT/addons/unidot_importer/.git"
  # the command-line import driver is the fork's (a checkout without it borrows it)
  [ -d "$OUT/addons/unidot_importer/headless" ] || cp -r refs/unidot_importer/headless "$OUT/addons/unidot_importer/headless"
  "$GODOT" --headless --editor --path "$OUT" --quit > "$OUT/godot_first_import.log" 2>&1
  # an importer that does not compile would leave the import below waiting for its timeout
  if grep -q "Parse Error" "$OUT/godot_first_import.log"; then echo "UI IMPORT FAILED: the importer does not compile"; grep -m3 -A1 "Parse Error" "$OUT/godot_first_import.log" | cut -c1-240; exit 1; fi
  for ATTEMPT in 1 2 3; do
    timeout "${IMPORT_TIMEOUT:-1800}" "$GODOT" --headless --editor --path "$OUT" -- --unidot-import "$(realpath tests/unity_ui)" --unidot-text-scenes --unidot-text-resources --unidot-log "$OUT/unidot_import.log" > "$OUT/unidot_stdout.log" 2>&1
    if grep -q "^\[unidot headless\] import finished" "$OUT/unidot_stdout.log" || ! grep -q "Program crashed with signal" "$OUT/unidot_stdout.log"; then break; fi
    echo "godot crashed during the import (attempt $ATTEMPT); retrying"
  done
  grep -E "^\[unidot headless\]" "$OUT/unidot_stdout.log" | tail -2
  if ! grep -q "^\[unidot headless\] import finished" "$OUT/unidot_stdout.log"; then echo "UI IMPORT FAILED (see $OUT/unidot_stdout.log)"; exit 1; fi
  N=$(grep -c "^SCRIPT ERROR" "$OUT/unidot_stdout.log" || true)
  if [ "${N:-0}" -gt 0 ]; then echo "!! $N GDScript error(s) during the import: $(grep -m1 -A1 '^SCRIPT ERROR' "$OUT/unidot_stdout.log" | tr '\n' ' ' | cut -c1-200)"; CODE=1; fi
else
  rm -rf "$OUT/addons/unidot_importer/runtime" "$OUT/addons/unidot_importer/test"
  cp -r "$UNIDOT/runtime" "$UNIDOT/test" "$OUT/addons/unidot_importer/"
fi
echo "== rect_transform.gd unit tests"
timeout 300 "$GODOT" --headless --path "$OUT" -s addons/unidot_importer/test/rect_transform_test.gd > "$OUT/unit.log" 2>&1 || CODE=1
grep -E "FAIL |RECT TRANSFORM TESTS|rect_transform_test" "$OUT/unit.log"
grep -q "RECT TRANSFORM TESTS PASSED" "$OUT/unit.log" || CODE=1
echo "== imported UI against the Unity reference"
timeout 300 "$GODOT" --headless --path "$OUT" -s addons/unidot_importer/test/ui_dump_main.gd -- --scene "res://$SCENE" --out "$OUT/ui_dump.json" --frames 20 > "$OUT/dump.log" 2>&1 || CODE=1
grep -E "^\[ui_dump\]" "$OUT/dump.log"
python3 tools/unity_ui_reference.py tests/unity_ui tests/unity_ui/UiCases/UiCases.unity --compare "$OUT/ui_dump.json" --active > "$OUT/compare.log" 2>&1 || CODE=1
grep -c "MISMATCH" "$OUT/compare.log" | sed 's/^/mismatches: /'
head -${UI_SHOW:-40} "$OUT/compare.log" | cut -c1-260
tail -1 "$OUT/compare.log"
if [ -n "${DISPLAY:-}" ]; then
  # what is rendered against the transforms: every canvas to a PNG, and at the centre of every
  # solid graphic the pixel must show the control the transforms put on top there
  echo "== rendered canvases against the transforms (display $DISPLAY)"
  rm -rf "$OUT/shots"; mkdir -p "$OUT/shots"
  timeout 600 "$GODOT" --display-driver x11 --rendering-method gl_compatibility --rendering-driver opengl3 --resolution 1152x648 --path "$OUT" -s addons/unidot_importer/test/ui_shots.gd -- --scene "res://$SCENE" --out "$OUT/shots" --check 1 > "$OUT/shots.log" 2>&1 || CODE=1
  grep -E "MISDRAWN" "$OUT/shots.log" | head -${UI_SHOW:-40} | cut -c1-260
  grep -E "^\[ui_shots\]" "$OUT/shots.log" || { echo "the rendering run did not finish (see $OUT/shots.log)"; CODE=1; }
else
  echo "== no display: the rendering of the canvases is not checked"
fi
godot_guard_report "$OUT"/*.log
godot_script_errors "$OUT/unit.log" "$OUT/dump.log" || CODE=1
[ $CODE -eq 0 ] && echo "UI TESTS PASSED" || echo "UI TESTS FAILED"
exit $CODE
