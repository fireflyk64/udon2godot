#!/usr/bin/env bash
# End-to-end fixture: import tests/unity_fixture through the world pipeline and run its scenario.
#   scripts/test_unity_fixture.sh [out_dir]   (REIMPORT=1 forces a fresh import)
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=${1:-/tmp/udon2godot_worlds/fixture}
GODOT="${GODOT:-tools/Godot_v4.7.2-stable_linux.x86_64}"
SCENE=res://unity_fixture/Fixture/Fixture.tscn
mkdir -p "$(dirname "$OUT")"   # the import log sits next to the world folder
if [ ! -f "$OUT/unity_fixture/Fixture/Fixture.tscn" ] || [ "${REIMPORT:-0}" = 1 ]; then
  rm -rf "$OUT"
  scripts/import_world.sh tests/unity_fixture "$OUT" > "$OUT.import.log" 2>&1 || true
  grep -E "class\(es\)|import finished|did not finish|scripts attached" "$OUT.import.log"
else
  rm -rf "$OUT/addons/udon_runtime"; cp -r runtime/addons/udon_runtime "$OUT/addons/"
  cp godot_world_template/world_runner.gd "$OUT/"; cp godot_world_template/scenarios/*.gd "$OUT/scenarios/"
  cargo build --release -q && target/release/udon2godot -q --manifest "$OUT/converted/udon_manifest.json" -o "$OUT/converted" --res-prefix res://converted tests/unity_fixture/Fixture/Fixture.cs
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
exit $CODE
