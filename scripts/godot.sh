#!/usr/bin/env bash
# Launches the Godot editor binary under guard rails, so a runaway import or a forgotten instance
# cannot take the machine down:
#   * memory cap: the process is killed when its resident memory exceeds GODOT_MEM_MB (default
#     6144 MB, a watchdog polls /proc and says so), backed by a kernel-enforced address-space limit
#     of GODOT_VMEM_MB (default 8192 MB, `ulimit -v`; Godot reserves about 2.8 GB of address space
#     for 0.3 GB of resident memory, so this only stops a real runaway; 0 disables it);
#   * lifetime cap: killed after GODOT_MAX_SECONDS (default 3600; 0 = unlimited, for playing);
#   * TERM/INT/HUP are forwarded, so `timeout ... scripts/godot.sh ...` never orphans the engine.
# Every script in scripts/ starts Godot through this file; GODOT_BIN picks another binary.
# Exit code: Godot's own, 137 when killed by a cap. GODOT_MEM_REPORT=1 prints the peak at exit.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="${GODOT_BIN:-$HERE/../tools/Godot_v4.7.2-stable_linux.x86_64}"
LIMIT_MB="${GODOT_MEM_MB:-6144}"
VMEM_MB="${GODOT_VMEM_MB:-8192}"
MAX_S="${GODOT_MAX_SECONDS:-3600}"
if [ ! -x "$BIN" ]; then
  echo "godot.sh: no Godot binary at $BIN (run scripts/setup_deps.sh or set GODOT_BIN)" >&2
  exit 127
fi
if [ "$VMEM_MB" -gt 0 ]; then
  ulimit -v $((VMEM_MB * 1024)) 2>/dev/null || echo "godot.sh: could not set the address-space limit" >&2
fi
"$BIN" "$@" &
pid=$!
trap 'kill -TERM "$pid" 2>/dev/null' TERM INT HUP
(
  start=$(date +%s)
  peak=0
  while kill -0 "$pid" 2>/dev/null; do
    rss=$(awk '/^VmRSS:/ {print $2}' "/proc/$pid/status" 2>/dev/null)
    rss=${rss:-0}
    [ "$rss" -gt "$peak" ] && peak=$rss && echo "$peak" > "/tmp/godot_sh_peak.$pid"
    if [ "$rss" -gt $((LIMIT_MB * 1024)) ]; then
      echo "godot.sh: resident memory $((rss / 1024)) MB exceeds the ${LIMIT_MB} MB cap (GODOT_MEM_MB); killing Godot ($pid)" >&2
      kill -KILL "$pid" 2>/dev/null
      break
    fi
    if [ "$MAX_S" -gt 0 ] && [ $(( $(date +%s) - start )) -gt "$MAX_S" ]; then
      echo "godot.sh: running longer than ${MAX_S} s (GODOT_MAX_SECONDS); killing Godot ($pid)" >&2
      kill -KILL "$pid" 2>/dev/null
      break
    fi
    sleep 1
  done
) &
watch=$!
wait "$pid"
code=$?
kill "$watch" 2>/dev/null
wait "$watch" 2>/dev/null
if [ "${GODOT_MEM_REPORT:-0}" = 1 ] && [ -f "/tmp/godot_sh_peak.$pid" ]; then
  echo "godot.sh: peak resident memory $(( $(cat "/tmp/godot_sh_peak.$pid") / 1024 )) MB" >&2
fi
rm -f "/tmp/godot_sh_peak.$pid"
exit $code
