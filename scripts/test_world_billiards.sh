#!/usr/bin/env bash
# End-to-end: import MS-VRCSA-Billiards (refs/MS-VRCSA-Billiards) into a world project, run the
# gameplay scenario headless, then render screenshots of the game on the X display.
#   scripts/test_world_billiards.sh [out_dir]   (set REIMPORT=1 to force a fresh import)
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=${1:-/tmp/udon2godot_worlds/billiards}
GODOT="${GODOT:-tools/Godot_v4.6.3-stable_linux.x86_64}"
SCENE=res://MS-VRCSA-Billiards/DefaultScene/MS-VRCSA_Scene.tscn
if [ ! -f "$OUT/MS-VRCSA-Billiards/DefaultScene/MS-VRCSA_Scene.tscn" ] || [ "${REIMPORT:-0}" = 1 ]; then
  rm -rf "$OUT"
  scripts/import_world.sh refs/MS-VRCSA-Billiards "$OUT" || true
else
  # refresh runtime, converted scripts and runner without a full asset import
  rm -rf "$OUT/addons/udon_runtime"; cp -r runtime/addons/udon_runtime "$OUT/addons/"
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
exit $CODE
