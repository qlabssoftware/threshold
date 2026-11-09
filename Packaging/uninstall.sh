#!/bin/bash
# Threshold uninstaller. Run as root. Safe to run when nothing is installed.
if [ "$(id -u)" -ne 0 ]; then
    echo "uninstall.sh must be run as root (try: sudo $0)" >&2
    exit 1
fi

launchctl bootout system/com.qlabs.threshold 2>/dev/null

# Dismiss any Threshold dialog still on screen.
pkill -f "/Library/Application Support/Threshold/run/" 2>/dev/null

rm -f "/Library/LaunchDaemons/com.qlabs.threshold.plist"
rm -rf "/Library/Application Support/Threshold/run/"
rm -rf "/Library/Application Support/Threshold"
rm -rf "/Library/Logs/Threshold"

pkgutil --forget com.qlabs.threshold >/dev/null 2>&1

echo "Threshold uninstalled."
exit 0
