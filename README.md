# Threshold

> **New software.** Pilot on a few Macs before rolling out to your whole fleet.

Threshold updates apps right after login, before people start working. It is a root LaunchDaemon, configured entirely by an MDM configuration profile (preference domain `com.qlabs.threshold`).

## What it does

At the first login after each boot (log out/in, lock/unlock and fast user switching do not count), Threshold compares each configured app's installed version with the target version in your profile. If nothing needs updating, nothing happens: no blur, no window. If something does, it covers the desktop with a blurred full-screen [swiftDialog](https://github.com/swiftDialog/swiftDialog) progress screen, installs the updates in order, verifies each one by reading the version on disk, optionally runs health checks, and releases the desktop. Combined with a regular forced restart, every Mac picks up queued updates without prompts or deferrals.

Updates come from either a Jamf policy custom trigger or a package already cached on disk. Cached packages are preferred for network clients (VPN, ZTNA) because they need no network.

The blur is a strong deterrent, not a security boundary.

## Prerequisites

- Apple silicon, macOS 14 or later.
- swiftDialog 2.5.0 or later at `/usr/local/bin/dialog`, root-owned (see "Trust rules"). Threshold never installs it silently in front of a user: if swiftDialog is missing, too old or untrusted, nothing runs and the results file says `BLOCKED`. On Macs where `/usr/local/bin` is owned by a user (common after Migration Assistant or an Intel Homebrew install), Threshold uses the real binary inside `/Library/Application Support/Dialog/Dialog.app` instead; nothing to configure.
- An MDM that can deploy a configuration profile with a custom settings payload. Only managed (forced) preferences are trusted; values a user sets themselves are ignored.
- Jamf Pro is optional, only needed for `jamfTrigger` items.

## Install

1. **Package.** Build with `Scripts/build-pkg.sh` (output: `build/Threshold-<version>.pkg`), then deploy it with your MDM. It is a component package: fine for a Jamf policy or `installer -pkg`, but MDM `InstallEnterpriseApplication` needs a signed distribution package, so wrap it (`productbuild --package ...`) first if you deploy that way. It installs the binary to `/Library/Application Support/Threshold/threshold` and the LaunchDaemon `/Library/LaunchDaemons/com.qlabs.threshold.plist`, and loads it. Installing mid-session is safe: a mid-session install will not blur unless the Mac booted less than 10 minutes ago (it is then treated as the first login of this boot). Set `SIGN_IDENTITY`, `INSTALLER_IDENTITY` and `NOTARY_PROFILE` to sign and notarize.
2. **Configuration profile.**
   - Jamf Pro: add `Packaging/com.qlabs.threshold.schema.json` as a custom schema under *Computers > Configuration Profiles > Application & Custom Settings > External Applications*, with preference domain `com.qlabs.threshold`. You get a form for every key.
   - Other MDMs: start from `Packaging/example.mobileconfig`. Its sha256 (64 zeros), team ID, paths and versions are placeholders; replace them.
3. **Extension attribute (optional).** Add `Packaging/threshold-ea.sh` as a Jamf script extension attribute to report the last result.

## Configuration reference

A working profile needs only `items`. Every global key has a default. Each version bump means editing `targetVersion` (plus `sha256` for a cached package).

### Global keys

All optional.

| Key | Type | Default | Meaning |
|---|---|---|---|
| `items` | array of dictionaries | `[]` | Updates to run, in order. See "Item keys". |
| `enabled` | boolean | `true` | Kill switch. `false` makes Threshold do nothing. |
| `capSeconds` | integer, 30-3600 | `300` | When the blur lifts. See "The cap rule". |
| `title` | string | `Updating your Mac` | Dialog title. |
| `message` | string | `Installing important updates. This usually takes a few minutes.` | Dialog message. |
| `icon` | string | none | Dialog icon (path or URL), e.g. your company logo. |
| `supportText` | string | `If this keeps happening, contact IT.` | Shown when something fails. |

Advanced (the defaults suit most fleets):

