#!/usr/bin/env bash
# End-to-end: import MS-VRCSA-Billiards (refs/MS-VRCSA-Billiards) into a world project, run the
# gameplay scenario headless, then render screenshots of the game on the X display.
#   scripts/test_world_billiards.sh [out_dir]   (set REIMPORT=1 to force a fresh import)
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=${1:-/tmp/udon2godot_worlds/billiards}
. scripts/_godot_env.sh   # GODOT → scripts/godot.sh (memory and lifetime caps)
SCENE=res://MS-VRCSA-Billiards/DefaultScene/MS-VRCSA_Scene.tscn
# a world imported before the importer changed is stale
STALE=$(find refs/unidot_importer -maxdepth 1 -name "*.gd" -newer "$OUT/MS-VRCSA-Billiards/DefaultScene/MS-VRCSA_Scene.tscn" -type f 2>/dev/null | head -1)
# ... or when the converter now describes the scripts differently (fields, types, exported flags):
# the import sets serialized values through that manifest
if [ -z "$STALE" ] && [ -f "$OUT/converted/udon_manifest.json" ]; then
  cargo build --release -q && target/release/udon2godot -q --check --manifest "$OUT/converted/udon_manifest.new.json" --res-prefix res://converted $(find refs/MS-VRCSA-Billiards -name "*.cs" -not -path "*/Editor/*") > /dev/null 2>&1
  if [ -f "$OUT/converted/udon_manifest.new.json" ] && ! cmp -s "$OUT/converted/udon_manifest.json" "$OUT/converted/udon_manifest.new.json"; then STALE="the converter's manifest"; fi
  rm -f "$OUT/converted/udon_manifest.new.json"
fi
if [ ! -f "$OUT/MS-VRCSA-Billiards/DefaultScene/MS-VRCSA_Scene.tscn" ] || [ -n "$STALE" ] || [ "${REIMPORT:-0}" = 1 ]; then
  [ -n "$STALE" ] && echo "re-importing: $STALE is newer than the imported scene"
  rm -rf "$OUT"
  scripts/import_world.sh refs/MS-VRCSA-Billiards "$OUT" || true
else
  # refresh runtime, converted scripts and runner without a full asset import
  rm -rf "$OUT/addons/udon_runtime"; cp -r runtime/addons/udon_runtime "$OUT/addons/"
  cp godot_project/addons/godot_sandbox/bin/*.so "$OUT/addons/godot_sandbox/bin/" 2>/dev/null || true   # a rebuilt sandbox library
  cp godot_world_template/world_runner.gd "$OUT/"; mkdir -p "$OUT/scenarios"; cp godot_world_template/scenarios/*.gd "$OUT/scenarios/"
  mkdir -p "$OUT/tests"; cp godot_world_template/tests/*.gd "$OUT/tests/"
  cargo build --release -q && target/release/udon2godot -q --manifest "$OUT/converted/udon_manifest.json" -o "$OUT/converted" --res-prefix res://converted $(find refs/MS-VRCSA-Billiards -name "*.cs" -not -path "*/Editor/*")
fi
python3 scripts/world_doctor.py "$OUT" | sed -n '1,40p'
echo "== scenario (headless)"
timeout 600 "$GODOT" --headless --path "$OUT" -s world_runner.gd -- --scene $SCENE --frames 10 --debug-scripts --scenario res://scenarios/billiards.gd > "$OUT/scenario.log" 2>&1
CODE=$?
grep -E "^\[scenario\]|FAIL |SCENARIO" "$OUT/scenario.log"
echo "runtime errors: $(grep -c '^ERROR\|^SCRIPT ERROR' "$OUT/scenario.log")  (log: $OUT/scenario.log)"
if [ -n "${DISPLAY:-}" ]; then
  echo "== screenshots"
  mkdir -p "$OUT/shots"
  # software GL renders about one frame per second with shadows; keep the resolution modest
  timeout 1500 "$GODOT" --display-driver x11 --rendering-method gl_compatibility --rendering-driver opengl3 --resolution 1152x648 --path "$OUT" -s world_runner.gd -- --scene $SCENE --frames 10 --shadows --frame MS-VRCSA_Table/BilliardsModule/intl_table --view "0.8,0.42,-0.55" --dist 1.15 --fov 55 --shot "$OUT/shots/billiards.png" --scenario res://scenarios/billiards.gd > "$OUT/shots.log" 2>&1
  ls "$OUT/shots"
  if [ ! -f "$OUT/shots/billiards_settled.png" ] || [ "$OUT/shots/billiards_settled.png" -ot "$OUT/scenario.log" ]; then
    echo "SCREENSHOTS FAILED (see $OUT/shots.log)"; tail -3 "$OUT/shots.log"; CODE=1
  fi
fi
# interactive: the desktop player plays through window input only (START button, lobby canvas, cue
# pickup, E, aim and shoot). Input needs no rendering, so this runs headless; PLAY_SHOTS=1 runs it on
# the display at a small resolution and keeps screenshots of each step in $OUT/shots.
echo "== interactive (desktop player: START button, lobby canvas, cue pickup, aim and shoot)"
if [ -n "${DISPLAY:-}" ] && [ "${PLAY_SHOTS:-0}" = 1 ]; then
  timeout 1500 "$GODOT" --display-driver x11 --rendering-method gl_compatibility --rendering-driver opengl3 --resolution 640x360 --path "$OUT" -s world_runner.gd -- --scene $SCENE --frames 5 --play --debug-scripts --scenario res://scenarios/billiards_play.gd --shot "$OUT/shots/play.png" > "$OUT/play.log" 2>&1
else
  timeout 600 "$GODOT" --headless --path "$OUT" -s world_runner.gd -- --scene $SCENE --frames 5 --play --pointer --debug-scripts --scenario res://scenarios/billiards_play.gd > "$OUT/play.log" 2>&1
fi
PCODE=$?
grep -E "^\[scenario\]|FAIL |SCENARIO" "$OUT/play.log"
echo "runtime errors: $(grep -c '^ERROR\|^SCRIPT ERROR' "$OUT/play.log")  (log: $OUT/play.log)"
[ $PCODE -ne 0 ] && CODE=$PCODE
godot_guard_report "$OUT"/*.log
godot_script_errors "$OUT/scenario.log" "$OUT/play.log" || CODE=1
exit $CODE
