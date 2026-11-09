#!/bin/bash
# Mock jamf binary, installed in the VM at /usr/local/bin/jamf.
#   jamf checkJSSConnection ...   exit 0, unless /tmp/jamf-down exists (then exit 1)
#   jamf policy -event X          sleep 5 (Threshold shows "waiting"), then installs <fixtures>/X.pkg
#   jamf recon                    exit 0
# The fixtures live in /Library/Threshold-E2E (root-owned chain; /Users/Shared is world-writable).
FIXTURES="/Library/Threshold-E2E"

case "${1:-}" in
    checkJSSConnection)
        [ ! -e /tmp/jamf-down ] || exit 1
        exit 0
        ;;
    policy)
        shift
        event=""
        while [ $# -gt 0 ]; do
            if [ "$1" = "-event" ]; then event="${2:-}"; shift; fi
            shift
        done
        [ -n "$event" ] || { echo "mock jamf: policy needs -event" >&2; exit 1; }
        sleep 5
        # Not exec: Threshold tells waiting from installing by whether jamf has an installer descendant.
        /usr/sbin/installer -pkg "$FIXTURES/$event.pkg" -target /
        exit $?
        ;;
    recon)
        exit 0
        ;;
    *)
        echo "mock jamf: unsupported command: $*" >&2
        exit 1
        ;;
esac