| Key | Type | Default | Meaning |
|---|---|---|---|
| `maxConsecutiveFailures` | integer, >= 1 | `3` | Failures in a row (same target version) before an item is quarantined. |
| `networkWaitSeconds` | integer, 0-300 | `30` | If the Jamf Pro server is unreachable at login (Wi-Fi often joins after login), wait up to this long under the blur, rechecking every ~5 s, before skipping Jamf-trigger items. Counts against `capSeconds`. `0` = no wait, and no blur if only Jamf items are due. |
| `minBatteryPercent` | integer, 0-100 | `20` | On battery, items are skipped below this charge. |
| `requireAC` | boolean | `false` | Skip installs unless on AC power. |
| `minFreeDiskGB` | number, >= 0 | `5` | Skip installs when free disk is below this. |
| `ignoredUsers` | array of strings | `[]` | Account short names that never trigger Threshold (e.g. a local admin or kiosk account). |

An invalid global value means nothing runs (`CONFIG ERROR`). It never locks the screen.

Fixed values (not configurable): swiftDialog 2.5.0 or later at `/usr/local/bin/dialog`, or else the binary inside `/Library/Application Support/Dialog/Dialog.app`; `jamf` at `/usr/local/bin/jamf`, or else `/usr/local/jamf/bin/jamf`; each health check is limited to 60 s and each hook script to 120 s, always within the cap. Keys removed in 2026-11 (`swiftDialogPath`, `jamfBinaryPath`, `minSwiftDialogVersion`, `healthTimeoutSeconds`, `hookTimeoutSeconds`, `networkCritical`) are ignored if a profile still sets them.

The config is read when the daemon starts at boot and read again at the first login; the login copy decides the run. If the boot copy has no items at all (the profile may not be delivered yet that early), Threshold does not mark the boot as handled; it waits for the login and decides from the login copy.

### Item keys (inside `items`)

Required for every item:

| Key | Type | Meaning |
|---|---|---|
| `id` | string | Stable identifier for state, logs and results. Letters, digits, `.`, `_`, `-`. Unique. |
| `appPath` *or* `versionCommand` | string | Where the installed version is read: an app's Info.plist, or a command that prints the version. Exactly one. |
| `targetVersion` | string (or whole number) | Minimum acceptable version. Dotted-numeric comparison. Use a string for anything with a dot: a real number loses digits (`5.10` reads back as `5.1`), so a real with a fraction makes the item invalid. |
| `source` | `jamfTrigger` or `cachedPackage` | Where the installer comes from. |

Required by source:

| Source | Keys |
|---|---|
| `jamfTrigger` | `trigger`: Jamf custom event name, no whitespace. |
| `cachedPackage` | `packagePath`: absolute path of the `.pkg`. `sha256`: 64 hex characters the package must match. `teamID`: 10-character Apple Team ID it must be signed by. |

Optional:

| Key | Type | Default | Meaning |
|---|---|---|---|
| `displayName` | string | `id` | Name shown in the dialog. |
| `icon` | string | the app's icon | Icon shown in the dialog row. |
| `versionKey` | string | `CFBundleShortVersionString` | Info.plist key read from `appPath` (e.g. `CFBundleVersion`). |
| `fallbackTrigger` | string | none | `cachedPackage` only. Jamf custom event run instead when the cached package is unusable (missing, wrong sha256, bad signature/team ID, untrusted location). The unusable package is never run. The result's reason says the fallback was used. |
| `healthProcess` | string | none | After install, this process must be running. |
| `healthCommand` | string | none | After install, this command must exit 0. |
| `healthURL` | string | none | After install, this http(s) URL must be reachable. |
| `timeoutSeconds` | integer, > 0 | `capSeconds` | Per-item time limit. |
| `preInstallScript` | string | none | Absolute path of a hook run before install. |
| `postInstallScript` | string | none | Absolute path of a hook run after the version check. |

Setting any `health*` key turns the health check on for that item; use them for network clients (VPN, ZTNA) so a user isn't released into a Mac with no network. If a check fails the item is marked failed; the blur still lifts on the normal rules.

An invalid item is skipped and reported; other items still run. Versions that can't be parsed make the item skipped (nothing is installed).

## The cap rule

The blur lifts at `capSeconds` (default 5 minutes). Every item follows the same rule, including network-critical ones. At the cap:

