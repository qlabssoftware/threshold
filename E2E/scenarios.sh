#!/bin/bash
# Threshold end-to-end scenarios, run against the Tart VM prepared by vm.sh up.
#
#   scenarios.sh <1-9>|all
#
# Each scenario writes a test-mode config (test-config.plist; macOS wipes managed preferences at boot on an unmanaged VM) into the guest, resets state and the dummy app
# (except where noted), reboots the guest, waits for results.json of the new boot and asserts.
# Prints PASS/FAIL per scenario and a summary; exits non-zero if any scenario failed.
#
# Notes:
#  * `tart run` keeps running across a guest reboot (macOS restarts inside the same VM process). If the VM did
#    stop anyway, wait_reboot starts it again with `vm.sh start` (tart run --no-graphics in the background).
#  * The brief's "log shows waiting then installing" (scenario 3) is asserted from the dialog command file
#    (statustext: Waiting / Installing); Threshold does not write per-state lines to the unified log.
#  * Scenario 7 kills the daemon (-9) and boots it out of launchd, then requires the blur to be gone within
#    capSeconds + 60. In practice launchd removes the job's dialog with it (seen: ~20 s), which is the safe outcome;
#    the window's own watchdog (capSeconds + 60) is the backstop and is tested directly in InspectPresenterTests.
#    Then it bootstraps the daemon again and checks it does not re-blur.
#  * Every scenario uses the default (modern) window except scenario 3, which runs the classic window: it reads
#    the classic command file to prove Waiting came before Installing.
#  * Each scenario runs in its own subshell with `set +e`; every guest step is checked explicitly (must/bail), so
#    a failed reboot, results wait or setup step FAILs that scenario and the run continues to the summary.
#    Scenario exit codes: 0 PASS, 1 FAIL, 2 SKIP (harness limitation); anything else counts as FAIL (aborted).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE/.."
VM="${THRESHOLD_E2E_VM:-threshold-e2e}"
BUILD="E2E/build"
FIX="/Library/Threshold-E2E"
SUPPORT="/Library/Application Support/Threshold"
RESULTS="$SUPPORT/results.json"
STATE="$SUPPORT/state.json"
APP="/Applications/Threshold Dummy.app/Contents/Info.plist"
TEST_CONFIG="$SUPPORT/test-config.plist"   # read instead of managed prefs because vm.sh up created THRESHOLD_TEST_MODE
SUBSYSTEM='subsystem == "com.qlabs.threshold"'
# The blur: the classic window carries run/dialog.cmd in its arguments, the modern one (default) run/inspect.json.
BLUR_PAT="Threshold/run/([d]ialog[.]cmd|[i]nspect[.]json)"
STILL_PAT="/Library/Application Support/Threshold/run/[s]till.cmd"
WRONG_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

