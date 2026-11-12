import Testing
import Foundation
@testable import ThresholdCore

// MARK: - Test doubles

private struct DialogDown: Error {}

private struct Spec {
    var runsFor: TimeInterval = 10
    var exitCode: Int32 = 0
    var descendant: (TimeInterval) -> Bool? = { _ in false }
    var exitsAfterTerminate: TimeInterval = 0
    /// Descendant process names; overrides `descendant` when set.
    var names: ((TimeInterval) -> [String]?)? = nil
    var exitLag: TimeInterval = 0
}

/// Wires a FakeClock, FakeLauncher and a version reader whose answer changes once an item's install
/// process has run to completion (exited on its own, not terminated).
private final class Harness {
    let clock = FakeClock()
    let dialog = RecordingDialog()
    /// Keyed by item id for installs (installer / jamf policy), by executable for everything else.
    var specs: [String: Spec] = [:]
    /// Version read after a completed install; defaults to the target "2.0".
    var after: [String: InstalledVersion] = [:]
    var untrusted: Set<String> = []
    /// Canonical paths the trust check resolves hooks to (default: unchanged).
    var canonical: [String: String] = [:]
    private(set) var installs: [String: FakeProcess] = [:]
    private(set) var launchTimes: [TimeInterval] = []
    /// Answer of the network re-check (nil = no re-check wired), and the deadlines it was called with.
    var recheckAnswer: Bool?
    private(set) var recheckDeadlines: [TimeInterval] = []
    /// Planner notes by item id.
    var notes: [String: String] = [:]
    /// The status-log reader handed to the Runner (nil = statusLog off).
    var statusLine: (() -> String?)?
    private(set) var statusMarks = 0
    private var origin: Date

    lazy var launcher: FakeLauncher = FakeLauncher { [unowned self] exe, args in self.make(exe, args) }

    init() { origin = clock.now() }

    private func installID(_ exe: String, _ args: [String]) -> String? {
        if exe == "/usr/sbin/installer", args.count == 4 {
            return URL(fileURLWithPath: args[1]).deletingPathExtension().lastPathComponent
        }
        if exe == "/usr/local/bin/jamf", args.count == 3, args[2].hasPrefix("install") {
            return String(args[2].dropFirst("install".count))
        }
        return nil
    }

    private func make(_ exe: String, _ args: [String]) -> FakeProcess {
        launchTimes.append(clock.now().timeIntervalSince(origin))
        let id = installID(exe, args)
        let spec = specs[id ?? exe] ?? Spec()
        let descendant = spec.descendant
        let names = spec.names ?? { t in descendant(t).map { $0 ? ["installer"] : [] } }
        let p = FakeProcess(clock: clock, runsFor: spec.runsFor, exitCode: spec.exitCode, descendantNames: names,
                            exitsAfterTerminate: spec.exitsAfterTerminate, exitLag: spec.exitLag)
        if let id { installs[id] = p }
        return p
    }

    var versions: VersionReading { HarnessVersions(harness: self) }

    func read(_ probe: VersionProbe) -> InstalledVersion {
        guard case let .bundle(path, _) = probe else { return .notInstalled }
        let id = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        if let p = installs[id], !p.isRunning, !p.terminated {
            return after[id] ?? .version(Version("2.0")!)
        }
        return .version(Version("1.0")!)
    }

    var elapsed: TimeInterval { clock.now().timeIntervalSince(origin) }

    func run(_ items: [[String: Any]], global: [String: Any] = [:],
             safety: SafetyResult = SafetyResult(globalBlock: nil, jamfBlock: nil)) throws -> RunOutcome {
        var dict = global
        dict["items"] = items
        let config = try Config.parse(dict)
        #expect(config.invalidItems.isEmpty)
        let plan = config.items.map { PlannedItem(item: $0, installed: Version("1.0")!, note: notes[$0.id]) }
        let (untrusted, canonical) = (self.untrusted, self.canonical)
        var recheck: ((Date) -> Bool)?
        if let answer = recheckAnswer {
            recheck = { [unowned self] until in
                self.recheckDeadlines.append(until.timeIntervalSince(self.origin))
                self.clock.advance(5)
                return answer
            }
        }
        let runner = Runner(config: config, launcher: launcher, clock: clock, versions: versions, dialog: dialog,
                            trustedHookPath: { untrusted.contains($0) ? nil : canonical[$0] ?? $0 },
                            jamfRecheck: recheck,
                            statusLine: statusLine.map { read in { [unowned self] in self.statusMarks += 1; return read } })
        return runner.run(plan, safety: safety)
    }