- Items not started yet are skipped and retried at the next login.
- Items still downloading or waiting on Jamf are cancelled and retried next login. This counts toward quarantine (see "Quarantine").
- An item that is **installing is never killed**. The blur lifts, the install keeps running in the background, and a small window says the app is "still updating, don't restart". A truly hung install is logged and flagged (`STILL RUNNING`), never killed.

What counts as installing:

- A cached package is installing from the moment `installer` starts.
- A Jamf policy is "waiting" while `jamf policy` runs with no child processes, or only these known-benign ones: `curl`, `jamfAgent`, `sleep`, `logger`, `jamfHelper` (check-in, downloads, notifications). As soon as **any other** process appears anywhere under it (`installer`, a script, `ditto`, a vendor installer, `softwareupdate`, ...) the item is installing, and stays installing until it ends. If Threshold can't tell, it assumes installing. Only a waiting policy is ever cancelled.

As a failsafe the dialog also has its own timer, so it goes away on its own even if the daemon dies.

## Quarantine

An item that fails `maxConsecutiveFailures` times in a row for the same target version is quarantined: skipped and reported until its target version changes. This stops a failing item from blurring the screen at every login.

Counts toward quarantine (outcomes the item caused):

- the install failed
- the version is unchanged after install (including a Jamf trigger that ran but is not scoped to this Mac)
- the health check failed
- the item was still installing or hung at the cap (remembered across boots)
- a Jamf policy still waiting or downloading at the cap, and cancelled (so a permanently stuck download can't blur every boot forever)

Does not count:

- safety-check skips (power, disk space, Jamf unreachable)
- items not started because the cap was reached
- a failing post-install hook when the version check passed
- a missing or unusable cached package (with `fallbackTrigger` set, the Jamf policy runs instead)
- an untrusted hook script (skipped when planning)

## Trust rules

Everything Threshold runs as root must be something only root could have put there.

- **Cached packages** must live in a root-owned directory chain, for example the Jamf Waiting Room (`/Library/Application Support/JAMF/Waiting Room/`). Otherwise they are skipped as "untrusted location". The file must also match `sha256` and be signed by `teamID`. They are checked and installed at their canonical path (parent directories resolved), so a symlink can't swap the file between the check and the install. Threshold never deletes or moves cached packages.
- **Hook scripts** must be root-owned regular files and not group/other-writable, and so must every parent directory up to `/` (the file itself must not be a symlink). An item with an untrusted hook is skipped when planning ("hook not trusted", not counted toward quarantine), so it never shows the blur. Hooks run as root, via the checked canonical path, limited to 120 s. A failing pre-hook skips the item; a failing post-hook marks it failed but never undoes the install.
- **swiftDialog and jamf** (`/usr/local/bin/dialog`, then the binary inside `Dialog.app`; `/usr/local/bin/jamf`, then `/usr/local/jamf/bin/jamf`) are resolved to their real file first. That file must pass the hook-script rule above, and if the configured path is a symlink, every symlink on the way must sit in a root-owned, non-writable directory chain. Threshold then runs the resolved file, never the configured path. An untrusted swiftDialog counts as missing (`BLOCKED: swiftDialog missing, too old or untrusted`); an untrusted jamf skips `jamfTrigger` items ("jamf binary missing or untrusted") and `jamf recon`. `/usr/local/bin` is often user-owned on migrated Macs: check with `ls -ld /usr/local /usr/local/bin`.

## Results, extension attribute, logs

- Results: `/Library/Application Support/Threshold/results.json` (run time, boot session, user, per-item state, versions, durations, errors, and an `overall` summary).
- The `overall` value, which the EA reports, is one of:

| Value | Meaning |
|---|---|
| `OK` | Everything needed was done (or nothing was needed). |
| `FAILED: id,...` | These items failed. |
| `STILL RUNNING: id,...` | These installs were still running at the cap. |
| `QUARANTINED: id,...` | These items are being skipped after repeated failures. |
| `BLOCKED: reason` | Nothing could be installed, for example swiftDialog missing, too old or untrusted. |
| `DISABLED` | `enabled` is `false`. |
| `CONFIG ERROR: ...` | The global config is invalid. |
| `ERROR: ...` | Internal problem, for example boot session unknown. |
| `NO RESULTS` | (EA only) `results.json` missing or unreadable (not installed, hasn't run yet, or damaged). |

Several segments can be joined with `; `.

- Logs: unified logging, `log show --predicate 'subsystem == "com.qlabs.threshold"' --last 1d --info`, and the file `/Library/Logs/Threshold/threshold.log`.
- After a run with installs, Threshold runs `jamf recon` in the background (if a trusted jamf binary is present).

## `threshold check`

`/Library/Application Support/Threshold/threshold check` prints JSON `{testMode, config, invalidItems, plan: {work, skipped (with reasons), upToDate}}` describing how the current managed config parses and what it would do, without installing anything or showing UI. It exits 2 with `{"error": ...}` on a global config error. Use it to validate a profile on a test Mac. `threshold version` prints the version; `threshold daemon` is what the LaunchDaemon runs.

## Test mode (for test VMs only)

Unmanaged VMs have no MDM, and macOS wipes `/Library/Managed Preferences` at boot, so the end-to-end tests cannot use a profile. Instead, if the marker `/Library/Application Support/Threshold/THRESHOLD_TEST_MODE` exists and is trusted (root-owned, not group/other-writable), the daemon reads its config from `/Library/Application Support/Threshold/test-config.plist` (same keys as the profile) and ignores managed preferences. If that file is missing, untrusted or not a dictionary, the run ends with `CONFIG ERROR: test mode: test-config.plist missing or untrusted` (no fallback). An untrusted marker is ignored with a logged warning.

**Never create the marker on a production Mac.** Test mode is loud: the daemon logs `TEST MODE: ...` at error level on every run, `results.json` and `threshold check` carry `"testMode": true`, and the extension attribute reports `TEST MODE: <overall>`.

`/Library/Application Support/Threshold/THRESHOLD_ALLOW_UNSIGNED` is test-only too. When that marker exists and is trusted, a `cachedPackage` item with `teamID` `UNSIGNED00` skips the signature check (the `sha256` must still match), so the end-to-end tests can use unsigned fixture packages. **Never create it on a production Mac**: it turns off the package signature check for any item an admin configures that way.

## Before fleet rollout

- [ ] Build once with `SIGN_IDENTITY`, `INSTALLER_IDENTITY` and `NOTARY_PROFILE` set, and confirm the package passes Gatekeeper: `spctl -a -vv -t install build/Threshold-<version>.pkg` reports `accepted` and `source=Notarized Developer ID`.
- [ ] On one real Jamf-enrolled Mac with the configuration profile installed, run `sudo "/Library/Application Support/Threshold/threshold" check` and confirm `testMode` is `false` and `plan` lists the items from the profile. Then restart, log in, and confirm `results.json` shows the same plan (`items`, `skipped`, `upToDate`) and an `overall` you expect.
- [ ] On that Mac, confirm `/usr/local/bin/dialog` and `/usr/local/bin/jamf` pass the trust rules (`ls -ld /usr/local /usr/local/bin`, `ls -l /usr/local/bin/dialog /usr/local/bin/jamf`). If `results.json` says `swiftDialog missing, too old or untrusted`, reinstall swiftDialog (its app bundle must be root-owned).
- [ ] Confirm neither `THRESHOLD_TEST_MODE` nor `THRESHOLD_ALLOW_UNSIGNED` exists in `/Library/Application Support/Threshold/`.

## Uninstall

Run `sudo Packaging/uninstall.sh` (or push it as a Jamf policy script). It stops the daemon, dismisses any Threshold dialog, removes the binary, LaunchDaemon plist, state, results, command files and logs, and forgets the package receipt. It is safe to run when nothing is installed. Remove the configuration profile and EA separately.

## Acknowledgements

Threshold's full-screen blur and progress window are drawn by [swiftDialog](https://github.com/swiftDialog/swiftDialog), created by Bart Reardon and maintained by the swiftDialog project (MIT License, © CSIRO). Threshold doesn't include swiftDialog; install it separately. Thank you to everyone who works on it.

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE). Documentation: [wiki](https://github.com/qlabssoftware/threshold/wiki).