g() { tart exec "$VM" "$@"; }
# bounded <seconds> <command...>: runs the command, killing it after the bound (macOS has no `timeout`).
# `tart exec` can hang forever when the guest reboots or logs out mid-connection. Pass the external command
# directly (not a shell function) so the kill reaches it.
bounded() {
    local secs="$1" pid killer rc
    shift
    "$@" &
    pid=$!
    ( sleep "$secs"; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 &
    killer=$!
    wait "$pid" 2>/dev/null; rc=$?
    kill "$killer" 2>/dev/null; wait "$killer" 2>/dev/null
    return "$rc"
}
gb() { bounded 20 tart exec "$VM" "$@"; }   # bounded guest exec for calls that may straddle a reboot or logout
vm_reachable() { bounded 10 tart exec "$VM" true >/dev/null 2>&1; }
vm_running() { tart list 2>/dev/null | awk -v vm="$VM" '$2 == vm && $NF == "running" {found=1} END{exit !found}'; }
sha_of() { awk -v f="$1" '$2 == f {print $1}' "$BUILD/checksums.txt"; }

# ---------------------------------------------------------------- assertions

SCENARIO_FAILS=0
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0
FAILED_LIST=""

begin() { SCENARIO_FAILS=0; SCENARIO="$1"; echo; echo "=== Scenario $1: $2"; }
fail() { echo "  FAIL $1"; SCENARIO_FAILS=$((SCENARIO_FAILS + 1)); }
check() { # check <description> <expected> <actual>
    if [ "$2" = "$3" ]; then echo "  ok   $1"; else fail "$1 (expected '$2', got '$3')"; fi
}
check_contains() { # check_contains <description> <needle> <haystack>
    case "$3" in *"$2"*) echo "  ok   $1" ;; *) fail "$1 (expected to contain '$2', got '$3')" ;; esac
}
check_cmd() { # check_cmd <description> <command...>: ok if the command succeeds
    local desc="$1"; shift
    if "$@"; then echo "  ok   $desc"; else fail "$desc"; fi
}
check_not() { # check_not <description> <command...>: ok if the command fails
    local desc="$1"; shift
    if "$@"; then fail "$desc"; else echo "  ok   $desc"; fi
}
# Ends the scenario subshell with its verdict. Prints the guest diagnostics on failure.
finish() {
    if [ "$SCENARIO_FAILS" -eq 0 ]; then
        echo "PASS scenario $SCENARIO"; exit 0
    fi
    echo "FAIL scenario $SCENARIO"
    echo "--- results.json:"; printf '%s\n' "${RES:-"(none)"}"
    echo "--- Threshold log since reboot:"; guest_log 2>&1 | tail -40
    exit 1
}
bail() { fail "$1"; finish; }                       # a precondition failed: stop this scenario as FAIL
skip() { echo "  SKIP $1"; echo "SKIP scenario $SCENARIO"; exit 2; }
must() { "$@" || bail "setup step failed: $*"; }    # a guest step that must succeed

# ---------------------------------------------------------------- config builders

item_cached() { # item_cached <pkg-file> <target> [sha-override]
    local sha="${3:-$(sha_of "$1")}"
    cat <<XML
        <dict>
            <key>id</key><string>dummy</string>
            <key>displayName</key><string>Threshold Dummy</string>
            <key>appPath</key><string>/Applications/Threshold Dummy.app</string>
            <key>targetVersion</key><string>$2</string>
            <key>source</key><string>cachedPackage</string>
            <key>packagePath</key><string>$FIX/$1</string>
            <key>sha256</key><string>$sha</string>
            <key>teamID</key><string>UNSIGNED00</string>
        </dict>
XML
}
item_jamf() { # item_jamf <trigger> <target>
    cat <<XML
        <dict>
            <key>id</key><string>dummy</string>
            <key>displayName</key><string>Threshold Dummy</string>
            <key>appPath</key><string>/Applications/Threshold Dummy.app</string>
            <key>targetVersion</key><string>$2</string>
            <key>source</key><string>jamfTrigger</string>
            <key>trigger</key><string>$1</string>
        </dict>
XML
}

# push_config <item-xml> [capSeconds] [enabled true|false]   (WINDOW_STYLE=classic for the classic window)
push_config() {
    local file rc; file="$(mktemp)"
    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
        echo '<plist version="1.0"><dict>'
        echo "    <key>enabled</key><${3:-true}/>"
        [ -z "${WINDOW_STYLE:-}" ] || echo "    <key>windowStyle</key><string>$WINDOW_STYLE</string>"
        [ -z "${STATUS_LOG:-}" ] || echo "    <key>statusLog</key><string>$STATUS_LOG</string>"
        [ -z "${2:-}" ] || echo "    <key>capSeconds</key><integer>$2</integer>"
        echo '    <key>items</key><array>'
        echo "$1"
        echo '    </array>'
        echo '</dict></plist>'
    } > "$file"
    plutil -lint "$file" >/dev/null || { rm -f "$file"; return 1; }
    tart exec -i "$VM" sudo /bin/sh -c "cat > '$TEST_CONFIG' && chown root:wheel '$TEST_CONFIG' && chmod 0644 '$TEST_CONFIG'" < "$file"
    rc=$?
    rm -f "$file"
    return $rc
}