    var argv: [[String]] { launcher.launches.map { [$0.executable] + $0.arguments } }
}

private struct HarnessVersions: VersionReading {
    let harness: Harness
    func read(_ probe: VersionProbe) -> InstalledVersion { harness.read(probe) }
}

private func pkgItem(_ id: String, _ extra: [String: Any] = [:]) -> [String: Any] {
    var d: [String: Any] = ["id": id, "displayName": "App \(id)", "appPath": "/Applications/\(id).app",
                            "targetVersion": "2.0", "source": "cachedPackage", "packagePath": "/pkg/\(id).pkg",
                            "sha256": String(repeating: "a", count: 64), "teamID": "TEAM123456"]
    d.merge(extra) { _, new in new }
    return d
}
private func jamfItem(_ id: String, _ extra: [String: Any] = [:]) -> [String: Any] {
    var d: [String: Any] = ["id": id, "displayName": "App \(id)", "appPath": "/Applications/\(id).app",
                            "targetVersion": "2.0", "source": "jamfTrigger", "trigger": "install\(id)"]
    d.merge(extra) { _, new in new }
    return d
}
private func installerArgv(_ id: String) -> [String] { ["/usr/sbin/installer", "-pkg", "/pkg/\(id).pkg", "-target", "/"] }
private func jamfArgv(_ id: String) -> [String] { ["/usr/local/bin/jamf", "policy", "-event", "install\(id)"] }

// MARK: - Tests

@Test func cachedSuccess() throws {
    let h = Harness()
    h.specs["a"] = Spec(runsFor: 30)
    let out = try h.run([pkgItem("a")])
    #expect(h.argv == [installerArgv("a")])
    #expect(out.results == [ItemResult(id: "a", displayName: "App a", state: .done, reason: nil, versionBefore: "1.0",
                                       versionAfter: "2.0", durationSeconds: 30, countsAsFailure: false)])
    #expect(out.background.isEmpty)
    #expect(h.dialog.calls == [.blur(["a"]), .update(0, .installing, nil), .update(0, .verifying, nil),
                               .update(0, .done, nil), .finish(true)])
}

@Test func nonZeroExitButVersionOK_isDone() throws {
    let h = Harness()
    h.specs["a"] = Spec(runsFor: 5, exitCode: 1)
    let out = try h.run([pkgItem("a")])
    #expect(out.results[0].state == .done)
    #expect(out.results[0].countsAsFailure == false)
    #expect(out.results[0].versionAfter == "2.0")
    #expect(h.dialog.calls.last == .finish(true))
}

@Test func versionUnchanged_failsAndCounts() throws {
    let h = Harness()
    h.after["a"] = .version(Version("1.0")!)
    let out = try h.run([pkgItem("a")])
    #expect(out.results[0].state == .failed)
    #expect(out.results[0].reason == "version unchanged (1.0)")
    #expect(out.results[0].countsAsFailure == true)
    #expect(out.results[0].versionAfter == "1.0")
    #expect(h.dialog.calls.suffix(2) == [.update(0, .failed, "version unchanged (1.0)"), .finish(false)])
}

@Test func versionNotInstalledAfterInstall_fails() throws {
    let h = Harness()
    h.after["a"] = .notInstalled
    let out = try h.run([pkgItem("a")])
    #expect(out.results[0].state == .failed)
    #expect(out.results[0].reason == "version unchanged (not installed)")
    #expect(out.results[0].versionAfter == nil)
    #expect(out.results[0].countsAsFailure == true)
}

@Test func installLaunchFailure_failsAndCounts() throws {
    let h = Harness()
    h.launcher.failingExecutables = ["/usr/sbin/installer"]
    let out = try h.run([pkgItem("a")])
    #expect(out.results[0].state == .failed)
    #expect(out.results[0].reason?.hasPrefix("launch failed: ") == true)
    #expect(out.results[0].countsAsFailure == true)
}

