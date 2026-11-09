#!/bin/bash
# Sourced helper: assembles an unsigned flat pkg by hand (no pkgbuild, no sudo).
#
# pkgbuild would archive the build shell's com.apple.provenance xattr as ._ AppleDouble entries.
# bsdtar with --uid 0 --gid 0 --no-xattrs gives a clean, root-owned payload instead.
#
#   flatpkg_build ROOT_DIR SCRIPTS_DIR|"" IDENTIFIER VERSION OUT_PKG
#
# SCRIPTS_DIR may be empty. If it contains a `postinstall`, PackageInfo references it.
# Sets COPYFILE_DISABLE=1 for the calling shell.

export COPYFILE_DISABLE=1

flatpkg_build() {
    local root="$1" scripts="$2" pkg_id="$3" version="$4" out="$5"
    case "$out" in /*) ;; *) out="$PWD/$out" ;; esac
    local work expanded
    work="$(mktemp -d)"
    expanded="$work/expanded"
    mkdir -p "$expanded"

    find "$root" -type d -exec chmod 0755 {} +
    _flatpkg_tar_gz "$root" > "$expanded/Payload"
    # This mkbom has no -u/-g: build a bom from the tree, rewrite every owner to 0/0 (root:wheel), rebuild from the listing.
    mkbom "$root" "$work/user.bom"
    lsbom "$work/user.bom" | awk -F'\t' 'BEGIN{OFS="\t"} {$3="0/0"; print}' > "$work/bom.list"
    mkbom -i "$work/bom.list" "$expanded/Bom"

    local scripts_xml=""
    if [ -n "$scripts" ]; then
        _flatpkg_tar_gz "$scripts" > "$work/Scripts.cpio.gz"
        # pkgutil --flatten wants a Scripts *directory* (a pre-built file would be wrapped as ./Scripts) and would
        # record the invoking user as owner; flatten with a directory, then swap in the root-owned archive below.
        mkdir "$expanded/Scripts"
        cp -R "$scripts/." "$expanded/Scripts/"
        scripts_xml="    <scripts>"
        if [ -f "$scripts/postinstall" ]; then
            scripts_xml="$scripts_xml
        <postinstall file=\"./postinstall\"/>"
        fi
        scripts_xml="$scripts_xml
    </scripts>"
    fi

    local nfiles kbytes
    nfiles=$(find "$root" | wc -l | tr -d ' ')
    kbytes=$(du -sk "$root" | awk '{print $1}')
    {
        echo '<?xml version="1.0" encoding="utf-8"?>'
        echo "<pkg-info format-version=\"2\" identifier=\"$pkg_id\" version=\"$version\" install-location=\"/\" auth=\"root\">"
        echo "    <payload numberOfFiles=\"$nfiles\" installKBytes=\"$kbytes\"/>"
        [ -z "$scripts_xml" ] || echo "$scripts_xml"
        echo '</pkg-info>'
    } > "$expanded/PackageInfo"

    rm -f "$out"
    pkgutil --flatten "$expanded" "$out"
    if [ -n "$scripts" ]; then
        local repack="$work/repack"
        mkdir "$repack"
        (cd "$repack" && xar -xf "$out" && cp "$work/Scripts.cpio.gz" Scripts && rm -f "$out" \
            && xar --compression none -cf "$out" Bom PackageInfo Payload Scripts)
    fi
    rm -rf "$work"
}

_flatpkg_tar_gz() { (cd "$1" && tar --format cpio --uid 0 --gid 0 --no-xattrs --no-mac-metadata -cf - .) | gzip -c; }
