#!/usr/bin/env bash
# Convert the API-coverage fixtures (tests/coverage/*.cs) and execute them inside Godot.
#   GODOT=/path/to/godot scripts/coverage_test.sh [FixtureName ...]
set -uo pipefail
cd "$(dirname "$0")/.."
GODOT="${GODOT:-tools/Godot_v4.6.3-stable_linux.x86_64}"
PROJ=godot_project
BIN=target/release/udon2godot

cargo build --release -q
rm -rf "$PROJ/addons/udon_runtime"
cp -r runtime/addons/udon_runtime "$PROJ/addons/"
rm -rf "$PROJ/converted_coverage"
"$BIN" --report -o "$PROJ/converted_coverage" --res-prefix res://converted_coverage tests/coverage > /tmp/udon2godot_coverage_convert.log 2>&1
CONV=$?
grep -E "class\(es\)|== totals|unmapped:|unsupported:|stubbed" -A3 /tmp/udon2godot_coverage_convert.log | head -40
grep -E "error:" /tmp/udon2godot_coverage_convert.log | head -20
if [ $CONV -ne 0 ]; then echo "CONVERSION FAILED"; exit 1; fi

mkdir -p "$PROJ/.godot"
[ -f "$PROJ/.godot/extension_list.cfg" ] || echo "res://addons/godot_sandbox/bin/godot-riscv.gdextension" > "$PROJ/.godot/extension_list.cfg"
"$GODOT" --headless --path "$PROJ" --import >/dev/null 2>&1 || true
LOG=$(mktemp)
timeout 300 "$GODOT" --headless --path "$PROJ" -s coverage_runner.gd -- "$@" >"$LOG" 2>&1
CODE=$?
grep -E "^== |^   FAIL|COVERAGE DONE" "$LOG"
echo "runtime errors: $(grep -c '^ERROR\|^SCRIPT ERROR' "$LOG" || true) (log: $LOG)"
grep -E "^ERROR|^SCRIPT ERROR|Message:" "$LOG" | sort | uniq -c | sort -rn | head -15
exit $CODE