@Test func jamfWaitingAtCap_isCancelledAndCounted() throws {
    let h = Harness()
    h.specs["a"] = Spec(runsFor: 400, descendant: { _ in false })
    let out = try h.run([jamfItem("a")])
    #expect(h.argv == [jamfArgv("a")])
    #expect(h.installs["a"]?.terminated == true)
    #expect(out.results[0].state == .skipped)
    #expect(out.results[0].reason == "cancelled at cap")
    #expect(out.results[0].countsAsFailure == true)   // a cancelled Jamf wait counts
    #expect(out.background.isEmpty)
    #expect(h.elapsed == 300)
    #expect(h.dialog.calls == [.blur(["a"]), .update(0, .waiting, nil), .update(0, .skipped, "cancelled at cap"),
                               .finish(false)])
}

@Test func jamfInstallingAtCap_isLeftRunning() throws {
    let h = Harness()
    // installer appears at t=10 and vanishes at t=20: installing must stay sticky.
    h.specs["a"] = Spec(runsFor: 900, descendant: { $0 >= 10 && $0 < 20 })
    let out = try h.run([jamfItem("a")])
    let p = try #require(h.installs["a"])
    #expect(p.terminated == false)
    #expect(p.isRunning)
    #expect(out.results[0].state == .stillRunning)
    #expect(out.results[0].countsAsFailure == true)
    #expect(out.background.count == 1)
    #expect(out.background.first?.item.id == "a")
    #expect(out.background.first?.process === p)
    #expect(h.elapsed <= 300)
    #expect(h.dialog.calls == [.blur(["a"]), .update(0, .waiting, nil), .update(0, .installing, nil),
                               .update(0, .stillRunning, nil), .finish(false), .stillRunning("App a")])
}

@Test func unknownDescendant_treatedAsInstalling() throws {
    let h = Harness()
    h.specs["a"] = Spec(runsFor: 900, descendant: { _ in nil })
    let out = try h.run([jamfItem("a")])
    #expect(h.installs["a"]?.terminated == false)
    #expect(out.results[0].state == .stillRunning)
    #expect(out.results[0].countsAsFailure == true)
    #expect(out.background.count == 1)
    #expect(h.dialog.calls.contains(.update(0, .installing, nil)))
}

@Test func hangStopsRemainingItems() throws {
    let h = Harness()
    h.specs["a"] = Spec(runsFor: 100_000)
    let out = try h.run([pkgItem("a"), pkgItem("b"), jamfItem("c")])
    #expect(h.argv == [installerArgv("a")])
    #expect(h.installs["a"]?.terminated == false)
    #expect(out.results.map(\.id) == ["a", "b", "c"])
    #expect(out.results[0].state == .stillRunning)
    #expect(out.results[0].countsAsFailure == true)
    for r in out.results.dropFirst() {
        #expect(r.state == .skipped)
        #expect(r.reason == "not started (cap)")
        #expect(r.countsAsFailure == false)
    }
    #expect(out.background.map(\.item.id) == ["a"])
    #expect(h.elapsed <= 300)
    #expect(h.dialog.calls == [.blur(["a", "b", "c"]), .update(0, .installing, nil), .update(0, .stillRunning, nil),
                               .update(1, .skipped, "not started (cap)"), .update(2, .skipped, "not started (cap)"),
                               .finish(false), .stillRunning("App a")])
}

@Test func itemTimeoutShorterThanCap() throws {
    let h = Harness()
    h.specs["a"] = Spec(runsFor: 1000, descendant: { _ in false })
    h.specs["b"] = Spec(runsFor: 10)
    let out = try h.run([jamfItem("a", ["timeoutSeconds": 60]), pkgItem("b")], global: ["capSeconds": 300])
    #expect(h.argv == [jamfArgv("a"), installerArgv("b")])
    #expect(h.installs["a"]?.terminated == true)
    #expect(out.results[0].state == .skipped)
    #expect(out.results[0].reason == "cancelled at cap")
    #expect(out.results[0].countsAsFailure == true)   // a cancelled Jamf wait counts
    #expect(out.results[0].durationSeconds == 60)
    #expect(h.launchTimes == [0, 60])
    #expect(out.results[1].state == .done)
    #expect(h.elapsed == 70)
}

@Test func dialogLaunchFailure_installsNothing() throws {
    let h = Harness()
    h.dialog.blurError = DialogDown()
    let out = try h.run([pkgItem("a", ["preInstallScript": "/hooks/pre.sh"]), jamfItem("b")])
    #expect(h.launcher.launches.isEmpty)
    #expect(out.results.map(\.state) == [.skipped, .skipped])
    #expect(out.results.allSatisfy { $0.reason == "swiftDialog failed to launch" && !$0.countsAsFailure })
    #expect(out.background.isEmpty)
    #expect(h.dialog.calls == [.blur(["a", "b"])])
}

