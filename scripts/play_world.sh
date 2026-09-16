#!/usr/bin/env bash
# Play an imported world with mouse and keyboard:
#   scripts/play_world.sh <world_dir> [res://path/to/scene.tscn]
# WASD / arrows move, Shift runs, Space jumps, the mouse looks; click = use / grab, right click or
# G = drop, Esc / Tab frees the mouse to click canvases. Without a scene the largest non-prefab
# .tscn of the world is used. RENDER=forward_plus picks the renderer (default gl_compatibility).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=$(realpath "$1")
GODOT="${GODOT:-tools/Godot_v4.6.3-stable_linux.x86_64}"
SCENE="${2:-}"
if [ -z "$SCENE" ]; then
  REL=$(cd "$OUT" && find . -name "*.tscn" -not -name "*.prefab.tscn" -not -path "./addons/*" -printf "%s %p\n" | sort -rn | head -1 | cut -d' ' -f2- | sed 's|^\./||')
  [ -n "$REL" ] || { echo "no scene found in $OUT"; exit 1; }
  SCENE="res://$REL"
fi
echo "playing $SCENE"
exec "$GODOT" --rendering-method "${RENDER:-gl_compatibility}" --path "$OUT" -s world_runner.gd -- --scene "$SCENE" --play --debug-scripts "${@:3}"
