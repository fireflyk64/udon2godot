#!/usr/bin/env bash
# Build the converter, run its tests, convert the fixture and reference corpora, then run the
# Godot end-to-end harness and the sandbox compile check.
#
#   GODOT=/path/to/Godot_v4.6.3-stable_linux.x86_64 scripts/verify.sh
set -euo pipefail
cd "$(dirname "$0")/.."
GODOT="${GODOT:-tools/Godot_v4.6.3-stable_linux.x86_64}"

echo "== cargo build & test"
cargo build --release
cargo test --release -q

BIN=target/release/udon2godot
PROJ=godot_project

echo "== runtime → project"
rm -rf "$PROJ/addons/udon_runtime"
cp -r runtime/addons/udon_runtime "$PROJ/addons/"

echo "== convert fixture"
"$BIN" -q -o "$PROJ/converted" --res-prefix res://converted tests/fixtures/Counter.cs

if [ -d refs/vrcbce ] || [ -d refs/SaccFlightAndVehicles ]; then
  echo "== convert reference corpora"
  rm -rf "$PROJ/converted_corpus"
  "$BIN" -q -o "$PROJ/converted_corpus" --res-prefix res://converted_corpus \
    $( [ -d refs/vrcbce ] && echo refs/vrcbce/Packages/com.vrcbilliards.vrcbce/Runtime ) \
    $( [ -d refs/SaccFlightAndVehicles ] && echo refs/SaccFlightAndVehicles )
fi

if [ ! -x "$GODOT" ]; then
  echo "Godot binary not found at $GODOT; skipping Godot checks"
  exit 0
fi

if [ ! -f "$PROJ/.godot/extension_list.cfg" ]; then
  echo "== godot: first import (registers the sandbox extension and class_name scripts)"
  mkdir -p "$PROJ/.godot"
  echo "res://addons/godot_sandbox/bin/godot-riscv.gdextension" > "$PROJ/.godot/extension_list.cfg"
  "$GODOT" --headless --path "$PROJ" --import >/dev/null 2>&1 || true
fi

echo "== godot: end-to-end harness"
LOG=$(mktemp)
"$GODOT" --headless --path "$PROJ" -s e2e_counter.gd >"$LOG" 2>&1 || true
grep -E "^  (ok|FAIL)|E2E DONE" "$LOG"
if grep -q "FAIL" "$LOG" || ! grep -q "E2E DONE: 0 failure" "$LOG"; then
  echo "e2e FAILED (see $LOG)"; exit 1
fi
ERRS=$(grep -c "^ERROR" "$LOG" || true)
echo "runtime errors during e2e: $ERRS"

if [ -d "$PROJ/converted_corpus" ]; then
  echo "== godot: compile check of converted corpora"
  "$GODOT" --headless --path "$PROJ" -s compile_check.gd 2>&1 | grep -E "COMPILE" || true
fi
echo "== done"
