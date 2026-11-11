#!/bin/bash
# Builds build/Threshold-<version>.pkg: a distribution package (arm64, macOS 14+). No sudo needed.
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
UNSIGNED="$STAGE/component/threshold.pkg"; mkdir -p "$STAGE/component"

# Hand-assembled flat pkg (see Scripts/lib/flatpkg.sh for why pkgbuild is not used).
flatpkg_build "$ROOT" "$SCRIPTS" "$PKG_ID" "$VERSION" "$UNSIGNED"

# Wrap the component in a distribution (product) package: Jamf PreStage enrollment only accepts
# signed distribution packages. The requirements stop installs on Intel or macOS < 14.
cat > "$STAGE/requirements.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>os</key><array><string>14.0</string></array>
    <key>arch</key><array><string>arm64</string></array>
</dict>
</plist>
PLIST

rm -f "$OUT"
SIGN_ARGS=()
if [ -n "${INSTALLER_IDENTITY:-}" ]; then
    SIGN_ARGS=(--sign "$INSTALLER_IDENTITY" --timestamp)
fi
DIST="$STAGE/Distribution.xml"
productbuild --synthesize --product "$STAGE/requirements.plist" --package "$UNSIGNED" "$DIST"
# Give the product a title (shown by Installer and in install logs).
sed -i '' 's|<installer-gui-script minSpecVersion="2">|&\
    <title>Threshold</title>|' "$DIST"
productbuild --distribution "$DIST" --package-path "$(dirname "$UNSIGNED")" \
    --identifier "$PKG_ID" --version "$VERSION" ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} "$OUT"

if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$OUT" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$OUT"
fi

if pkgutil --payload-files "$OUT" | grep -q '/\._'; then
    echo "error: AppleDouble entries in payload" >&2
    exit 1
fi

echo "Built $OUT"
