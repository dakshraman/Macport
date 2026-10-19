#!/bin/bash
#
# Embed the managed QEMU runtime into a built Macport.app.
#
# Usage: vendor-runtime.sh <resources-folder>
#   e.g. "${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
#
# The runtime is a build input, not source: it lives in the user's managed
# Application Support directory (or MACPORT_QEMU_DIR) and this script copies it
# into Contents/Resources/Runtime/QEMU. It is deliberately tolerant of a missing
# runtime so a source-only clone still builds; the app then offers in-app
# installation, which is the documented first-run path.
#
# The copied binaries are already ad-hoc signed with the hypervisor entitlement
# by QEMURuntimeBundler. `rsync -a` preserves them. The script verifies the
# entitlement survived instead of re-signing blindly, because a silent loss of
# `com.apple.security.hypervisor` is a boot failure, not a cosmetic problem.

set -euo pipefail

DEST_RESOURCES="${1:-}"
if [ -z "$DEST_RESOURCES" ]; then
  echo "usage: vendor-runtime.sh <resources-folder>" >&2
  exit 64
fi

SOURCE="${MACPORT_QEMU_DIR:-$HOME/Library/Application Support/Macport/Runtime/QEMU}"
DEST="$DEST_RESOURCES/Runtime/QEMU"
STAMP="$DEST/.embedded-runtime-id"

if [ ! -x "$SOURCE/bin/qemu-system-aarch64" ]; then
  echo "note: no QEMU runtime at '$SOURCE'; skipping embed (the app can install one)."
  exit 0
fi

# Re-embed only when the source runtime actually changed. The stamp records the
# source binary's size and modification time; a rebuild with nothing new to copy
# is a no-op instead of a 167 MB duplicate.
SOURCE_ID="$(stat -f '%z-%m' "$SOURCE/bin/qemu-system-aarch64")"
if [ -f "$STAMP" ] && [ "$(cat "$STAMP" 2>/dev/null || true)" = "$SOURCE_ID" ]; then
  exit 0
fi

mkdir -p "$DEST"
rsync -a --delete "$SOURCE/" "$DEST/"

if ! codesign -d --entitlements - "$DEST/bin/qemu-system-aarch64" 2>/dev/null \
    | grep -q "com.apple.security.hypervisor"; then
  echo "error: embedded QEMU lost com.apple.security.hypervisor; refusing to ship it." >&2
  exit 1
fi

printf '%s' "$SOURCE_ID" > "$STAMP"
echo "embedded QEMU runtime ($(du -sh "$DEST" | cut -f1)) from '$SOURCE'"