@Test func globalBlock_skipsAllButShowsBlur() throws {
    let h = Harness()
    let out = try h.run([pkgItem("a"), jamfItem("b")],
                        safety: SafetyResult(globalBlock: "battery below 20%", jamfBlock: nil))
    #expect(h.launcher.launches.isEmpty)
    #expect(out.results.allSatisfy { $0.state == .skipped && $0.reason == "battery below 20%" && !$0.countsAsFailure })
    #expect(h.dialog.calls == [.blur(["a", "b"]), .update(0, .skipped, "battery below 20%"),
                               .update(1, .skipped, "battery below 20%"), .finish(false)])
}

@Test func untrustedPreHook_skipsAndCounts() throws {
    let h = Harness()
    h.untrusted = ["/hooks/pre.sh"]
    let out = try h.run([pkgItem("a", ["preInstallScript": "/hooks/pre.sh"])])
    #expect(h.launcher.launches.isEmpty)
    #expect(out.results[0].state == .skipped)
    #expect(out.results[0].reason == "hook not trusted")
    #expect(out.results[0].countsAsFailure == true)
    #expect(h.dialog.calls == [.blur(["a"]), .update(0, .skipped, "hook not trusted"), .finish(false)])
}

@Test func preHookFailure_skipsAndCounts() throws {
    let h = Harness()
    h.specs["/hooks/pre.sh"] = Spec(runsFor: 1, exitCode: 3)
    let out = try h.run([pkgItem("a", ["preInstallScript": "/hooks/pre.sh"])])
    #expect(h.argv == [["/hooks/pre.sh", "a"]])
    #expect(out.results[0].state == .skipped)
    #expect(out.results[0].reason == "pre-install hook failed")
    #expect(out.results[0].countsAsFailure == true)
}

@Test func preHookTimeoutLimitedByCap_thenLaterItemsNotStarted() throws {
    let h = Harness()
    h.specs["/hooks/pre.sh"] = Spec(runsFor: 1000)
    let out = try h.run([pkgItem("a", ["preInstallScript": "/hooks/pre.sh"]), pkgItem("b")],
                        global: ["capSeconds": 30])
    #expect(h.argv == [["/hooks/pre.sh", "a"]])
    #expect(out.results[0].reason == "pre-install hook failed")
    #expect(out.results[0].countsAsFailure == true)
    #expect(out.results[1].state == .skipped)
    #expect(out.results[1].reason == "not started (cap)")
    #expect(out.results[1].countsAsFailure == false)
    #expect(h.elapsed >= 30 && h.elapsed < 31)
}

@Test func preHookTimeoutBoundedByItemTimeout() throws {
    let h = Harness()
    h.specs["/hooks/pre.sh"] = Spec(runsFor: 15)
    let out = try h.run([pkgItem("a", ["preInstallScript": "/hooks/pre.sh", "timeoutSeconds": 10]), pkgItem("b")],
                        global: ["capSeconds": 300])
    #expect(h.argv == [["/hooks/pre.sh", "a"], installerArgv("b")])
    #expect(out.results[0].state == .skipped)
    #expect(out.results[0].reason == "pre-install hook failed")
    #expect(out.results[0].countsAsFailure == true)
    #expect(h.launchTimes[1] >= 10 && h.launchTimes[1] < 11)  // hook killed at the item timeout, not at 120 s
    #expect(out.results[1].state == .done)
}

@Test func preHookOutlastingItemTimeout_installNotLaunched() throws {
    let h = Harness()
    // Hook exits successfully exactly at the item deadline.
    h.specs["/hooks/pre.sh"] = Spec(runsFor: 10)
    let out = try h.run([pkgItem("a", ["preInstallScript": "/hooks/pre.sh", "timeoutSeconds": 10]), pkgItem("b")],
                        global: ["capSeconds": 300])
    #expect(h.argv == [["/hooks/pre.sh", "a"], installerArgv("b")])
    #expect(out.results[0].state == .skipped)
    #expect(out.results[0].reason == "pre-install hook exceeded item timeout")
    #expect(out.results[0].countsAsFailure == true)
    #expect(out.results[1].state == .done)
}