# ---------------------------------------------------------------- guest helpers

kill_installs() { g sudo /bin/sh -c 'pkill -x installer; pkill -f "[s]leep 900"; true'; }

reset_dummy() { # back to installed 1.0, clean leftovers
    kill_installs || return 1
    g sudo rm -rf "/Applications/Threshold Dummy.app" /tmp/jamf-down || return 1
    g sudo installer -pkg "$FIX/dummy-1.0.pkg" -target / >/dev/null || return 1
    [ "$(guest_version)" = "1.0" ]
}
# Fresh state: no state.json/results.json, and no stale dialog command files that could satisfy later assertions.
reset_state() {
    g sudo rm -f "$STATE" "$RESULTS" "$SUPPORT/run/dialog.cmd" "$SUPPORT/run/still.cmd" "$SUPPORT/run/inspect.json" \
        /var/tmp/dialog.log
}
guest_version() { g plutil -extract CFBundleShortVersionString raw "$APP" 2>/dev/null || echo "?"; }
guest_uuid() { gb sysctl -n kern.bootsessionuuid 2>/dev/null; }
# Fails loudly if the log cannot be read, so an unreadable log can never look like "no launch".
guest_log() { g sudo log show --predicate "$SUBSYSTEM" --start "$LOGSTART" --info; }
launch_count() { # prints the number of blur launches since the reboot, or ERR
    local out
    out="$(guest_log 2>/dev/null)" || { echo ERR; return 1; }
    printf '%s\n' "$out" | grep -c 'showing blur' || true
}
alive() { g pgrep -f "$1" >/dev/null 2>&1; } # returns 0 if a matching process exists
alive_exact() { g pgrep -x "$1" >/dev/null 2>&1; }

# wait_gone <pattern> <timeout-s>: 0 once no process matches
wait_gone() {
    local waited=0
    while alive "$1"; do
        sleep 2; waited=$((waited + 2)); [ "$waited" -lt "$2" ] || return 1
    done
}
wait_alive() {
    local waited=0
    until alive "$1"; do
        sleep 1; waited=$((waited + 1)); [ "$waited" -lt "$2" ] || return 1
    done
}

# Reboots the guest and waits until it is back on a new boot session. Sets PRE_EPOCH, LOGSTART, NEW_UUID.
# `tart exec ... shutdown` must be the direct command (a shell-backgrounded shutdown dies with the exec session) and
# the exec connection never closes by itself, so it is killed after a short bound; its status is ignored.
reboot_and_wait() {
    vm_running || "$HERE/vm.sh" start || return 1
    local old; old="$(guest_uuid)"
    [ -n "$old" ] || { echo "error: cannot read the pre-reboot boot session uuid" >&2; return 1; }
    PRE_EPOCH="$(g date +%s)"
    LOGSTART="$(g date '+%Y-%m-%d %H:%M:%S')"
    [ -n "$PRE_EPOCH" ] && [ -n "$LOGSTART" ] || { echo "error: cannot read the guest clock" >&2; return 1; }
    # Never returns once the guest goes down, so bound it (15 s) and ignore the status.
    bounded 15 tart exec "$VM" sudo -n /sbin/shutdown -r now >/dev/null 2>&1 || true
    local waited=0 new=""
    while :; do
        sleep 2; waited=$((waited + 2))
        if ! vm_running; then "$HERE/vm.sh" start || true; fi
        if vm_reachable; then
            new="$(guest_uuid || true)"
            if [ -n "$new" ] && [ "$new" != "$old" ]; then break; fi
        fi
        if [ "$waited" -ge 600 ]; then echo "error: guest did not come back within 600 s" >&2; return 1; fi
    done
    NEW_UUID="$new"
    # After reboot the base image auto-logs in admin before the daemon starts; the daemon's SessionGate treats that
    # as the first login (uptime < 10 min).
}

