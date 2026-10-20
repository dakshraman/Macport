#!/bin/sh
# Embed MacportVMHost in Macport.app/Contents/MacOS.
#
# The host must be a sibling of the app binary: that is where VMHostLauncher
# looks, and it keeps the lookup closed (no PATH, no DerivedData). Xcode builds
# the tool as a dependency; this script only places it and gives it its own
# signature, because a hardened app will not execute an unsigned nested binary
# on a signed build.
#
# Called from the Macport target's post-compile phase:
#   embed-vm-host.sh <built-host> <app-contents-macos-dir> <entitlements>
set -eu

SOURCE_HOST="$1"
DESTINATION_DIR="$2"
ENTITLEMENTS="$3"

if [ ! -x "$SOURCE_HOST" ]; then
    echo "error: MacportVMHost was not built at $SOURCE_HOST" >&2
    exit 1
fi

/usr/bin/install -d "$DESTINATION_DIR"
DESTINATION_HOST="$DESTINATION_DIR/MacportVMHost"

if [ ! -f "$DESTINATION_HOST" ] || ! /usr/bin/cmp -s "$SOURCE_HOST" "$DESTINATION_HOST"; then
    /usr/bin/install -m 755 "$SOURCE_HOST" "$DESTINATION_HOST"
fi

# Unsigned builds (CODE_SIGNING_ALLOWED=NO) are for local development and CI;
# there is no identity to use and no hardened runtime to satisfy. A signed build
# signs the host with the same identity as the app before the app itself is
# sealed, so the nested binary is both runnable and covered by the app's seal.
if [ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ]; then
    IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
    if [ -z "$IDENTITY" ]; then
        IDENTITY="-"
    fi
    /usr/bin/codesign \
        --force \
        --sign "$IDENTITY" \
        --entitlements "$ENTITLEMENTS" \
        --options runtime \
        "$DESTINATION_HOST"
fi