@Test func emptyPlan_showsNothing() throws {
    let h = Harness()
    let config = try Config.parse([:])
    let runner = Runner(config: config, launcher: h.launcher, clock: h.clock, versions: h.versions,
                        dialog: h.dialog, trustedHookPath: { $0 })
    let out = runner.run([], safety: SafetyResult(globalBlock: nil, jamfBlock: nil))
    #expect(out.results.isEmpty)
    #expect(out.background.isEmpty)
    #expect(h.dialog.calls.isEmpty)
    #expect(h.launcher.launches.isEmpty)
}

@Test func cancelledJamfIsAwaitedBeforeNextItem() throws {
    let h = Harness()
    h.specs["a"] = Spec(runsFor: 1000, descendant: { _ in false }, exitsAfterTerminate: 3)
    h.specs["b"] = Spec(runsFor: 10)
    let out = try h.run([jamfItem("a", ["timeoutSeconds": 60]), pkgItem("b")], global: ["capSeconds": 300])
    let a = try #require(h.installs["a"])
    #expect(a.terminated && !a.isRunning)
    #expect(out.results[0].state == .skipped)
    #expect(out.results[0].reason == "cancelled at cap")
    #expect(out.results[0].countsAsFailure == true)   // a cancelled Jamf wait counts
    // terminated at t=60, exited at t=63: b must not launch before a is gone.
    #expect(h.launchTimes == [0, 63])
    #expect(out.results[1].state == .done)
    #expect(out.background.isEmpty)
}

@Test func cancelledJamfThatNeverExits_isStillRunning() throws {
    let h = Harness()
    h.specs["a"] = Spec(runsFor: 100_000, descendant: { _ in false }, exitsAfterTerminate: .infinity)
    let out = try h.run([jamfItem("a", ["timeoutSeconds": 60]), pkgItem("b")], global: ["capSeconds": 300])
    #expect(h.argv == [jamfArgv("a")])
    #expect(h.installs["a"]?.isRunning == true)
    #expect(out.results[0].state == .stillRunning)
    #expect(out.results[0].countsAsFailure == true)
    #expect(out.background.map(\.item.id) == ["a"])
    #expect(out.results[1].reason == "not started (cap)")
    #expect(h.elapsed >= 66 && h.elapsed < 67)
    #expect(h.dialog.calls.suffix(4) == [.update(0, .stillRunning, nil), .update(1, .skipped, "not started (cap)"),
                                         .finish(false), .stillRunning("App a")])
}

@Test func installerAppearsWhileAwaitingCancel_isStillRunning() throws {
    let h = Harness()
    // Terminated at t=300; installer shows up at t=302 while we wait for exit.
    h.specs["a"] = Spec(runsFor: 100_000, descendant: { $0 >= 302 }, exitsAfterTerminate: 4)
    let out = try h.run([jamfItem("a"), pkgItem("b")])
    #expect(h.argv == [jamfArgv("a")])
    #expect(out.results[0].state == .stillRunning)
    #expect(out.results[0].reason == nil)
    #expect(out.results[0].countsAsFailure == true)
    #expect(out.background.map(\.item.id) == ["a"])
    #expect(out.results[1].state == .skipped)
    #expect(out.results[1].reason == "not started (cap)")
    #expect(!h.dialog.calls.contains(.update(0, .skipped, "cancelled at cap")))
    #expect(h.dialog.calls.last == .stillRunning("App a"))
}

@Test func postHookFailure_failsWithoutCounting() throws {
    let h = Harness()
    h.specs["/hooks/post.sh"] = Spec(runsFor: 1, exitCode: 1)
    let out = try h.run([pkgItem("a", ["postInstallScript": "/hooks/post.sh"])])
    #expect(h.argv == [installerArgv("a"), ["/hooks/post.sh", "a"]])
    #expect(out.results[0].state == .failed)
    #expect(out.results[0].reason == "post-install hook failed")
    #expect(out.results[0].countsAsFailure == false)
    #expect(out.results[0].versionAfter == "2.0")
    #expect(h.dialog.calls.last == .finish(false))
}

@Test func untrustedPostHook_failsWithoutCounting() throws {
    let h = Harness()
    h.untrusted = ["/hooks/post.sh"]
    let out = try h.run([pkgItem("a", ["postInstallScript": "/hooks/post.sh"])])
    #expect(h.argv == [installerArgv("a")])
    #expect(out.results[0].state == .failed)
    #expect(out.results[0].reason == "post-install hook not trusted")
    #expect(out.results[0].countsAsFailure == false)
}