# Polls results.json until runAt is after the reboot and bootSession is the new one (timeout 600 s). Sets RES.
wait_results() {
    local waited=0 json run_at epoch boot
    RES=""
    while [ "$waited" -lt 600 ]; do
        json="$(g sudo cat "$RESULTS" 2>/dev/null || true)"
        if [ -n "$json" ]; then
            run_at="$(printf '%s' "$json" | plutil -extract runAt raw -o - - 2>/dev/null || true)"
            boot="$(printf '%s' "$json" | plutil -extract bootSession raw -o - - 2>/dev/null || true)"
            epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$run_at" +%s 2>/dev/null || echo 0)"
            if [ "$epoch" -ge "$PRE_EPOCH" ] && [ "$boot" = "$NEW_UUID" ]; then RES="$json"; return 0; fi
        fi
        if [ -n "$SCREENSHOT" ] && [ ! -e "$SHOT_DONE" ] && alive "$BLUR_PAT"; then
            if g screencapture -x /tmp/threshold-blur.png >/dev/null 2>&1; then
                g cat /tmp/threshold-blur.png > "$SCREENSHOT" 2>/dev/null && : > "$SHOT_DONE" && echo "  screenshot: $SCREENSHOT"
            fi
        fi
        sleep 2; waited=$((waited + 2))
    done
    return 1
}
rj() { printf '%s' "$RES" | plutil -extract "$1" raw -o - - 2>/dev/null || true; }

# The log source must demonstrably work, otherwise "no launch" assertions would pass vacuously.
require_log() {
    local out
    out="$(guest_log 2>&1)" || bail "cannot read the Threshold log in the guest"
    case "$out" in *"daemon starting"*) ;; *) bail "Threshold log since reboot has no 'daemon starting' line" ;; esac
    # Proves the config really came from test-config.plist (managed preferences are wiped on this VM).
    case "$out" in *"TEST MODE: config from test-config.plist"*) ;; *) bail "Threshold log since reboot has no 'TEST MODE' line (config source not proven)" ;; esac
}

# run_boot: reboot, wait for results, prove the log is readable. A failure FAILs and ends the scenario.
run_boot() {
    reboot_and_wait || bail "guest reboot did not complete"
    wait_results || bail "results.json not updated for the new boot within 600 s"
    require_log
}

prepare() { # prepare <item-xml> [cap] [enabled]   (config + reset state + dummy back to 1.0)
    must push_config "$@"
    must reset_state
    must reset_dummy
}

no_launch() { check "no blur dialog was launched" "0" "$(launch_count)"; }

# ---------------------------------------------------------------- scenarios
# Each runs in a subshell (see main) and ends through finish/bail/skip.

s1() {
    begin 1 "dummy already at target 1.0: nothing to do"
    prepare "$(item_cached dummy-2.0.pkg 1.0)"
    run_boot
    check "overall" "OK" "$(rj overall)"
    check "dummy is up to date" "dummy" "$(rj upToDate.0)"
    no_launch
    finish
}

s2() {
    begin 2 "cached dummy-2.0.pkg, target 2.0"
    prepare "$(item_cached dummy-2.0.pkg 2.0)"
    SHOT_DONE="$(mktemp -u)"; SCREENSHOT="$BUILD/scenario2-blur.png"
    reboot_and_wait || bail "guest reboot did not complete"
    # Poll for the blur right away (1 s), before waiting on results.json: the whole install is only ~11 s.
    # Prove the blur really existed before asserting that it is gone. If the short window was missed, fall back to the
    # daemon's own launch line plus the dialog command file (the dialog was driven), and say so.
    if wait_alive "$BLUR_PAT" 120; then
        echo "  ok   blur dialog process seen"
        # Best-effort screenshot while the blur is up.
        if g screencapture -x /tmp/threshold-blur.png >/dev/null 2>&1; then
            g cat /tmp/threshold-blur.png > "$SCREENSHOT" 2>/dev/null && echo "  screenshot: $SCREENSHOT"
        fi
    else
        wait_results || bail "results.json not updated for the new boot within 600 s"
        require_log
        if [ "$(launch_count)" = "1" ] && g sudo grep -q '"preset2"' "$SUPPORT/run/inspect.json"; then
            echo "  note blur process window missed; launch confirmed by log and inspect.json"
        else
            bail "blur dialog never appeared"
        fi
    fi
    [ -n "$RES" ] || wait_results || bail "results.json not updated for the new boot within 600 s"
    SCREENSHOT=""
    require_log
    check "item state" "done" "$(rj items.0.state)"
    check "app version" "2.0" "$(guest_version)"
    check "blur launched exactly once (same log source as the no-launch scenarios)" "1" "$(launch_count)"
    check_contains "modern window used" "showing blur (modern window)" "$(guest_log 2>&1)"
    check_cmd "item marker created for the cards view" g sudo test -e "$SUPPORT/run/done/item0"
    check_cmd "no blur dialog alive at end" wait_gone "$BLUR_PAT" 30
    check_not "shared /var/tmp/dialog.log removed after the run" g test -e /var/tmp/dialog.log
    check_cmd "no still-running dialog alive at end" wait_gone "$STILL_PAT" 5
    finish
}

