# Sourced by the scripts: every Godot launch goes through scripts/godot.sh (memory cap, lifetime
# cap, signal forwarding). GODOT=/path/to/binary still selects the engine binary.
case "$(basename "${GODOT:-godot.sh}")" in
  godot.sh) : ;;
  *) GODOT_BIN="$(realpath "$GODOT")"; export GODOT_BIN ;;
esac
GODOT="scripts/godot.sh"

# Print the launcher's messages found in log files (a memory or lifetime cap that fired).
godot_guard_report() {
  grep -h "^godot.sh:" "$@" 2>/dev/null | sed 's/^/!! /' || true
}

# A GDScript error inside a scenario (or the runner) aborts that function while the run goes on
# and may still print "SCENARIO PASSED": count such lines so the caller can fail the run.
#   godot_script_errors <log>...   → prints a note and returns 1 when any log has script errors
godot_script_errors() {
  local total=0 f n
  for f in "$@"; do
    [ -f "$f" ] || continue
    n=$(grep -c '^SCRIPT ERROR' "$f" 2>/dev/null || true)
    if [ "${n:-0}" -gt 0 ]; then
      echo "!! $n GDScript error(s) in $f: $(grep -m1 '^SCRIPT ERROR' "$f" | cut -c1-160)"
      total=$((total + n))
    fi
  done
  [ "$total" -eq 0 ]
}
