#!/usr/bin/env bash
# Every check, sequentially (Godot instances must not overlap on small containers):
#   scripts/ci.sh [worlds_dir]
# 1. cargo tests, corpus conversion, e2e lifecycle, compile check        (scripts/verify.sh)
# 2. API coverage fixtures                                                (scripts/coverage_test.sh)
# 3. host + client over ENet                                              (scripts/net_test.sh)
# 4. Unity fixture scene through unidot + udon_integration                (scripts/test_unity_fixture.sh)
# 5. MS-VRCSA-Billiards import + gameplay scenario (+ screenshots on X)   (scripts/test_world_billiards.sh)
set -uo pipefail
cd "$(dirname "$0")/.."
WORLDS=${1:-/tmp/udon2godot_worlds}
FAILED=()
run() { echo; echo "===== $1"; shift; "$@" || FAILED+=("$1"); }
run verify scripts/verify.sh
run coverage scripts/coverage_test.sh
run net scripts/net_test.sh
run fixture env REIMPORT=1 scripts/test_unity_fixture.sh "$WORLDS/fixture"
run billiards env REIMPORT=1 scripts/test_world_billiards.sh "$WORLDS/billiards"
echo
if [ ${#FAILED[@]} -eq 0 ]; then echo "CI PASSED"; exit 0; fi
echo "CI FAILED: ${FAILED[*]}"; exit 1
