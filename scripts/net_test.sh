#!/usr/bin/env bash
# Two-process multiplayer test: a host and a client Godot instance exercise UdonNetworkProvider.
#   GODOT=/path/to/godot scripts/net_test.sh [port]
set -uo pipefail
cd "$(dirname "$0")/.."
GODOT="${GODOT:-tools/Godot_v4.6.3-stable_linux.x86_64}"
PORT="${1:-27777}"
PROJ=godot_project
LOGS=$(mktemp -d)

rm -rf "$PROJ/addons/udon_runtime"
cp -r runtime/addons/udon_runtime "$PROJ/addons/"
# class_name registrations need a scan
mkdir -p "$PROJ/.godot"
[ -f "$PROJ/.godot/extension_list.cfg" ] || echo "res://addons/godot_sandbox/bin/godot-riscv.gdextension" > "$PROJ/.godot/extension_list.cfg"
"$GODOT" --headless --path "$PROJ" --import >/dev/null 2>&1 || true

timeout 120 "$GODOT" --headless --path "$PROJ" -s net_test.gd -- host "$PORT" >"$LOGS/host.log" 2>&1 &
HOST_PID=$!
sleep 3
timeout 90 "$GODOT" --headless --path "$PROJ" -s net_test.gd -- client "$PORT" >"$LOGS/client.log" 2>&1
CLIENT_EXIT=$?
wait $HOST_PID
HOST_EXIT=$?

echo "== host"; grep -E "^  (ok|FAIL)|NET DONE" "$LOGS/host.log"
echo "== client"; grep -E "^  (ok|FAIL)|NET DONE" "$LOGS/client.log"
echo "== errors (host/client): $(grep -c '^ERROR' "$LOGS/host.log" || true) / $(grep -c '^ERROR' "$LOGS/client.log" || true)"
grep -E "^ERROR|^SCRIPT ERROR" "$LOGS/host.log" "$LOGS/client.log" | sort | uniq -c | sort -rn | head -10
echo "logs: $LOGS"
if [ $HOST_EXIT -ne 0 ] || [ $CLIENT_EXIT -ne 0 ]; then
  echo "NET TEST FAILED (host exit $HOST_EXIT, client exit $CLIENT_EXIT)"; exit 1
fi
echo "NET TEST PASSED"
