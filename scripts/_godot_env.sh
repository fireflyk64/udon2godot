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
