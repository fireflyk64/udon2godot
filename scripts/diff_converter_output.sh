#!/usr/bin/env bash
# Convert the reference repositories with the last committed converter and with the working
# tree, and show which generated lines differ. Catalog and lowering changes that no suite
# exercises show up here (a bare `type ParticleSystem` block once turned typed fields into
# Variant without failing a single check).
#   scripts/diff_converter_output.sh [ref ...]      (default: every directory under refs/ with .cs files)
set -uo pipefail
cd "$(dirname "$0")/.."
WORK=${DIFF_WORK:-/tmp/udon2godot_outdiff}
REV=${DIFF_REV:-HEAD}
mkdir -p "$WORK"
if [ ! -d "$WORK/wt/.git" ] && [ ! -f "$WORK/wt/.git" ]; then
  git worktree add -q --detach "$WORK/wt" "$REV" || exit 1
else
  git -C "$WORK/wt" checkout -q --detach "$(git rev-parse "$REV")" || exit 1
fi
(cd "$WORK/wt" && CARGO_TARGET_DIR="$WORK/target" cargo build --release -q) || exit 1
cargo build --release -q || exit 1
REFS=("$@")
if [ ${#REFS[@]} -eq 0 ]; then
  for d in refs/*/; do
    n=$(basename "$d")
    case "$n" in godot-sandbox|unidot_importer|udon_flat|udonweft) continue ;; esac
    REFS+=("$n")
  done
fi
TOTAL=0
for r in "${REFS[@]}"; do
  [ -d "refs/$r" ] || { echo "$r: not cloned"; continue; }
  rm -rf "$WORK/old/$r" "$WORK/new/$r"
  "$WORK/target/release/udon2godot" -q -o "$WORK/old/$r" "refs/$r" > /dev/null 2>&1
  target/release/udon2godot -q -o "$WORK/new/$r" "refs/$r" > /dev/null 2>&1
  N=$(diff -r "$WORK/old/$r" "$WORK/new/$r" | grep -c '^[<>]')
  TOTAL=$((TOTAL + N))
  echo "$r: $N changed line(s)"
  [ "$N" -gt 0 ] && diff -r "$WORK/old/$r" "$WORK/new/$r" | grep '^[<>]' | sed -E 's/^([<>])[[:space:]]+/\1 /' | cut -c1-200 | head -${DIFF_LINES:-40}
done
echo "total: $TOTAL changed line(s) against $(git rev-parse --short "$REV")"
