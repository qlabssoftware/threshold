#!/bin/bash
# Manages the Tart VM used by the Threshold end-to-end scenarios.
#
#   vm.sh up        clone (if absent), boot, install swiftDialog + fixtures + mock jamf + dummy 1.0 + Threshold
#   vm.sh start     boot the VM if it is not running (used by scenarios.sh after a VM stop)
#   vm.sh down      stop the VM
#   vm.sh destroy   stop and delete the VM
#
# Guest access is `tart exec` (Tart guest agent, runs as the admin user; passwordless sudo).
# Run Scripts/build-pkg.sh and E2E/make-fixtures.sh first.
set -euo pipefail

cd "$(dirname "$0")/.."
VM="${THRESHOLD_E2E_VM:-threshold-e2e}"
IMAGE="ghcr.io/cirruslabs/macos-tahoe-base:latest"
BUILD="E2E/build"
GUEST_FIXTURES="/Library/Threshold-E2E"
LOG="${TMPDIR:-/tmp}/threshold-e2e-tart-run.log"

g() { tart exec "$VM" "$@"; }

# Copies a host file into the guest as root: vm_put <host-file> <guest-path> <mode>
vm_put() {
    tart exec -i "$VM" sudo /bin/sh -c "cat > '$2' && chown root:wheel '$2' && chmod $3 '$2'" < "$1"
}

vm_exists() { tart list --quiet 2>/dev/null | grep -qx "$VM"; }
vm_running() { tart list 2>/dev/null | awk -v vm="$VM" '$2 == vm && $NF == "running" {found=1} END{exit !found}'; }
vm_reachable() { tart exec "$VM" true >/dev/null 2>&1; }

wait_reachable() {
    local timeout="${1:-300}" waited=0
    until vm_reachable; do
        sleep 3; waited=$((waited + 3))
        if [ "$waited" -ge "$timeout" ]; then echo "error: $VM not reachable after ${timeout}s" >&2; return 1; fi
    done
}

# A guest reboot (shutdown -r) keeps `tart run` alive: the VM is the same host process, only macOS restarts.
# If the VM did stop (host process exited), start it again headless in the background.
start_vm() {
    if vm_running; then return 0; fi
    echo "Starting $VM"
    nohup tart run --no-graphics "$VM" > "$LOG" 2>&1 &
    disown
}

latest_dialog_pkg() {
    # Cached in build/; the newest release's .pkg asset is resolved through the GitHub API.
    local cached
    cached="$(ls "$BUILD"/dialog-*.pkg 2>/dev/null | head -1 || true)"
    if [ -n "$cached" ]; then echo "$cached"; return; fi
    local json url name
    json="$(curl -fsSL https://api.github.com/repos/swiftDialog/swiftDialog/releases/latest)"
    url="$(echo "$json" | jq -r '[.assets[] | select(.name | endswith(".pkg"))][0].browser_download_url')"
    name="$(basename "$url")"
    [ -n "$url" ] && [ "$url" != null ] || { echo "error: no .pkg asset in latest swiftDialog release" >&2; exit 1; }
    curl -fsSL -o "$BUILD/$name" "$url"
    echo "$BUILD/$name"
}

cmd_up() {
    for f in dummy-1.0.pkg dummy-2.0.pkg dummy-hang-2.0.pkg dummy-fail-2.0.pkg; do
        [ -f "$BUILD/$f" ] || { echo "error: missing $BUILD/$f (run make-fixtures.sh)" >&2; exit 1; }
    done
    local threshold_pkg
    threshold_pkg="$(ls -t build/Threshold-*.pkg 2>/dev/null | head -1 || true)"
    [ -n "$threshold_pkg" ] || { echo "error: no build/Threshold-*.pkg (run Scripts/build-pkg.sh)" >&2; exit 1; }
    mkdir -p "$BUILD"
    local dialog_pkg
    dialog_pkg="$(latest_dialog_pkg)"

    vm_exists || tart clone "$IMAGE" "$VM"
    start_vm
    wait_reachable 300

    echo "Installing swiftDialog ($dialog_pkg)"
    tart exec -i "$VM" /bin/sh -c 'cat > /tmp/dialog.pkg' < "$dialog_pkg"
    g sudo installer -pkg /tmp/dialog.pkg -target /
    g /usr/local/bin/dialog --version

    echo "Copying fixtures and mock jamf"
    g sudo mkdir -p "$GUEST_FIXTURES"
    g sudo chown root:wheel "$GUEST_FIXTURES"
    g sudo chmod 0755 "$GUEST_FIXTURES"
    for f in dummy-1.0.pkg dummy-2.0.pkg dummy-hang-2.0.pkg dummy-fail-2.0.pkg; do
        vm_put "$BUILD/$f" "$GUEST_FIXTURES/$f" 0644
    done
    g sudo mkdir -p /usr/local/bin
    vm_put E2E/mock-jamf.sh /usr/local/bin/jamf 0755

    echo "Installing dummy 1.0 and Threshold"
    g sudo installer -pkg "$GUEST_FIXTURES/dummy-1.0.pkg" -target /
    tart exec -i "$VM" /bin/sh -c 'cat > /tmp/threshold.pkg' < "$threshold_pkg"
    g sudo installer -pkg /tmp/threshold.pkg -target /

    # Fixture pkgs are unsigned: the verifier accepts teamID UNSIGNED00 only if this root-owned marker exists.
    g sudo mkdir -p "/Library/Application Support/Threshold"
    g sudo touch "/Library/Application Support/Threshold/THRESHOLD_ALLOW_UNSIGNED"
    g sudo chown root:wheel "/Library/Application Support/Threshold/THRESHOLD_ALLOW_UNSIGNED"
    g sudo chmod 0644 "/Library/Application Support/Threshold/THRESHOLD_ALLOW_UNSIGNED"

    # Unmanaged VM: macOS wipes /Library/Managed Preferences at boot, so scenarios.sh writes test-config.plist
    # and this root-owned marker makes the daemon read it. Never create the marker on a production Mac.
    g sudo touch "/Library/Application Support/Threshold/THRESHOLD_TEST_MODE"
    g sudo chown root:wheel "/Library/Application Support/Threshold/THRESHOLD_TEST_MODE"
    g sudo chmod 0644 "/Library/Application Support/Threshold/THRESHOLD_TEST_MODE"

    echo "VM $VM is ready."
    g /usr/local/bin/dialog --version
}

case "${1:-}" in
    up) cmd_up ;;
    start) start_vm; wait_reachable 300 ;;
    down) tart stop "$VM" ;;
    destroy) tart stop "$VM" 2>/dev/null || true; tart delete "$VM" ;;
    *) echo "usage: $0 up|start|down|destroy" >&2; exit 2 ;;
esac
