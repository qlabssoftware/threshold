#!/bin/bash
# Builds build/Threshold-<version>.pkg (arm64). No sudo needed.
#
#   Scripts/build-pkg.sh
#   VERSION=1.2.3 SIGN_IDENTITY="Developer ID Application: …" \
#   INSTALLER_IDENTITY="Developer ID Installer: …" NOTARY_PROFILE=my-profile \
#     Scripts/build-pkg.sh
set -euo pipefail

cd "$(dirname "$0")/.."
PKG_ID="com.qlabs.threshold"
PACKAGING="Packaging"
# shellcheck source=lib/flatpkg.sh
source Scripts/lib/flatpkg.sh

swift build -c release --arch arm64 --product threshold
BIN="$(swift build -c release --arch arm64 --show-bin-path)/threshold"

if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$BIN"
fi

VERSION="${VERSION:-$("$BIN" version)}"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ROOT="$STAGE/root"
SCRIPTS="$STAGE/scripts"
APPDIR="$ROOT/Library/Application Support/Threshold"
mkdir -p "$APPDIR" "$ROOT/Library/LaunchDaemons" "$SCRIPTS"

# ditto without resource forks, extended attributes or quarantine: keeps ._ AppleDouble entries out of the payload.
DITTO=(ditto --norsrc --noextattr --noqtn)
"${DITTO[@]}" "$BIN" "$APPDIR/threshold"
"${DITTO[@]}" "$PACKAGING/com.qlabs.threshold.plist" "$ROOT/Library/LaunchDaemons/com.qlabs.threshold.plist"
"${DITTO[@]}" "$PACKAGING/postinstall" "$SCRIPTS/postinstall"
chmod 0755 "$APPDIR" "$APPDIR/threshold" "$SCRIPTS/postinstall"
chmod 0644 "$ROOT/Library/LaunchDaemons/com.qlabs.threshold.plist"

mkdir -p build
OUT="build/Threshold-${VERSION}.pkg"
UNSIGNED="$STAGE/Threshold-unsigned.pkg"

# Hand-assembled flat pkg (see Scripts/lib/flatpkg.sh for why pkgbuild is not used).
flatpkg_build "$ROOT" "$SCRIPTS" "$PKG_ID" "$VERSION" "$UNSIGNED"

rm -f "$OUT"
if [ -n "${INSTALLER_IDENTITY:-}" ]; then
    productsign --sign "$INSTALLER_IDENTITY" --timestamp "$UNSIGNED" "$OUT"
else
    cp "$UNSIGNED" "$OUT"
fi

if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$OUT" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$OUT"
fi

if pkgutil --payload-files "$OUT" | grep -q '/\._'; then
    echo "error: AppleDouble entries in payload" >&2
    exit 1
fi

echo "Built $OUT"
