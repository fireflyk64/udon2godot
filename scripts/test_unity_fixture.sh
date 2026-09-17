#!/usr/bin/env bash
# End-to-end fixture: import tests/unity_fixture through the world pipeline and run its scenario.
#   scripts/test_unity_fixture.sh [out_dir]   (REIMPORT=1 forces a fresh import)
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=${1:-/tmp/udon2godot_worlds/fixture}
. scripts/_godot_env.sh   # GODOT → scripts/godot.sh (memory and lifetime caps)
SCENE=res://unity_fixture/Fixture/Fixture.tscn
mkdir -p "$(dirname "$OUT")"   # the import log sits next to the world folder
# a world imported before the Unity sources or the importer changed is stale
# (converter sources count too: field values are set on the converted scripts during the import,
#  a script that did not compile then silently loses all of them)
STALE=$(find tests/unity_fixture refs/unidot_importer/*.gd src data/api -newer "$OUT/unity_fixture/Fixture/Fixture.tscn" -type f 2>/dev/null | head -1)
if [ ! -f "$OUT/unity_fixture/Fixture/Fixture.tscn" ] || [ -n "$STALE" ] || [ "${REIMPORT:-0}" = 1 ]; then
  [ -n "$STALE" ] && echo "re-importing: $STALE is newer than the imported scene"
  rm -rf "$OUT"
  scripts/import_world.sh tests/unity_fixture "$OUT" > "$OUT.import.log" 2>&1 || true
  grep -E "class\(es\)|import finished|did not finish|scripts attached" "$OUT.import.log"
else
  rm -rf "$OUT/addons/udon_runtime"; cp -r runtime/addons/udon_runtime "$OUT/addons/"
  cp godot_project/addons/godot_sandbox/bin/*.so "$OUT/addons/godot_sandbox/bin/" 2>/dev/null || true   # a rebuilt sandbox library
  cp godot_world_template/world_runner.gd "$OUT/"; cp godot_world_template/scenarios/*.gd "$OUT/scenarios/"
  cargo build --release -q && target/release/udon2godot -q --manifest "$OUT/converted/udon_manifest.json" -o "$OUT/converted" --res-prefix res://converted $(find tests/unity_fixture -name "*.cs")
fi
python3 scripts/world_doctor.py "$OUT" | sed -n '/Scene import/,/Custom shaders/p' | head -12
timeout 300 "$GODOT" --headless --path "$OUT" -s world_runner.gd -- --scene $SCENE --frames 5 --debug-scripts --dump-refs --scenario res://scenarios/fixture.gd > "$OUT/scenario.log" 2>&1
CODE=$?
grep -E "^\[scenario\]|^\[fixture\]|FAIL |SCENARIO|unbound" "$OUT/scenario.log"
echo "runtime errors: $(grep -c '^ERROR\|^SCRIPT ERROR' "$OUT/scenario.log")  (log: $OUT/scenario.log)"
if [ -n "${DISPLAY:-}" ]; then
  # on a display the scenario also samples the rendered UI canvas and clicks it through the window
  # (pointer raycast → SubViewport input); screenshots land in $OUT/shots
  echo "== UI rendering + window input (display $DISPLAY)"
  mkdir -p "$OUT/shots"
  timeout 300 "$GODOT" --display-driver x11 --rendering-method gl_compatibility --rendering-driver opengl3 --resolution 1152x648 --path "$OUT" -s world_runner.gd -- --scene $SCENE --frames 5 --scenario res://scenarios/fixture.gd --shot "$OUT/shots/fixture.png" > "$OUT/scenario_display.log" 2>&1
  DCODE=$?
  grep -E "^\[scenario\]|FAIL |SCENARIO" "$OUT/scenario_display.log"
  echo "runtime errors: $(grep -c '^ERROR\|^SCRIPT ERROR' "$OUT/scenario_display.log")  (log: $OUT/scenario_display.log)"
  [ $DCODE -ne 0 ] && CODE=$DCODE
  echo "== desktop player (walk, jump, tracking data, clicks through the player camera)"
  timeout 300 "$GODOT" --display-driver x11 --rendering-method gl_compatibility --rendering-driver opengl3 --resolution 1152x648 --path "$OUT" -s world_runner.gd -- --scene $SCENE --frames 5 --play --scenario res://scenarios/player.gd --shot "$OUT/shots/player.png" > "$OUT/scenario_player.log" 2>&1
  PCODE=$?
  grep -E "^\[scenario\]|FAIL |SCENARIO" "$OUT/scenario_player.log"
  echo "runtime errors: $(grep -c '^ERROR\|^SCRIPT ERROR' "$OUT/scenario_player.log")  (log: $OUT/scenario_player.log)"
  [ $PCODE -ne 0 ] && CODE=$PCODE
fi
echo "== VR player with simulated controllers (rays, trigger, stick, station)"
timeout 300 "$GODOT" --headless --path "$OUT" -s world_runner.gd -- --scene $SCENE --frames 5 --vr-sim --scenario res://scenarios/vr.gd > "$OUT/scenario_vr.log" 2>&1
VCODE=$?
grep -E "^\[scenario\]|FAIL |SCENARIO" "$OUT/scenario_vr.log"
echo "runtime errors: $(grep -c '^ERROR\|^SCRIPT ERROR' "$OUT/scenario_vr.log")  (log: $OUT/scenario_vr.log)"
[ $VCODE -ne 0 ] && CODE=$VCODE
godot_guard_report "$OUT"/*.log "$OUT.import.log"
godot_script_errors "$OUT/scenario.log" "$OUT/scenario_display.log" "$OUT/scenario_player.log" "$OUT/scenario_vr.log" || CODE=1
exit $CODE
