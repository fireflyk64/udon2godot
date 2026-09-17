#!/usr/bin/env bash
# Convert every reference repository under refs/ and load each generated script in the sandbox:
# "does everything the converter emits for real-world code compile as SafeGDScript".
# (verify.sh checks vrcbce and SaccFlight; this adds the pool table and the community prefabs.)
#   scripts/compile_check_refs.sh [ref ...]
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/_godot_env.sh   # GODOT → scripts/godot.sh (memory and lifetime caps)
PROJ=godot_project
BIN=target/release/udon2godot
cargo build --release -q || exit 1
REFS=("$@")
if [ ${#REFS[@]} -eq 0 ]; then
  for d in refs/*/; do
    n=$(basename "$d")
    case "$n" in godot-sandbox|unidot_importer|udon_flat|udonweft|vrcbce|SaccFlightAndVehicles) continue ;; esac
    REFS+=("$n")
  done
fi
rm -rf "$PROJ/converted_refs"
DIRS=()
for r in "${REFS[@]}"; do
  [ -d "refs/$r" ] || { echo "$r: not cloned"; continue; }
  safe=$(echo "$r" | tr -c 'A-Za-z0-9_\n' '_')
  "$BIN" -q -o "$PROJ/converted_refs/$safe" --res-prefix "res://converted_refs/$safe" "refs/$r" > /dev/null 2>&1
  DIRS+=("res://converted_refs/$safe")
done
[ ${#DIRS[@]} -eq 0 ] && { echo "nothing to check"; exit 0; }
LOG=$(mktemp)
timeout 3000 "$GODOT" --headless --path "$PROJ" -s compile_check.gd -- "${DIRS[@]}" > "$LOG" 2>&1
CODE=$?
grep -E "COMPILE FAILED|COMPILE CHECK" "$LOG"
# the compiler's message for each failed script
grep -E "^ERROR: SafeGDScript: " "$LOG" | sort -u | cut -c1-220 | head -40
godot_guard_report "$LOG"
echo "(log: $LOG)"
rm -rf "$PROJ/converted_refs"
grep -qE "COMPILE CHECK: [0-9]+ ok, 0 failed" "$LOG" || exit 1
exit $CODE