@Test func healthFailure_failsAndCounts() throws {
    let h = Harness()
    h.specs["/usr/bin/pgrep"] = Spec(runsFor: 1, exitCode: 1)
    let out = try h.run([pkgItem("a", ["healthProcess": "VPNAgent",
                                       "healthURL": "https://example.com/ping"])])
    #expect(h.argv == [installerArgv("a"), ["/usr/bin/pgrep", "-x", "VPNAgent"]])
    #expect(out.results[0].state == .failed)
    #expect(out.results[0].reason == "health check failed: process")
    #expect(out.results[0].countsAsFailure == true)
    #expect(h.dialog.calls.contains(.update(0, .healthCheck, nil)))
}

@Test func healthAllChecksPass_inOrder() throws {
    let h = Harness()
    let out = try h.run([pkgItem("a", ["healthProcess": "VPNAgent",
                                       "healthCommand": "vpnutil status", "healthURL": "https://example.com/ping"])])
    #expect(h.argv == [installerArgv("a"), ["/usr/bin/pgrep", "-x", "VPNAgent"], ["/bin/sh", "-c", "vpnutil status"],
                       ["/usr/bin/curl", "-sS", "-o", "/dev/null", "-m", "10", "https://example.com/ping"]])
    #expect(out.results[0].state == .done)
    #expect(out.results[0].reason == nil)
}

@Test func healthRunsWheneverAHealthKeyIsSet() throws {
    let h = Harness()
    let out = try h.run([pkgItem("a", ["healthProcess": "VPNAgent"])])
    #expect(h.argv == [installerArgv("a"), ["/usr/bin/pgrep", "-x", "VPNAgent"]])
    #expect(out.results[0].state == .done)
}

@Test func noHealthKeysMeansNoHealthCheck() throws {
    let h = Harness()
    let out = try h.run([pkgItem("a")])
    #expect(h.argv == [installerArgv("a")])
    #expect(out.results[0].state == .done)
}

@Test func healthHungCommand_failsWithinBudget() throws {
    let h = Harness()
    h.specs["/bin/sh"] = Spec(runsFor: 10_000)
    let out = try h.run([pkgItem("a", ["healthCommand": "sleep 9999"])],
                        global: [:])
    #expect(out.results[0].reason == "health check failed: command")
    #expect(out.results[0].countsAsFailure == true)
    // install 10 s + health budget 60 s (+ polling slack)
    #expect(h.elapsed >= 70 && h.elapsed < 71)
}

@Test func healthSkippedWhenNoTimeLeft() throws {
    let h = Harness()
    h.specs["a"] = Spec(runsFor: 30)
    let out = try h.run([pkgItem("a", ["healthProcess": "VPNAgent"])],
                        global: ["capSeconds": 30])
    #expect(h.argv == [installerArgv("a")])
    #expect(out.results[0].state == .done)
    #expect(out.results[0].reason == "health not checked (cap)")
    #expect(out.results[0].countsAsFailure == false)
}

@Test func jamfBlock_skipsOnlyJamfItems() throws {
    let h = Harness()
    let out = try h.run([jamfItem("a"), pkgItem("b")],
                        safety: SafetyResult(globalBlock: nil, jamfBlock: "Jamf Pro server unreachable"))
    #expect(h.argv == [installerArgv("b")])
    #expect(out.results[0].state == .skipped)
    #expect(out.results[0].reason == "Jamf Pro server unreachable")
    #expect(out.results[0].countsAsFailure == false)
    #expect(out.results[1].state == .done)
    #expect(h.dialog.calls.prefix(2) == [.blur(["a", "b"]), .update(0, .skipped, "Jamf Pro server unreachable")])
    #expect(h.dialog.calls.last == .finish(false))
}

@Test func deadlineMeasuredFromRunStart() throws {
    let h = Harness()
    h.clock.advance(1000)
    h.specs["a"] = Spec(runsFor: 200)
    let out = try h.run([pkgItem("a")], global: ["capSeconds": 300])
    #expect(h.installs["a"]?.terminated == false)
    #expect(out.results[0].state == .done)
    #expect(out.results[0].durationSeconds == 200)
    #expect(out.background.isEmpty)
}

// MARK: - Jamf "installing" rule

@Test func jamfBenignListIsTheDocumentedSet() {
    #expect(Runner.jamfBenignDescendants == ["curl", "jamfAgent", "sleep", "logger", "jamfHelper"])
}

