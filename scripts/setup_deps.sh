#!/usr/bin/env bash
# Fetch everything the scripts need that is not in git: the Godot editor binary, the godot-sandbox
# release binaries for the platforms whose libraries are not tracked here, and the reference
# repositories under refs/ (unidot_importer fork, converter corpora).
#
#   scripts/setup_deps.sh                  # Godot + sandbox binaries + refs/ (Linux x86_64)
#   scripts/setup_deps.sh --build-sandbox  # also clone the patched godot-sandbox source and rebuild
#                                          # the Linux library (needs cmake, ninja, a C++20 compiler)
#
# Already tracked in git: godot_project/addons/godot_sandbox/ with the customized plugin scripts,
# gdscript.elf and the source-built Linux x86_64 library (MAX_LEVEL = 16, see README).
# Safe to re-run: existing downloads, clones and binaries are kept.
set -euo pipefail
cd "$(dirname "$0")/.."

GODOT_VERSION=4.6.3-stable
GODOT_BIN=tools/Godot_v${GODOT_VERSION}_linux.x86_64
SANDBOX_RELEASE=v0.56   # the release gdscript.elf and the non-Linux libraries were taken from
SANDBOX_ADDON=godot_project/addons/godot_sandbox
SANDBOX_FORK=https://github.com/fireflyk64/godot-sandbox.git
SANDBOX_BRANCH=udon2godot

fetch() { # url dest
  [ -f "$2" ] && return 0
  echo "== download $1"
  curl -fL --progress-bar -o "$2.part" "$1" && mv "$2.part" "$2"
}

clone_at() { # dir url revision [git clone options]
  local dir=$1 url=$2 rev=$3; shift 3
  if [ -d "$dir/.git" ]; then echo "== $dir present"; return 0; fi
  echo "== clone $url -> $dir"
  git clone -q "$@" "$url" "$dir"
  git -C "$dir" checkout -q "$rev"
}

mkdir -p tools refs

echo "== godot editor"
if [ ! -x "$GODOT_BIN" ]; then
  fetch "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}/Godot_v${GODOT_VERSION}_linux.x86_64.zip" "$GODOT_BIN.zip"
  unzip -oq "$GODOT_BIN.zip" -d tools && chmod +x "$GODOT_BIN"
fi
echo "   $GODOT_BIN"

echo "== godot-sandbox ${SANDBOX_RELEASE} binaries for the other platforms"
fetch "https://github.com/libriscv/godot-sandbox/releases/download/${SANDBOX_RELEASE}/godot-sandbox.zip" "tools/godot-sandbox-${SANDBOX_RELEASE}.zip"
TMP=$(mktemp -d)
unzip -q "tools/godot-sandbox-${SANDBOX_RELEASE}.zip" -d "$TMP"
for f in "$TMP"/addons/godot_sandbox/bin/*; do                     # tracked files win
  [ -e "$SANDBOX_ADDON/bin/$(basename "$f")" ] || cp -r "$f" "$SANDBOX_ADDON/bin/"
done
rm -rf "$TMP"
echo "   $(find "$SANDBOX_ADDON/bin" -maxdepth 1 -name 'libgodot_riscv.*' | wc -l) libraries in $SANDBOX_ADDON/bin"

echo "== reference repositories (pinned to the revisions the README numbers were measured with)"
clone_at refs/unidot_importer https://github.com/fireflyk64/unidot_importer.git udon-integration --branch udon-integration
clone_at refs/MS-VRCSA-Billiards https://github.com/Sacchan-VRC/MS-VRCSA-Billiards.git 2a325d297be759130990bad999a5b2e2af82fac5
clone_at refs/vrcbce https://github.com/VRCBilliards/vrcbce 968d176077b5397b09538c94839540bd57623807
clone_at refs/SaccFlightAndVehicles https://github.com/Sacchan-VRC/SaccFlightAndVehicles 8578813e3627b39f2f564684e865be940c6947d3

if [ "${1:-}" = "--build-sandbox" ]; then
  echo "== patched godot-sandbox source (branch $SANDBOX_BRANCH) and Linux library rebuild"
  clone_at refs/godot-sandbox "$SANDBOX_FORK" "$SANDBOX_BRANCH" --branch "$SANDBOX_BRANCH" --recurse-submodules
  (cd refs/godot-sandbox && ./build.sh)
  cp refs/godot-sandbox/.build/libgodot-riscv.so "$SANDBOX_ADDON/bin/libgodot_riscv.linux.template_release.x86_64.so"
  echo "   $SANDBOX_ADDON/bin/libgodot_riscv.linux.template_release.x86_64.so rebuilt"
fi

if [ ! -f godot_project/.godot/extension_list.cfg ]; then
  echo "== first import of godot_project (registers the sandbox extension and class_name scripts)"
  mkdir -p godot_project/.godot
  echo "res://addons/godot_sandbox/bin/godot-riscv.gdextension" > godot_project/.godot/extension_list.cfg
  "$GODOT_BIN" --headless --path godot_project --import >/dev/null 2>&1 || true
fi

echo "== done: next run scripts/verify.sh (or scripts/ci.sh for everything)"
