#!/usr/bin/env bash
# Community prefab worlds: import each example scene through the world pipeline and run its
# scenario (scripts/setup_deps.sh --community clones the repositories; what is missing is skipped).
#   scripts/test_world_community.sh [worlds_dir]      (REIMPORT=1 forces fresh imports, ONLY=<name> runs one,
#                                                       SHOTS=0 skips the display pass)
set -uo pipefail
cd "$(dirname "$0")/.."
WORLDS=${1:-/tmp/udon2godot_worlds}
. scripts/_godot_env.sh   # GODOT → scripts/godot.sh (memory and lifetime caps)
mkdir -p "$WORLDS"
FAILED=()

# name | unity assets folder | scene (res://) | scenario | extra world_runner arguments
world() {
  local name=$1 src=$2 scene=$3 scenario=$4 out="$WORLDS/$1"
  local extra=("${@:5}")
  if [ -n "${ONLY:-}" ] && [ "$ONLY" != "$name" ]; then return 0; fi
  echo; echo "===== $name"
  if [ ! -d "$src" ]; then echo "skipped: $src is not cloned (scripts/setup_deps.sh --community)"; return 0; fi
  local tscn="$out/${scene#res://}"
  local stale=""
  [ -f "$tscn" ] && stale=$(find refs/unidot_importer -maxdepth 1 -name "*.gd" -newer "$tscn" -type f 2>/dev/null | head -1)
  # ... or when the converter now describes the scripts differently: values are set through the manifest
  if [ -f "$tscn" ] && [ -z "$stale" ] && [ -f "$out/converted/udon_manifest.json" ]; then
    local cs=()
    mapfile -d '' cs < <(find "$src" -name "*.cs" -not -path "*/Editor/*" -not -path "*/editor/*" -print0)
    cargo build --release -q && target/release/udon2godot -q --check --manifest "$out/converted/udon_manifest.new.json" --res-prefix res://converted "${cs[@]}" > /dev/null 2>&1
    if [ -f "$out/converted/udon_manifest.new.json" ] && ! cmp -s "$out/converted/udon_manifest.json" "$out/converted/udon_manifest.new.json"; then stale="the converter's manifest"; fi
    rm -f "$out/converted/udon_manifest.new.json"
  fi
  if [ ! -f "$tscn" ] || [ -n "$stale" ] || [ "${REIMPORT:-0}" = 1 ]; then
    [ -n "$stale" ] && echo "re-importing: $stale is newer than the imported scene"
    rm -rf "$out"
    scripts/import_world.sh "$src" "$out" > "$out.import.log" 2>&1 || true
    grep -E "class\(es\)|import finished|did not finish|scripts attached|unknown scripts" "$out.import.log"
  else
    install_runtime "$out"
    cp godot_project/addons/godot_sandbox/bin/*.so "$out/addons/godot_sandbox/bin/" 2>/dev/null || true
    cp godot_world_template/world_runner.gd "$out/"; cp godot_world_template/scenarios/*.gd "$out/scenarios/"
    local files=()
    mapfile -d '' files < <(find "$src" -name "*.cs" -not -path "*/Editor/*" -not -path "*/editor/*" -print0)
    cargo build --release -q && target/release/udon2godot -q --manifest "$out/converted/udon_manifest.json" -o "$out/converted" --res-prefix res://converted "${files[@]}" > /dev/null 2>&1
  fi
  # the headless pass is a first visit: PlayerData kept with --player-data starts empty, the
  # display pass then comes back to what the first one stored
  rm -f "$out/player_data.dat"
  timeout 600 "$GODOT" --headless --path "$out" -s world_runner.gd -- --scene "$scene" --frames 5 --debug-scripts --scenario "$scenario" ${extra[@]+"${extra[@]}"} > "$out/scenario.log" 2>&1
  local code=$?
  grep -E "^\[scenario\] [0-9]|FAIL |SCENARIO" "$out/scenario.log"
  echo "runtime errors: $(grep -c '^ERROR\|^SCRIPT ERROR' "$out/scenario.log")  (log: $out/scenario.log)"
  # 148 sandboxes plus the GL driver do not fit the 8 GB address-space cap of scripts/godot.sh
  # (thread creation fails); the caps are not to be raised, so that world stays headless
  local headless_only=0
  case "$name" in udonutils_tests) headless_only=1 ;; esac
  if [ -n "${DISPLAY:-}" ] && [ "${SHOTS:-1}" = 1 ] && [ $headless_only = 0 ]; then
    mkdir -p "$out/shots"
    timeout 600 "$GODOT" --display-driver x11 --rendering-method gl_compatibility --rendering-driver opengl3 --resolution 1152x648 --path "$out" -s world_runner.gd -- --scene "$scene" --frames 5 --scenario "$scenario" --shot "$out/shots/$name.png" ${extra[@]+"${extra[@]}"} > "$out/scenario_display.log" 2>&1
    local dcode=$?
    grep -E "^\[scenario\] [0-9]|FAIL |SCENARIO" "$out/scenario_display.log"
    echo "screenshots: $out/shots"
    [ $dcode -ne 0 ] && code=$dcode
  fi
  godot_guard_report "$out"/*.log "$out.import.log"
  godot_script_errors "$out/scenario.log" "$out/scenario_display.log" || code=1
  [ $code -ne 0 ] && FAILED+=("$name")
  return 0
}

world emychess refs/EmyChess/Packages/com.emymin.emychess/Runtime res://Runtime/ExampleScene.tscn res://scenarios/emychess.gd
# (unidot keeps paths relative to the Unity project: the folder above "Assets")
# the package's own runtime tests, run by its TestController in the imported world
world udonutils_tests refs/UdonUtils/Packages/tlp.udonutils/Runtime "res://Runtime/Scenes/Examples/RuntimeTesting/RuntimeTestingExample.tscn" res://scenarios/udonutils_tests.gd --player-data "$WORLDS/udonutils_tests/player_data.dat"
# vrcbce (VRCBilliards Community Edition): one table prefab as the scene, played through its menu;
# --frame / --view put the display pass's camera over the cloth
world vrcbce refs/vrcbce/Packages/com.vrcbilliards.vrcbce "res://com.vrcbilliards.vrcbce/VRCBCE (M.O.O.N).prefab.tscn" res://scenarios/vrcbce.gd --shadows --frame "Core Table Code/Shadows" --view "0.15,0.8,-0.6" --dist 1.3 --fov 55
# ... played through the desktop player (the unlock object, the menu's canvas, the cue pickup,
# the top-down view and a shot by window input alone); a prefab has no ground: --floor
play() {
  local name=$1 scene=$2 scenario=$3 out="$WORLDS/$1"
  local extra=("${@:4}")
  if [ -n "${ONLY:-}" ] && [ "$ONLY" != "$name" ]; then return 0; fi
  [ -d "$out" ] && [ -n "${DISPLAY:-}" ] && [ "${SHOTS:-1}" = 1 ] || return 0
  rm -f "$out/player_data.dat"
  timeout 600 "$GODOT" --display-driver x11 --rendering-method gl_compatibility --rendering-driver opengl3 --resolution 1152x648 --path "$out" -s world_runner.gd -- --scene "$scene" --frames 5 --play --scenario "$scenario" --shot "$out/shots/${name}_play.png" ${extra[@]+"${extra[@]}"} > "$out/scenario_play.log" 2>&1
  local code=$?
  grep -E "^\[scenario\] [0-9]|FAIL |SCENARIO" "$out/scenario_play.log"
  godot_script_errors "$out/scenario_play.log" || code=1
  [ $code -ne 0 ] && FAILED+=("$name-play")
  return 0
}
play vrcbce "res://com.vrcbilliards.vrcbce/VRCBCE (M.O.O.N).prefab.tscn" res://scenarios/vrcbce_play.gd --floor 0 --shadows
# ... the package's sample scene: every table of it (three: the plain one, the fox one with its
# fur shaders, the one of the tournament) through its own menu, in the world already imported
scene() {
  local name=$1 tag=$2 scene=$3 scenario=$4 out="$WORLDS/$1"
  local extra=("${@:5}")
  if [ -n "${ONLY:-}" ] && [ "$ONLY" != "$name" ]; then return 0; fi
  [ -f "$out/${scene#res://}" ] || return 0
  rm -f "$out/player_data.dat"
  timeout 600 "$GODOT" --headless --path "$out" -s world_runner.gd -- --scene "$scene" --frames 5 --debug-scripts --scenario "$scenario" ${extra[@]+"${extra[@]}"} > "$out/scenario_$tag.log" 2>&1
  local code=$?
  grep -E "^\[scenario\] [0-9]|FAIL |SCENARIO" "$out/scenario_$tag.log"
  local logs=("$out/scenario_$tag.log")
  if [ -n "${DISPLAY:-}" ] && [ "${SHOTS:-1}" = 1 ]; then
    mkdir -p "$out/shots"
    timeout 600 "$GODOT" --display-driver x11 --rendering-method gl_compatibility --rendering-driver opengl3 --resolution 1152x648 --path "$out" -s world_runner.gd -- --scene "$scene" --frames 5 --scenario "$scenario" --shot "$out/shots/${name}_$tag.png" ${extra[@]+"${extra[@]}"} > "$out/scenario_${tag}_display.log" 2>&1
    local dcode=$?
    grep -E "^\[scenario\] [0-9]|FAIL |SCENARIO" "$out/scenario_${tag}_display.log"
    [ $dcode -ne 0 ] && code=$dcode
    logs+=("$out/scenario_${tag}_display.log")
  fi
  godot_script_errors "${logs[@]}" || code=1
  [ $code -ne 0 ] && FAILED+=("$name-$tag")
  return 0
}
scene vrcbce all "res://com.vrcbilliards.vrcbce/Samples~/Demo Scene/VRCBilliardsCE_All_Tables.tscn" res://scenarios/vrcbce_all.gd --shadows --frame "VRCBCE CottonFox (akalink)" --view "0.1,0.9,-0.5" --dist 0.75 --fov 55
# ... and the canvases of its three menu styles against what Unity computes from the prefabs
# (tools/unity_ui_reference.py), on a display also what is rendered against the transforms
ui_reference() {
  local name=$1 assets=$2 out="$WORLDS/$1"
  shift 2
  if [ -n "${ONLY:-}" ] && [ "$ONLY" != "$name" ]; then return 0; fi
  [ -d "$out" ] || return 0
  local code=0 unity scene tag
  for unity in "$@"; do
    scene="res://$(basename "$assets")/${unity#"$assets"/}.tscn"
    tag=$(basename "$unity" .prefab | tr -c 'A-Za-z0-9\n' '_')
    timeout 300 "$GODOT" --headless --path "$out" -s world_runner.gd -- --scene "$scene" --frames 5 --static --scenario res://scenarios/canvas_dump.gd --dump-out "$out/ui_dump_$tag.json" > "$out/ui_dump_$tag.log" 2>&1
    python3 tools/unity_ui_reference.py "$assets" "$unity" --compare "$out/ui_dump_$tag.json" > "$out/ui_compare_$tag.log" 2>/dev/null || code=1
    grep -E "MISMATCH" "$out/ui_compare_$tag.log" | head -10
    echo "$(basename "$unity"): $(tail -1 "$out/ui_compare_$tag.log")"
    grep -q ", 0 problem(s)" "$out/ui_compare_$tag.log" || code=1
    if [ -n "${DISPLAY:-}" ] && [ "${SHOTS:-1}" = 1 ]; then
      timeout 600 "$GODOT" --display-driver x11 --rendering-method gl_compatibility --rendering-driver opengl3 --resolution 1152x648 --path "$out" -s addons/unidot_importer/test/ui_shots.gd -- --scene "$scene" --out "$out/shots/canvases_$tag" --check 1 --static 1 --all 1 > "$out/ui_pixels_$tag.log" 2>&1 || code=1
      grep -E "MISDRAWN|pixel check" "$out/ui_pixels_$tag.log" | head -10
    fi
  done
  [ $code -ne 0 ] && FAILED+=("$name-ui")
  return 0
}
VRCBCE=refs/vrcbce/Packages/com.vrcbilliards.vrcbce
[ -d "$VRCBCE" ] && ui_reference vrcbce "$VRCBCE" "$VRCBCE/VRCBCE (M.O.O.N).prefab" "$VRCBCE/VRCBCE (esnya).prefab" "$VRCBCE/VRCBCE (akalink).prefab"
world udon_essentials "refs/UdonEssentials/Assets/Varneon/Udon Prefabs" "res://Assets/Varneon/Udon Prefabs/Essentials/Examples/UdonEssentials_ExampleScene.tscn" res://scenarios/udon_essentials.gd

echo
if [ ${#FAILED[@]} -eq 0 ]; then echo "COMMUNITY WORLDS PASSED"; exit 0; fi
echo "COMMUNITY WORLDS FAILED: ${FAILED[*]}"; exit 1