s3() {
    begin 3 "jamfTrigger dummy-2.0, target 2.0 (classic window)"
    WINDOW_STYLE=classic prepare "$(item_jamf dummy-2.0 2.0)"
    run_boot
    check "item state" "done" "$(rj items.0.state)"
    check "app version" "2.0" "$(guest_version)"
    check_contains "classic window used" "showing blur (classic window)" "$(guest_log 2>&1)"
    local cmd; cmd="$(g sudo cat "$SUPPORT/run/dialog.cmd" 2>/dev/null || true)"
    check_contains "dialog showed Waiting" "statustext: Waiting" "$cmd"
    check_contains "dialog showed Installing" "statustext: Installing" "$cmd"
    local waiting_line installing_line
    waiting_line="$(printf '%s\n' "$cmd" | grep -n 'statustext: Waiting' | head -1 | cut -d: -f1)"
    installing_line="$(printf '%s\n' "$cmd" | grep -n 'statustext: Installing' | head -1 | cut -d: -f1)"
    if [ -n "$waiting_line" ] && [ -n "$installing_line" ] && [ "$waiting_line" -lt "$installing_line" ]; then
        echo "  ok   Waiting came before Installing"
    else
        fail "Waiting came before Installing"
    fi
    finish
}

s4() {
    begin 4 "cached dummy-hang-2.0.pkg, capSeconds 60, statusLog install.log; Mac kept awake"
    STATUS_LOG=/var/log/install.log prepare "$(item_cached dummy-hang-2.0.pkg 2.0)" 60
    reboot_and_wait || bail "guest reboot did not complete"
    wait_alive "$BLUR_PAT" 300 || { kill_installs; bail "blur dialog never appeared"; }
    sleep 10
    local asserts; asserts="$(g pmset -g assertions 2>/dev/null || true)"
    check_contains "display kept awake while the blur is up" "PreventUserIdleDisplaySleep named: \"Threshold is installing updates\"" "$asserts"
    check_contains "system kept awake while the blur is up" "PreventUserIdleSystemSleep named: \"Threshold is installing updates\"" "$asserts"
    local status; status="$(g sudo cat /var/tmp/dialog.log 2>/dev/null | grep '^item:item0:installing:' | grep -v ':Installing$' | tail -1)"
    if [ -n "$status" ]; then echo "  ok   install.log line shown on the card ($status)"; else fail "install.log line shown on the card"; fi
    wait_results || { kill_installs; bail "results.json not updated for the new boot within 600 s"; }
    require_log
    check "item state" "stillRunning" "$(rj items.0.state)"
    check_contains "overall" "STILL RUNNING: dummy" "$(rj overall)"
    check_cmd "installer postinstall (sleep 900) still running after the cap" alive '[s]leep 900'
    check_cmd "installer process still running" alive_exact installer
    check_cmd "still-running dialog present" wait_alive "$STILL_PAT" 30
    check_cmd "blur dialog gone" wait_gone "$BLUR_PAT" 30
    asserts="$(g pmset -g assertions 2>/dev/null || true)"
    check_not "display hold released when the blur lifted" grep -q "PreventUserIdleDisplaySleep named: \"Threshold" <<< "$asserts"
    check_contains "system still kept awake for the background install" "PreventUserIdleSystemSleep named: \"Threshold is installing updates\"" "$asserts"
    kill_installs
    finish
}

