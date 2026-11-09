#!/bin/bash
# Builds the Tart E2E fixture packages into E2E/build/ (no sudo needed):
#   dummy-1.0.pkg        installs /Applications/Threshold Dummy.app, version 1.0
#   dummy-2.0.pkg        same, version 2.0
#   dummy-hang-2.0.pkg   payload 2.0, postinstall sleeps 900 s then exits 0
#   dummy-fail-2.0.pkg   payload 1.0, postinstall exits 1 (install fails, version unchanged)
# Also writes build/checksums.txt ("<sha256>  <file>"). The packages are unsigned: configs use
# teamID UNSIGNED00 together with the THRESHOLD_ALLOW_UNSIGNED marker that vm.sh creates.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=Scripts/lib/flatpkg.sh
source Scripts/lib/flatpkg.sh

OUT="E2E/build"
mkdir -p "$OUT"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# make_pkg <name> <payload-version> <postinstall-body|"">
make_pkg() {
    local name="$1" version="$2" post="$3"
    local root="$STAGE/$name/root" scripts="" app
    app="$root/Applications/Threshold Dummy.app/Contents"
    mkdir -p "$app"
    cat > "$app/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.qlabs.threshold.dummy</string>
    <key>CFBundleName</key>
    <string>Threshold Dummy</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$version</string>
    <key>CFBundleVersion</key>
    <string>$version</string>
</dict>
</plist>
PLIST
    plutil -lint "$app/Info.plist" >/dev/null
    if [ -n "$post" ]; then
        scripts="$STAGE/$name/scripts"
        mkdir -p "$scripts"
        printf '#!/bin/sh\n%s\n' "$post" > "$scripts/postinstall"
        chmod 0755 "$scripts/postinstall"
    fi
    flatpkg_build "$root" "$scripts" "com.qlabs.threshold.e2e.dummy" "$version" "$OUT/$name.pkg"
    if pkgutil --payload-files "$OUT/$name.pkg" | grep -q '/\._'; then
        echo "error: AppleDouble entries in $name.pkg payload" >&2
        exit 1
    fi
}

make_pkg dummy-1.0 1.0 ""
make_pkg dummy-2.0 2.0 ""
make_pkg dummy-hang-2.0 2.0 $'sleep 900\nexit 0'
make_pkg dummy-fail-2.0 1.0 'exit 1'

(cd "$OUT" && shasum -a 256 dummy-1.0.pkg dummy-2.0.pkg dummy-hang-2.0.pkg dummy-fail-2.0.pkg > checksums.txt)
echo "Built fixtures in $OUT"
cat "$OUT/checksums.txt"