@Test func jamfNonBenignDescendant_isInstallingAndNeverTerminated() throws {
    let h = Harness()
    // A policy installing with ditto (no `installer` anywhere) must still count as installing.
    h.specs["a"] = Spec(runsFor: 900, names: { $0 >= 10 ? ["curl", "ditto"] : ["curl"] })
    let out = try h.run([jamfItem("a"), pkgItem("b")], global: ["capSeconds": 300])
    let p = try #require(h.installs["a"])
    #expect(!p.terminated)
    #expect(out.results.map(\.state) == [.stillRunning, .skipped])
    #expect(out.background.count == 1)
    #expect(h.dialog.calls.contains(.update(0, .installing, nil)))
}

@Test func jamfOnlyBenignDescendants_isWaitingAndCancelled() throws {
    let h = Harness()
    h.specs["a"] = Spec(runsFor: 400, names: { _ in ["curl", "jamfAgent", "sleep", "logger", "jamfHelper"] })
    let out = try h.run([jamfItem("a")], global: ["capSeconds": 300])
    #expect(h.installs["a"]?.terminated == true)
    #expect(out.results[0].state == .skipped)
    #expect(out.results[0].reason == "cancelled at cap")
    #expect(out.results[0].countsAsFailure == true)   // a cancelled Jamf wait counts
    #expect(!h.dialog.calls.contains(.update(0, .installing, nil)))
}

@Test func jamfUnknownDescendants_isInstalling() throws {
    let h = Harness()
    h.specs["a"] = Spec(runsFor: 900, names: { _ in nil })
    let out = try h.run([jamfItem("a")], global: ["capSeconds": 300])
    #expect(h.installs["a"]?.terminated == false)
    #expect(out.results[0].state == .stillRunning)
}

@Test func nonBenignDescendantDuringCancelWait_isStillRunning() throws {
    let h = Harness()
    h.specs["a"] = Spec(runsFor: 100_000, exitsAfterTerminate: 4, names: { $0 >= 302 ? ["softwareupdate"] : [] })
    let out = try h.run([jamfItem("a")], global: ["capSeconds": 300])
    #expect(out.results[0].state == .stillRunning)
}

@Test func cancelRace_rootExitingWithLaggedIsRunning_isCleanExit() throws {
    let h = Harness()
    // After SIGTERM the root exits at once, but isRunning lags (as SystemProcess does) and the
    // descendant listing is unknown meanwhile: that is a clean exit, not an install.
    h.specs["a"] = Spec(runsFor: 100_000, exitsAfterTerminate: 0, names: { _ in [] }, exitLag: 0.8)
    let out = try h.run([jamfItem("a"), pkgItem("b")], global: ["capSeconds": 300])
    #expect(out.results[0].state == .skipped)
    #expect(out.results[0].reason == "cancelled at cap")
    #expect(out.background.isEmpty)
}

@Test func cancelUnknownWhileRootStillRunning_isStillRunning() throws {
    let h = Harness()
    h.specs["a"] = Spec(runsFor: 100_000, exitsAfterTerminate: .infinity, names: { $0 > 300 ? nil : [] })
    let out = try h.run([jamfItem("a")], global: ["capSeconds": 300])
    #expect(out.results[0].state == .stillRunning)
    #expect(out.background.count == 1)
}

// MARK: - Canonical paths

@Test func hooksRunViaTheCanonicalTrustCheckedPath() throws {
    let h = Harness()
    h.canonical = ["/hooks/pre.sh": "/private/hooks/pre.sh", "/hooks/post.sh": "/private/hooks/post.sh"]
    let out = try h.run([pkgItem("a", ["preInstallScript": "/hooks/pre.sh", "postInstallScript": "/hooks/post.sh"])])
    #expect(out.results[0].state == .done)
    #expect(h.argv == [["/private/hooks/pre.sh", "a"], installerArgv("a"), ["/private/hooks/post.sh", "a"]])
}


// MARK: - Network wait and fallback note

private let unreachable = SafetyResult(globalBlock: nil, jamfBlock: "Jamf Pro server unreachable", jamfRetryable: true)

@Test func networkRecheckSucceedsThenJamfItemsInstall() throws {
    let h = Harness()
    h.recheckAnswer = true
    let out = try h.run([pkgItem("b"), jamfItem("a"), jamfItem("c")], global: ["capSeconds": 300], safety: unreachable)
    #expect(out.results.map(\.state) == [.done, .done, .done])
    #expect(h.argv == [installerArgv("b"), jamfArgv("a"), jamfArgv("c")])
    #expect(h.recheckDeadlines.count == 1)                        // once per run, not per item
    #expect(h.dialog.calls.contains(.update(1, .waiting, "Waiting for network")))
}