s5() {
    begin 5 "cached package with wrong sha256, only item"
    prepare "$(item_cached dummy-2.0.pkg 2.0 "$WRONG_SHA")"
    run_boot
    check "skipped item" "dummy" "$(rj skipped.0.id)"
    check_contains "skip reason" "checksum" "$(rj skipped.0.reason)"
    check "app version unchanged" "1.0" "$(guest_version)"
    no_launch
    finish
}

s6() {
    begin 6 "dummy-fail-2.0.pkg x3 reboots, then quarantine on the 4th"
    prepare "$(item_cached dummy-fail-2.0.pkg 2.0)"   # state reset once; deliberately kept across the 4 reboots
    local n count
    for n in 1 2 3; do
        run_boot
        check "run $n overall" "FAILED: dummy" "$(rj overall)"
        check "run $n item state" "failed" "$(rj items.0.state)"
        count="$(g sudo cat "$STATE" 2>/dev/null | plutil -extract failures.dummy.count raw -o - - 2>/dev/null || true)"
        check "run $n failure count" "$n" "$count"
        [ "$SCENARIO_FAILS" -eq 0 ] || finish   # later runs depend on this one
    done
    run_boot
    check "run 4 overall" "QUARANTINED: dummy" "$(rj overall)"
    check "run 4 dummy skipped as quarantined" "quarantined" "$(rj skipped.0.reason)"
    no_launch
    finish
}

s7() {
    begin 7 "dummy-hang, cap 300, kill -9 the daemon 20 s after login; the blur must still go away"
    prepare "$(item_cached dummy-hang-2.0.pkg 2.0)" 300
    reboot_and_wait || bail "guest reboot did not complete"
    wait_alive "$BLUR_PAT" 600 || { kill_installs; bail "blur dialog never appeared"; }
    local t0; t0="$(date +%s)"   # blur launch as first observed (host clock; only differences are used)
    require_log
    sleep 20
    check_cmd "daemon killed" g sudo pkill -9 -f 'Application Support/Threshold/[t]hreshold daemon'
    # Take the job out of launchd now so it cannot relaunch (a relaunch would pkill the dialog via killStaleDialogs).
    check_cmd "daemon booted out of launchd" g sudo launchctl bootout system/com.qlabs.threshold
    check_not "no daemon process left" alive 'Application Support/Threshold/[t]hreshold daemon'
    # The watchdog closes the window at capSeconds+60 = 360 s; allow 10 s for polling/exec latency.
    if wait_gone "$BLUR_PAT" 420; then
        local elapsed=$(( $(date +%s) - t0 ))
        echo "  blur gone ${elapsed}s after launch (limit 360 + 10)"
        if [ "$elapsed" -le 370 ]; then echo "  ok   blur exited on its own within cap + 60 s"; else fail "blur exited on its own within cap + 60 s"; fi
    else
        fail "blur exited on its own within cap + 60 s (still alive after 420 s)"
    fi
    check_cmd "daemon bootstrapped again" g sudo launchctl bootstrap system /Library/LaunchDaemons/com.qlabs.threshold.plist
    sleep 20
    check "blur launched exactly once (restart did not re-blur)" "1" "$(launch_count)"
    check_contains "restarted daemon saw the boot as handled" "boot session already handled" "$(guest_log 2>&1)"
    check_not "no blur dialog after restart" alive "$BLUR_PAT"
    kill_installs
    finish
}

s8() {
    begin 8 "enabled = false"
    prepare "$(item_cached dummy-2.0.pkg 2.0)" "" false
    run_boot
    check "overall" "DISABLED" "$(rj overall)"
    check "app version unchanged" "1.0" "$(guest_version)"
    no_launch
    finish
}

