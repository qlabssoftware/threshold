#!/bin/bash
# Jamf extension attribute: Threshold last-run status.
# Prints (with a "TEST MODE: " prefix when the Mac runs in test mode) OK, FAILED: ..., STILL RUNNING: ..., QUARANTINED: ..., BLOCKED: ...,
# DISABLED, OS BELOW MINIMUM: ..., CONFIG ERROR: ..., ERROR: ..., or NO RESULTS (not installed / never ran).
RESULTS="/Library/Application Support/Threshold/results.json"
# Test VMs only: results from the test-mode config source are prefixed with "TEST MODE: ".
overall="$(/usr/bin/plutil -extract overall raw -o - "$RESULTS" 2>/dev/null || echo "NO RESULTS")"
prefix=""
[ "$(/usr/bin/plutil -extract testMode raw -o - "$RESULTS" 2>/dev/null)" = "true" ] && prefix="TEST MODE: "
echo "<result>${prefix}${overall}</result>"
