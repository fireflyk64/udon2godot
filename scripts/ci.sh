#!/usr/bin/env bash
# Every check, sequentially (Godot instances must not overlap on small containers):
#   scripts/ci.sh [worlds_dir]
# 1. cargo tests, corpus conversion, e2e lifecycle, compile check        (scripts/verify.sh)
#    + catalog audit: no unmapped extern, no unmapped overload         (udon2godot --coverage-overloads)
# 2. API coverage fixtures                                                (scripts/coverage_test.sh)
# 3. host + client over ENet                                              (scripts/net_test.sh)
# 4. Unity fixture scene through unidot + udon_integration                (scripts/test_unity_fixture.sh)
# 5. MS-VRCSA-Billiards import + gameplay scenario (+ screenshots on X)   (scripts/test_world_billiards.sh)
set -uo pipefail
cd "$(dirname "$0")/.."
WORLDS=${1:-/tmp/udon2godot_worlds}
FAILED=()
run() { local name=$1; shift; echo; echo "===== $name"; "$@" || FAILED+=("$name"); }
run verify scripts/verify.sh
# every Udon extern has a mapping, by member name and by argument list
catalog_audit() {
  local out; out=$(target/release/udon2godot --catalog-coverage --coverage-overloads 2>&1 | grep -E "^coverage:|^overload gaps:")
  echo "$out"
  echo "$out" | grep -q "; 0 unmapped" && echo "$out" | grep -q "^overload gaps: 0 "
}
run catalog-audit catalog_audit
# differential parser test against tree-sitter-c-sharp (optional: pip install tree-sitter tree-sitter-c-sharp;
# PARSER_DIFF_PYTHON picks the interpreter that has them)
PDP="${PARSER_DIFF_PYTHON:-python3}"
if "$PDP" -c "import tree_sitter_c_sharp" 2>/dev/null; then
  run parser-diff "$PDP" tools/parser_diff.py tests $(ls -d refs/MS-VRCSA-Billiards refs/vrcbce refs/SaccFlightAndVehicles 2>/dev/null)
else
  echo; echo "===== parser-diff skipped (tree-sitter-c-sharp is not installed for $PDP)"
fi
run coverage scripts/coverage_test.sh
run net scripts/net_test.sh
run fixture env REIMPORT=1 scripts/test_unity_fixture.sh "$WORLDS/fixture"
run billiards env REIMPORT=1 scripts/test_world_billiards.sh "$WORLDS/billiards"
echo
if [ ${#FAILED[@]} -eq 0 ]; then echo "CI PASSED"; exit 0; fi
echo "CI FAILED: ${FAILED[*]}"; exit 1