s9() {
    begin 9 "log out and back in after a scenario-2 style run: no second run"
    prepare "$(item_cached dummy-2.0.pkg 2.0)"
    run_boot
    check "item state" "done" "$(rj items.0.state)"
    local run_at boot uid lw_before
    run_at="$(rj runAt)"; boot="$(rj bootSession)"
    uid="$(g id -u admin)"; [ -n "$uid" ] || bail "cannot read admin uid"
    lw_before="$(g pgrep -x -u admin loginwindow 2>/dev/null | head -1)"
    [ -n "$lw_before" ] || bail "no admin loginwindow before logout (is admin logged in?)"
    local brc=0
    bounded 30 tart exec "$VM" sudo launchctl bootout "gui/$uid" >/dev/null 2>&1 || brc=$?
    # The guest agent may live in the GUI session, so a dropped exec connection is possible; the logout itself is
    # proven below by the admin loginwindow pid changing.
    sleep 10
    local waited=0 console="" lw_after="" back=1
    while [ "$waited" -lt 240 ]; do
        if vm_reachable; then
            console="$(gb stat -f %Su /dev/console 2>/dev/null || true)"
            lw_after="$(gb pgrep -x -u admin loginwindow 2>/dev/null | head -1 || true)"
            if [ "$console" = "admin" ] && [ -n "$lw_after" ]; then back=0; break; fi
        fi
        sleep 3; waited=$((waited + 3))
    done
    if [ "$back" -ne 0 ]; then
        skip "auto-login did not bring admin back within 240 s after bootout gui/$uid (bootout rc=$brc); harness limitation"
    fi
    if [ "$lw_after" = "$lw_before" ]; then
        fail "a logout happened (admin loginwindow pid unchanged: $lw_before; bootout rc=$brc)"
    else
        echo "  ok   a logout happened (admin loginwindow pid $lw_before -> $lw_after)"
    fi
    sleep 30
    RES="$(g sudo cat "$RESULTS" 2>/dev/null || true)"
    check "runAt unchanged" "$run_at" "$(rj runAt)"
    check "bootSession unchanged" "$boot" "$(rj bootSession)"
    check "blur launched only once this boot" "1" "$(launch_count)"
    finish
}

# ---------------------------------------------------------------- main

[ $# -eq 1 ] || { echo "usage: $0 <1-9>|all" >&2; exit 2; }
[ -f "$BUILD/checksums.txt" ] || { echo "error: run make-fixtures.sh first" >&2; exit 1; }
vm_running || "$HERE/vm.sh" start || { echo "error: cannot start $VM" >&2; exit 1; }
LOGSTART="$(g date '+%Y-%m-%d %H:%M:%S')"
RES=""; PRE_EPOCH=0; NEW_UUID=""; SHOT_DONE=""; SCREENSHOT=""

run_scenario() { # runs s<n> in a subshell without errexit; its exit code is the verdict
    local rc=0
    ( set +e; "s$1" ) || rc=$?
    case "$rc" in
        0) TOTAL_PASS=$((TOTAL_PASS + 1)) ;;
        2) TOTAL_SKIP=$((TOTAL_SKIP + 1)) ;;
        *) [ "$rc" -eq 1 ] || echo "FAIL scenario $1 (aborted unexpectedly, exit $rc)"
           TOTAL_FAIL=$((TOTAL_FAIL + 1)); FAILED_LIST="$FAILED_LIST $1" ;;
    esac
}

case "$1" in
    all) for n in 1 2 3 4 5 6 7 8 9; do run_scenario "$n"; done ;;
    [1-9]) run_scenario "$1" ;;
    *) echo "usage: $0 <1-9>|all" >&2; exit 2 ;;
esac

echo
echo "=== Summary: $TOTAL_PASS passed, $TOTAL_FAIL failed, $TOTAL_SKIP skipped${FAILED_LIST:+ (failed scenarios:$FAILED_LIST)}"
[ "$TOTAL_FAIL" -eq 0 ]