@Test func networkRecheckDeadlineIsNetworkWaitFromNow() throws {
    let h = Harness()
    h.recheckAnswer = false
    _ = try h.run([jamfItem("a")], global: ["capSeconds": 300, "networkWaitSeconds": 45], safety: unreachable)
    #expect(h.recheckDeadlines == [45])
}

@Test func networkRecheckDeadlineNeverPassesTheCap() throws {
    let h = Harness()
    h.recheckAnswer = false
    h.specs["b"] = Spec(runsFor: 50)
    _ = try h.run([pkgItem("b"), jamfItem("a")], global: ["capSeconds": 60, "networkWaitSeconds": 30], safety: unreachable)
    #expect(h.recheckDeadlines == [60])
}

@Test func networkRecheckFailsSoJamfItemsSkipWithoutCounting() throws {
    let h = Harness()
    h.recheckAnswer = false
    let out = try h.run([jamfItem("a"), pkgItem("b"), jamfItem("c")], safety: unreachable)
    #expect(out.results.map(\.state) == [.skipped, .done, .skipped])
    #expect(out.results[0].reason == "Jamf Pro server unreachable")
    #expect(out.results[2].reason == "Jamf Pro server unreachable")
    #expect(out.results.allSatisfy { !$0.countsAsFailure })
    #expect(h.recheckDeadlines.count == 1)
    #expect(h.argv == [installerArgv("b")])
}

@Test func noRecheckWhenNotRetryableOrDisabled() throws {
    let untrusted = SafetyResult(globalBlock: nil, jamfBlock: "jamf binary missing or untrusted", jamfRetryable: false)
    let h1 = Harness()
    h1.recheckAnswer = true
    let out1 = try h1.run([jamfItem("a")], safety: untrusted)
    #expect(out1.results[0].state == .skipped && h1.recheckDeadlines.isEmpty)

    let h2 = Harness()
    h2.recheckAnswer = true
    let out2 = try h2.run([jamfItem("a")], global: ["networkWaitSeconds": 0], safety: unreachable)
    #expect(out2.results[0].state == .skipped && h2.recheckDeadlines.isEmpty)
}

@Test func plannerNoteBecomesTheReasonOfAnOtherwiseCleanResult() throws {
    let h = Harness()
    h.notes["a"] = "cached package missing; used fallback trigger"
    let out = try h.run([jamfItem("a")])
    #expect(out.results[0].state == .done)
    #expect(out.results[0].reason == "cached package missing; used fallback trigger")
}

@Test func statusLogLineIsShownWhileInstallingAndOnlyWhenItChanges() throws {
    let h = Harness()
    h.specs["a"] = Spec(runsFor: 6)
    let start = h.clock.now()
    h.statusLine = {
        let t = h.clock.now().timeIntervalSince(start)
        return t < 3 ? "Extracting files" : "Running package scripts"
    }
    let out = try h.run([pkgItem("a")])
    #expect(out.results.map(\.state) == [.done])
    #expect(h.dialog.calls == [.blur(["a"]), .update(0, .installing, nil),
                               .update(0, .installing, "Extracting files"),
                               .update(0, .installing, "Running package scripts"),
                               .update(0, .verifying, nil), .update(0, .done, nil), .finish(true)])
}

@Test func statusLogStartsOverWhenAWaitingPolicyStartsInstalling() throws {
    let h = Harness()
    h.specs["j"] = Spec(runsFor: 6, descendant: { $0 >= 3 })
    h.statusLine = { "jamf: Executing Policy" }
    _ = try h.run([jamfItem("j")])
    let updates = h.dialog.calls.filter { if case .update = $0 { return true }; return false }
    #expect(Array(updates.prefix(4)) == [.update(0, .waiting, nil), .update(0, .waiting, "jamf: Executing Policy"),
                                         .update(0, .installing, nil), .update(0, .installing, "jamf: Executing Policy")])
}

@Test func statusLogIsMarkedOncePerInstall() throws {
    let h = Harness()
    h.specs["a"] = Spec(runsFor: 3); h.specs["b"] = Spec(runsFor: 3)
    h.statusLine = { nil }
    _ = try h.run([pkgItem("a"), pkgItem("b")])
    #expect(h.statusMarks == 2)
}
