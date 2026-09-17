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

# name | unity assets folder | scene (res://) | scenario
world() {
  local name=$1 src=$2 scene=$3 scenario=$4 out="$WORLDS/$1"
  if [ -n "${ONLY:-}" ] && [ "$ONLY" != "$name" ]; then return 0; fi
  echo; echo "===== $name"
  if [ ! -d "$src" ]; then echo "skipped: $src is not cloned (scripts/setup_deps.sh --community)"; return 0; fi
  local tscn="$out/${scene#res://}"
  local stale=""
  [ -f "$tscn" ] && stale=$(find refs/unidot_importer -maxdepth 1 -name "*.gd" -newer "$tscn" -type f 2>/dev/null | head -1)
  if [ ! -f "$tscn" ] || [ -n "$stale" ] || [ "${REIMPORT:-0}" = 1 ]; then
    [ -n "$stale" ] && echo "re-importing: $stale is newer than the imported scene"
    rm -rf "$out"
    scripts/import_world.sh "$src" "$out" > "$out.import.log" 2>&1 || true
    grep -E "class\(es\)|import finished|did not finish|scripts attached|unknown scripts" "$out.import.log"
  else
    rm -rf "$out/addons/udon_runtime"; cp -r runtime/addons/udon_runtime "$out/addons/"
    cp godot_project/addons/godot_sandbox/bin/*.so "$out/addons/godot_sandbox/bin/" 2>/dev/null || true
    cp godot_world_template/world_runner.gd "$out/"; cp godot_world_template/scenarios/*.gd "$out/scenarios/"
    local files=()
    mapfile -d '' files < <(find "$src" -name "*.cs" -not -path "*/Editor/*" -not -path "*/editor/*" -print0)
    cargo build --release -q && target/release/udon2godot -q --manifest "$out/converted/udon_manifest.json" -o "$out/converted" --res-prefix res://converted "${files[@]}" > /dev/null 2>&1
  fi
  timeout 600 "$GODOT" --headless --path "$out" -s world_runner.gd -- --scene "$scene" --frames 5 --debug-scripts --scenario "$scenario" > "$out/scenario.log" 2>&1
  local code=$?
  grep -E "^\[scenario\] [0-9]|FAIL |SCENARIO" "$out/scenario.log"
  echo "runtime errors: $(grep -c '^ERROR\|^SCRIPT ERROR' "$out/scenario.log")  (log: $out/scenario.log)"
  if [ -n "${DISPLAY:-}" ] && [ "${SHOTS:-1}" = 1 ]; then
    mkdir -p "$out/shots"
    timeout 600 "$GODOT" --display-driver x11 --rendering-method gl_compatibility --rendering-driver opengl3 --resolution 1152x648 --path "$out" -s world_runner.gd -- --scene "$scene" --frames 5 --scenario "$scenario" --shot "$out/shots/$name.png" > "$out/scenario_display.log" 2>&1
    grep -E "^\[scenario\] [0-9]|FAIL |SCENARIO" "$out/scenario_display.log"
    echo "screenshots: $out/shots"
  fi
  godot_guard_report "$out"/*.log "$out.import.log"
  [ $code -ne 0 ] && FAILED+=("$name")
  return 0
}

world emychess refs/EmyChess/Packages/com.emymin.emychess/Runtime res://Runtime/ExampleScene.tscn res://scenarios/emychess.gd
# (unidot keeps paths relative to the Unity project: the folder above "Assets")
world udon_essentials "refs/UdonEssentials/Assets/Varneon/Udon Prefabs/Essentials" "res://Assets/Varneon/Udon Prefabs/Essentials/Examples/UdonEssentials_ExampleScene.tscn" res://scenarios/udon_essentials.gd

echo
if [ ${#FAILED[@]} -eq 0 ]; then echo "COMMUNITY WORLDS PASSED"; exit 0; fi
echo "COMMUNITY WORLDS FAILED: ${FAILED[*]}"; exit 1
