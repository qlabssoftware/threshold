import Testing
import Foundation
@testable import ThresholdCore

// MARK: - Test doubles

private let sha = String(repeating: "a", count: 64)

private func cachedItem(_ id: String) -> [String: Any] {
    ["id": id, "appPath": "/Applications/\(id).app", "targetVersion": "2.0", "source": "cachedPackage",
     "packagePath": "/Library/Caches/\(id).pkg", "sha256": sha, "teamID": "ABCDEFGHIJ"]
}

private func jamfItem(_ id: String) -> [String: Any] {
    ["id": id, "appPath": "/Applications/\(id).app", "targetVersion": "2.0", "source": "jamfTrigger",
     "trigger": "install\(id)"]
}

private struct OKPackages: PackageVerifying {
    func verify(path: String, sha256: String, teamID: String) -> PackageCheck { .ok }
}

private struct MappedPackages: PackageVerifying {
    var byPath: [String: PackageCheck]
    func verify(path: String, sha256: String, teamID: String) -> PackageCheck { byPath[path] ?? .ok }
}

private final class FakeProbe: SystemProbe {
    var status = PowerStatus(onAC: true, batteryPercent: 90)
    var disk = 100.0
    func power() -> PowerStatus { status }
    func freeDiskGB() -> Double { disk }
}

/// Records presenter calls; `onShowBlur` runs at the moment the blur would appear.
private final class LifecyclePresenter: DialogPresenting {
    let uid: uid_t
    private(set) var calls: [String] = []
    var onShowBlur: (() -> Void)?
    var onCloseStillRunning: (() -> Void)?
    init(uid: uid_t) { self.uid = uid }
    func showBlur(items: [Item], global: GlobalConfig) throws {
        onShowBlur?()
        calls.append("blur:" + items.map(\.id).joined(separator: ","))
    }
    func update(index: Int, state: ItemState, detail: String?) { calls.append("update:\(index):\(state.rawValue)") }
    func finish(success: Bool, global: GlobalConfig) { calls.append("finish:\(success)") }
    func showStillRunning(displayName: String) { calls.append("still:\(displayName)") }
    func closeStillRunning() {
        onCloseStillRunning?()
        calls.append("closeStill")
    }
}

private final class World: Platform {
    let fakeClock = FakeClock()
    let dir: URL
    var prefs: [String: Any] = [:]
    /// Console-user answers in order; the last one repeats forever.
    var users: [(name: String, uid: uid_t)?] = [("alice", 501)]
    private(set) var userPolls = 0
    private(set) var userPollTimes: [Date] = []
    /// Runs when the console user script reaches this index.
    var onUserPoll: [Int: () -> Void] = [:]
    var boot = "boot-1"
    var uptime: TimeInterval = 60
    var files: Set<String> = ["/usr/local/bin/dialog", "/usr/local/bin/jamf"]
    /// Executables that exist but fail the trust check, and where trusted symlinks resolve to.
    var untrustedExecutables: Set<String> = []
    var resolvedExecutables: [String: String] = [:]
    private(set) var presenterGlobals: [GlobalConfig] = []
    var dialogVersion = "2.5.2.4777"
    var dialogVersionRunsFor: TimeInterval = 0
    var installed: [String: InstalledVersion] = [:]
    var afterInstall: [String: InstalledVersion] = [:]
    var installRunsFor: [String: TimeInterval] = [:]
    var installDescendant: [String: Bool?] = [:]
    var jamfConnectionExit: Int32 = 0
    /// When non-empty, the Nth checkJSSConnection exits with this[N] (the last value repeats).
    var jamfConnectionSequence: [Int32] = []
    private(set) var jamfConnectionChecks = 0
    var packageChecks: [String: PackageCheck] = [:]
    private(set) var installs: [String: FakeProcess] = [:]
    private(set) var versionReads = 0
    private(set) var presenters: [LifecyclePresenter] = []
    private(set) var detached: [(String, [String])] = []
    private(set) var staleKills = 0
    var configurePresenter: ((LifecyclePresenter) -> Void)?
    let fakeProbe = FakeProbe()

    init() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lifecycle-\(UUID().uuidString)")
    }

    lazy var fakeLauncher: FakeLauncher = FakeLauncher { [unowned self] exe, args in self.make(exe, args) }

    private func make(_ exe: String, _ args: [String]) -> FakeProcess {
        if exe == "/usr/sbin/installer" {
            let id = URL(fileURLWithPath: args[1]).deletingPathExtension().lastPathComponent
            return track(id)
        }
        if exe.hasSuffix("/jamf"), args.first == "policy" {
            return track(String(args[2].dropFirst("install".count)))
        }
        if exe.hasSuffix("/jamf"), args.first == "checkJSSConnection" {
            defer { jamfConnectionChecks += 1 }
            let code = jamfConnectionSequence.isEmpty ? jamfConnectionExit
                : jamfConnectionSequence[min(jamfConnectionChecks, jamfConnectionSequence.count - 1)]
            return FakeProcess(clock: fakeClock, runsFor: 1, exitCode: code)
        }
        if args == ["--version"] {
            return FakeProcess(clock: fakeClock, runsFor: dialogVersionRunsFor, output: dialogVersion + "\n")
        }
        return FakeProcess(clock: fakeClock, runsFor: 0)
    }

    private func track(_ id: String) -> FakeProcess {
        let p = FakeProcess(clock: fakeClock, runsFor: installRunsFor[id] ?? 10,
                            descendant: installDescendant[id] ?? false)
        installs[id] = p
        return p
    }

    fileprivate func read(_ probe: VersionProbe) -> InstalledVersion {
        versionReads += 1
        guard case let .bundle(path, _) = probe else { return .notInstalled }
        let id = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        if let p = installs[id], !p.isRunning, !p.terminated {
            return afterInstall[id] ?? .version(Version("2.0")!)
        }
        return installed[id] ?? .version(Version("1.0")!)
    }

    // Platform
    var clock: Clock { fakeClock }
    var launcher: ProcessLauncher { fakeLauncher }
    var probe: SystemProbe { fakeProbe }
    var versions: VersionReading { WorldVersions(world: self) }
    var packages: PackageVerifying { MappedPackages(byPath: packageChecks) }
    var stateStore: StateStore { StateStore(url: dir.appendingPathComponent("state.json")) }
    var resultsWriter: ResultsWriter { ResultsWriter(url: dir.appendingPathComponent("results.json")) }

    func managedPreferences() -> [String: Any] { prefs }

    /// Test-mode plists by path, and paths that fail the trust check.
    var plists: [String: [String: Any]] = [:]
    var untrusted: Set<String> = []
    func configSource() -> ConfigSource {
        ConfigSource.resolve(fileExists: fileExists, isTrusted: { [unowned self] in !self.untrusted.contains($0) },
                             readPlist: { [unowned self] in self.plists[$0] }, managed: managedPreferences)
    }

    func consoleUser() -> (name: String, uid: uid_t)? {
        let index = min(userPolls, users.count - 1)
        onUserPoll[userPolls]?()
        userPolls += 1
        userPollTimes.append(fakeClock.now())
        // Safety net: a test that never yields an eligible user must not hang.
        precondition(userPolls < 10_000, "console user polled forever")
        return users[index]
    }

    func bootSessionUUID() -> String { boot }
    func uptimeSeconds() -> TimeInterval { uptime }
    var os = "26.1"
    func osVersion() -> Version { Version(os)! }
    func fileExists(_ path: String) -> Bool { files.contains(path) }
    func trustedExecutable(_ path: String) -> String? {
        // Like the real resolver, an already-resolved trusted path resolves to itself.
        if resolvedExecutables.values.contains(path) { return path }
        guard files.contains(path), !untrustedExecutables.contains(path) else { return nil }
        return resolvedExecutables[path] ?? path
    }
    func killStaleDialogs() { staleKills += 1 }

    func makePresenter(uid: uid_t, global: GlobalConfig) -> DialogPresenting {
        let p = LifecyclePresenter(uid: uid)
        presenterGlobals.append(global)
        configurePresenter?(p)
        presenters.append(p)
        return p
    }

    func launchDetached(_ executable: String, _ arguments: [String]) throws {
        detached.append((executable, arguments))
    }

    /// "+display", "+system", "-display", "-system", in order.
    private(set) var awake: [String] = []
    /// Called when an assertion is released, with the matching event.
    var onAwakeRelease: ((String) -> Void)?
    func keepAwake(display: Bool, reason: String) -> () -> Void {
        let kind = display ? "display" : "system"
        awake.append("+" + kind)
        var released = false
        return { [unowned self] in
            guard !released else { return }
            released = true
            awake.append("-" + kind)
            onAwakeRelease?("-" + kind)
        }
    }

    // Helpers
    var state: PersistentState { stateStore.load() }

    var report: RunReport? {
        guard let data = try? Data(contentsOf: resultsWriter.url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RunReport.self, from: data)
    }

    func run() -> Int32 {
        Lifecycle(platform: self, log: Log(fileURL: dir.appendingPathComponent("threshold.log"))).run()
    }
}

private struct WorldVersions: VersionReading {
    let world: World
    func read(_ probe: VersionProbe) -> InstalledVersion { world.read(probe) }
}

// MARK: - Test mode

@Test func normalRunReportsTestModeFalse() throws {
    let w = World()
    w.prefs = ["items": []]
    #expect(w.run() == 0)
    #expect(try #require(w.report).testMode == false)
    let text = try String(contentsOf: w.resultsWriter.url, encoding: .utf8)
    #expect(text.contains("\"testMode\" : false"))
}

@Test func testModeUsesTestConfigAndWritesTestModeToResults() throws {
    let w = World()
    w.prefs = ["enabled": true, "items": [cachedItem("managed")]]
    w.files.insert(ConfigSource.testModeMarker)
    w.files.insert(ConfigSource.testConfigPath)
    w.plists[ConfigSource.testConfigPath] = ["enabled": false, "items": [cachedItem("a")]]
    #expect(w.run() == 0)
    let report = try #require(w.report)
    #expect(report.overall == "DISABLED")   // from the file, not managed prefs
    #expect(report.testMode)
    let log = try String(contentsOf: w.dir.appendingPathComponent("threshold.log"), encoding: .utf8)
    #expect(log.contains("ERROR TEST MODE: config from test-config.plist (managed preferences ignored)"))
}

@Test func testModeWithMissingConfigIsConfigErrorNotManagedPrefs() throws {
    let w = World()
    w.prefs = ["items": [cachedItem("managed")]]
    w.files.insert(ConfigSource.testModeMarker)
    #expect(w.run() == 0)
    let report = try #require(w.report)
    #expect(report.overall == "CONFIG ERROR: test mode: test-config.plist missing or untrusted")
    #expect(report.testMode)
    #expect(w.presenters.isEmpty)
}

@Test func untrustedTestModeMarkerUsesManagedPrefs() throws {
    let w = World()
    w.prefs = ["enabled": false]
    w.files.insert(ConfigSource.testModeMarker)
    w.untrusted.insert(ConfigSource.testModeMarker)
    #expect(w.run() == 0)
    let report = try #require(w.report)
    #expect(report.overall == "DISABLED")
    #expect(report.testMode == false)
}

// MARK: - Early exits

@Test func disabledWritesDisabledAndShowsNothing() {
    let w = World()
    w.prefs = ["enabled": false, "items": [cachedItem("a")]]
    #expect(w.run() == 0)
    #expect(w.report?.overall == "DISABLED")
    #expect(w.presenters.isEmpty)
    #expect(w.staleKills == 1)
}

// MARK: - Minimum OS

@Test func belowMinimumOSShowsNothingAndLeavesBootUnhandled() {
    let w = World()
    w.os = "26.1"
    w.prefs = ["minimumOSVersion": "27", "items": [cachedItem("a")]]
    #expect(w.run() == 0)
    #expect(w.report?.overall == "OS BELOW MINIMUM: macOS 26.1 < 27")
    #expect(w.presenters.isEmpty)
    #expect(w.installs.isEmpty)
    #expect(w.versionReads == 0)        // gated before any planning
    #expect(w.state.lastHandledBootSession == nil)
}

@Test func atOrAboveMinimumOSRunsUpdates() {
    for os in ["27.0", "27.2.1", "28.0"] {
        let w = World()
        w.os = os
        w.prefs = ["minimumOSVersion": "27", "items": [cachedItem("a")]]
        #expect(w.run() == 0)
        #expect(w.installs.keys.sorted() == ["a"], "macOS \(os)")
        #expect(w.report?.items.map(\.state) == [.done], "macOS \(os)")
    }
}

@Test func noMinimumOSRunsOnAnyVersion() {
    let w = World()
    w.os = "15.0"
    w.prefs = ["items": [cachedItem("a")]]
    #expect(w.run() == 0)
    #expect(w.installs.keys.sorted() == ["a"])
}

@Test func minimumOSRaisedInLoginConfigShowsNothing() {
    let w = World()
    w.os = "27.0"
    w.prefs = ["items": [cachedItem("a")]]
    w.users = [nil, ("alice", 501)]
    w.onUserPoll[1] = { w.prefs = ["minimumOSVersion": "28", "items": [cachedItem("a")]] }
    #expect(w.run() == 0)
    #expect(w.report?.overall == "OS BELOW MINIMUM: macOS 27.0 < 28")
    #expect(w.presenters.isEmpty)
    #expect(w.installs.isEmpty)
}

@Test func globalConfigErrorWritesConfigError() {
    let w = World()
    w.prefs = ["capSeconds": "lots", "items": [cachedItem("a")]]
    #expect(w.run() == 0)
    let overall = w.report?.overall ?? ""
    #expect(overall.hasPrefix("CONFIG ERROR: "))
    #expect(overall.contains("capSeconds"))
    #expect(w.presenters.isEmpty)
}

@Test func alreadyHandledBootExitsWithoutPlanning() throws {
    let w = World()
    w.prefs = ["items": [cachedItem("a")]]
    var s = PersistentState()
    s.lastHandledBootSession = "boot-1"
    try w.stateStore.save(s)
    #expect(w.run() == 0)
    #expect(w.versionReads == 0)
    #expect(w.presenters.isEmpty)
    #expect(w.report == nil)
}

@Test func existingSessionLongAfterBootMarksHandledWithoutBlur() {
    let w = World()
    w.prefs = ["items": [cachedItem("a")]]
    w.uptime = 3600
    #expect(w.run() == 0)
    #expect(w.state.lastHandledBootSession == "boot-1")
    #expect(w.presenters.isEmpty)
    #expect(w.report == nil)
    #expect(w.installs.isEmpty)
}

@Test func existingSessionRightAfterBootProceeds() {
    let w = World()
    w.prefs = ["items": [cachedItem("a")]]
    w.uptime = 120
    #expect(w.run() == 0)
    #expect(w.presenters.count == 1)
    #expect(w.report?.items.map(\.state) == [.done])
}

@Test func nothingToDoAtBootWritesOKAndMarksHandled() {
    let w = World()
    w.prefs = ["items": [cachedItem("a")]]
    w.installed["a"] = .version(Version("2.0")!)
    w.users = [nil]
    #expect(w.run() == 0)
    #expect(w.report?.overall == "OK")
    #expect(w.report?.upToDate == ["a"])
    #expect(w.state.lastHandledBootSession == "boot-1")
    #expect(w.presenters.isEmpty)
    // Never waited for a login: the clock never ticked.
    #expect(w.fakeClock.now() == Date(timeIntervalSince1970: 1_000_000))
}

@Test func waitsPastIgnoredUserForEligibleOne() {
    let w = World()
    w.prefs = ["ignoredUsers": ["admin"], "items": [cachedItem("a")]]
    w.users = [nil, ("loginwindow", 0), ("admin", 502), ("admin", 502), ("bob", 503)]
    #expect(w.run() == 0)
    #expect(w.presenters.map(\.uid) == [503])
    #expect(w.report?.user == "bob")
    // The login poll ticks once a second on the injected clock.
    let gaps = zip(w.userPollTimes.dropFirst(2), w.userPollTimes.dropFirst(1)).map { $0.timeIntervalSince($1) }
    #expect(gaps.allSatisfy { $0 == 1 })
}

@Test func bootIsSavedAsHandledBeforeBlurAppears() {
    let w = World()
    w.prefs = ["items": [cachedItem("a")]]
    w.users = [nil, ("alice", 501)]
    var savedAtBlur: String??
    w.configurePresenter = { p in p.onShowBlur = { savedAtBlur = w.state.lastHandledBootSession } }
    #expect(w.run() == 0)
    #expect(savedAtBlur == .some("boot-1"))
}

@Test func workGoneAtLoginShowsNothing() {
    let w = World()
    w.prefs = ["items": [cachedItem("a")]]
    w.users = [nil, nil, ("alice", 501)]
    w.onUserPoll[2] = { w.installed["a"] = .version(Version("2.0")!) }
    #expect(w.run() == 0)
    #expect(w.presenters.isEmpty)
    #expect(w.state.lastHandledBootSession == "boot-1")
    #expect(w.report?.overall == "OK")
    #expect(w.report?.upToDate == ["a"])
}

@Test func missingSwiftDialogSkipsEverything() {
    let w = World()
    w.prefs = ["items": [cachedItem("a"), cachedItem("b")]]
    w.files.remove("/usr/local/bin/dialog")
    #expect(w.run() == 0)
    #expect(w.presenters.isEmpty)
    #expect(w.installs.isEmpty)
    #expect(w.report?.items.map(\.state) == [.skipped, .skipped])
    #expect(w.report?.items.allSatisfy { $0.reason == "swiftDialog missing or untrusted" } == true)
    #expect(w.report?.overall == "BLOCKED: swiftDialog missing or untrusted")
    #expect(w.report?.items.allSatisfy { !$0.countsAsFailure } == true)
    #expect(w.state.failures.isEmpty)
    #expect(w.state.lastHandledBootSession == "boot-1")
}

@Test func oldSwiftDialogSkipsEverything() {
    let w = World()
    w.prefs = ["items": [cachedItem("a")]]
    w.dialogVersion = "2.4.9"
    #expect(w.run() == 0)
    #expect(w.presenters.isEmpty)
    #expect(w.report?.items.first?.reason == "swiftDialog 2.4.9 older than 2.5.0")
    #expect(w.report?.overall == "BLOCKED: swiftDialog 2.4.9 older than 2.5.0")
}

@Test func slowSwiftDialogAtLoginStillInstalls() {
    // Field case: swiftDialog 3.0.1 took > 10 s to answer `--version` right after login.
    let w = World()
    w.prefs = ["items": [cachedItem("a")]]
    w.dialogVersionRunsFor = 25
    #expect(w.run() == 0)
    #expect(w.report?.items.map(\.state) == [.done])
    #expect(w.report?.overall == "OK")
}

@Test func hungSwiftDialogExplainsWhy() {
    let w = World()
    w.prefs = ["items": [cachedItem("a")]]
    w.dialogVersionRunsFor = 1_000
    #expect(w.run() == 0)
    #expect(w.presenters.isEmpty)
    #expect(w.installs.isEmpty)
    #expect(w.report?.items.first?.reason == "swiftDialog version check failed (timed out after 60s)")
    #expect(w.report?.overall == "BLOCKED: swiftDialog version check failed (timed out after 60s)")
    #expect(w.state.failures.isEmpty)
}

@Test func untrustedSwiftDialogIsNeverExecuted() {
    let w = World()
    w.prefs = ["items": [cachedItem("a")]]
    w.untrustedExecutables = ["/usr/local/bin/dialog"]
    #expect(w.run() == 0)
    #expect(w.presenters.isEmpty)
    #expect(w.installs.isEmpty)
    #expect(w.fakeLauncher.launches.isEmpty)   // not even `dialog --version`
    #expect(w.report?.items.map(\.state) == [.skipped])
    #expect(w.report?.items.first?.reason == "swiftDialog missing or untrusted")
    #expect(w.report?.overall == "BLOCKED: swiftDialog missing or untrusted")
    #expect(w.state.failures.isEmpty)
}

@Test func symlinkedSwiftDialogRunsResolvedPath() throws {
    let w = World()
    w.prefs = ["items": [cachedItem("a")]]
    let real = "/Library/Application Support/Dialog/Dialog.app/Contents/MacOS/dialogcli"
    w.resolvedExecutables["/usr/local/bin/dialog"] = real
    #expect(w.run() == 0)
    let version = try #require(w.fakeLauncher.launches.first { $0.arguments == ["--version"] })
    #expect(version.executable == real)
    #expect(w.presenterGlobals.map(\.swiftDialogPath) == [real])
    #expect(w.report?.items.map(\.state) == [.done])
}

@Test func untrustedJamfBlocksJamfItemsAndRecon() {
    let w = World()
    w.prefs = ["items": [jamfItem("j"), cachedItem("a")]]
    w.untrustedExecutables = ["/usr/local/bin/jamf"]
    #expect(w.run() == 0)
    #expect(w.report?.items.map(\.state) == [.skipped, .done])
    #expect(w.report?.items.first?.reason == "jamf binary missing or untrusted")
    #expect(!w.fakeLauncher.launches.contains { $0.executable.hasSuffix("/jamf") })
    #expect(w.detached.isEmpty)   // no recon through an untrusted binary
}

@Test func symlinkedJamfRunsResolvedPathForPolicyAndRecon() {
    let w = World()
    w.prefs = ["items": [jamfItem("j")]]
    let real = "/usr/local/jamf/bin/jamf"
    w.resolvedExecutables["/usr/local/bin/jamf"] = real
    #expect(w.run() == 0)
    #expect(w.report?.items.map(\.state) == [.done])
    let jamfLaunches = w.fakeLauncher.launches.filter { $0.executable.hasSuffix("/jamf") }
    #expect(jamfLaunches.map(\.executable) == [real, real])   // checkJSSConnection, policy
    #expect(w.detached.map(\.0) == [real])
}

@Test func safetyBlockingEverythingShowsNoBlur() {
    let w = World()
    w.prefs = ["items": [cachedItem("a")]]
    w.fakeProbe.disk = 1
    #expect(w.run() == 0)
    #expect(w.presenters.isEmpty)
    #expect(w.report?.items.map(\.state) == [.skipped])
    #expect(w.report?.items.first?.reason == "less than 5 GB free disk")
    #expect(w.report?.overall == "BLOCKED: less than 5 GB free disk")
    #expect(w.state.failures.isEmpty)
}

@Test func batteryBlockWithQuarantineListsBothSegments() throws {
    let w = World()
    w.prefs = ["items": [cachedItem("a"), cachedItem("q")]]
    w.fakeProbe.status = PowerStatus(onAC: false, batteryPercent: 10)
    var s = PersistentState()
    s.failures["q"] = FailureRecord(targetVersion: "2.0", count: 3)
    try w.stateStore.save(s)
    #expect(w.run() == 0)
    #expect(w.presenters.isEmpty)
    #expect(w.report?.overall == "BLOCKED: battery below 20%; QUARANTINED: q")
}

@Test func unreadableUptimeWithUserPresentNeverBlurs() {
    let w = World()
    w.prefs = ["items": [cachedItem("a")]]
    w.uptime = .infinity
    #expect(w.run() == 0)
    #expect(w.state.lastHandledBootSession == "boot-1")
    #expect(w.presenters.isEmpty)
    #expect(w.installs.isEmpty)
}

@Test func unknownBootSessionDoesNothing() {
    let w = World()
    w.prefs = ["items": [cachedItem("a")]]
    w.boot = ""
    w.users = [nil, ("alice", 501)]
    #expect(w.run() == 0)
    #expect(w.report?.overall == "ERROR: boot session unknown")
    #expect(w.state.lastHandledBootSession == nil)
    #expect(w.presenters.isEmpty)
    #expect(w.versionReads == 0)
}

// MARK: - Runs

@Test func happyPathInstallsRecordsAndRecons() throws {
    let w = World()
    w.prefs = ["items": [cachedItem("a"), cachedItem("b")]]
    w.afterInstall["b"] = .version(Version("1.0")!)
    var s = PersistentState()
    s.failures["a"] = FailureRecord(targetVersion: "2.0", count: 2)
    try w.stateStore.save(s)

    #expect(w.run() == 0)
    #expect(w.presenters.count == 1)
    #expect(w.presenters[0].uid == 501)
    let report = try #require(w.report)
    #expect(report.items.map(\.state) == [.done, .failed])
    #expect(report.overall == "FAILED: b")
    #expect(report.user == "alice")
    #expect(report.bootSession == "boot-1")
    #expect(w.state.failures["a"] == nil)
    #expect(w.state.failures["b"] == FailureRecord(targetVersion: "2.0", count: 1))
    #expect(w.detached.map(\.0) == ["/usr/local/bin/jamf"])
    #expect(w.detached.map(\.1) == [["recon"]])
}

@Test func noReconWithoutJamfBinary() {
    let w = World()
    w.prefs = ["items": [cachedItem("a")]]
    w.files.remove("/usr/local/bin/jamf")
    #expect(w.run() == 0)
    #expect(w.report?.items.map(\.state) == [.done])
    #expect(w.detached.isEmpty)
}

@Test func noReconWhenNothingDone() {
    let w = World()
    w.prefs = ["items": [cachedItem("a")]]
    w.afterInstall["a"] = .version(Version("1.0")!)
    #expect(w.run() == 0)
    #expect(w.detached.isEmpty)
}

@Test func quarantinedItemsAppearInOverall() throws {
    let w = World()
    w.prefs = ["items": [cachedItem("a"), cachedItem("q")]]
    var s = PersistentState()
    s.failures["q"] = FailureRecord(targetVersion: "2.0", count: 3)
    try w.stateStore.save(s)
    #expect(w.run() == 0)
    #expect(w.report?.overall == "QUARANTINED: q")
}

@Test func stillRunningInstallIsMonitoredToCompletion() throws {
    let w = World()
    w.prefs = ["capSeconds": 300, "items": [cachedItem("a")]]
    w.installRunsFor["a"] = 1000
    w.installDescendant["a"] = true
    var stateAtClose: PersistentState?
    var reportAtClose: RunReport?
    var timeAtClose: Date?
    var installExitAt: Date?
    var reconCountAtClose: Int?
    w.configurePresenter = { p in
        p.onCloseStillRunning = {
            stateAtClose = w.state; reportAtClose = w.report; timeAtClose = w.fakeClock.now()
            reconCountAtClose = w.detached.count
            // The install was launched `elapsed` seconds ago and runs for 1000 s.
            if let install = w.installs["a"] {
                installExitAt = w.fakeClock.now().addingTimeInterval(1000 - install.elapsed)
            }
        }
    }

    #expect(w.run() == 0)
    let p = try #require(w.presenters.first)
    #expect(p.calls.contains("still:a"))
    #expect(p.calls.last == "closeStill")
    let install = try #require(w.installs["a"])
    #expect(!install.isRunning)
    #expect(!install.terminated)
    // Polled every 5 s: noticed within one poll of the real exit.
    let ended = install.elapsed
    #expect(ended >= 1000 && ended < 1005)
    let closeAt = try #require(timeAtClose)
    let exitAt = try #require(installExitAt)
    #expect(closeAt >= exitAt && closeAt <= exitAt.addingTimeInterval(5))
    // Recon waits for the background install, so inventory sees the final version.
    #expect(reconCountAtClose == 0)
    #expect(reportAtClose?.items.map(\.state) == [.done])
    #expect(reportAtClose?.items.first?.versionAfter == "2.0")
    #expect(reportAtClose?.overall == "OK")
    #expect(stateAtClose?.failures["a"] == nil)
    #expect(w.detached.map(\.1) == [["recon"]])
}

@Test func stillRunningInstallThatFailsIsReportedFailed() throws {
    let w = World()
    w.prefs = ["items": [cachedItem("a")]]
    w.installRunsFor["a"] = 1000
    w.installDescendant["a"] = true
    w.afterInstall["a"] = .version(Version("1.0")!)
    #expect(w.run() == 0)
    #expect(w.report?.items.map(\.state) == [.failed])
    #expect(w.report?.overall == "FAILED: a")
    #expect(w.state.failures["a"] == FailureRecord(targetVersion: "2.0", count: 1))
    #expect(w.presenters.first?.calls.last == "closeStill")
    #expect(w.detached.isEmpty)
}

@Test func reconDeferredUntilBackgroundFinishesEvenIfItFails() throws {
    let w = World()
    w.prefs = ["items": [cachedItem("a"), cachedItem("b")]]
    w.installRunsFor["b"] = 1000
    w.installDescendant["b"] = true
    w.afterInstall["b"] = .version(Version("1.0")!)
    var reconCountAtClose: Int?
    w.configurePresenter = { p in p.onCloseStillRunning = { reconCountAtClose = w.detached.count } }
    #expect(w.run() == 0)
    #expect(w.report?.items.map(\.state) == [.done, .failed])
    #expect(reconCountAtClose == 0)
    #expect(w.detached.map(\.1) == [["recon"]])
}

// MARK: - Config re-read at login

@Test func emptyBootConfigDecidesFromLoginConfig() throws {
    let w = World()
    w.prefs = [:]   // managed preferences not delivered yet at early boot
    w.users = [nil, nil, ("alice", 501)]
    var handledAtWait: String??
    var reportExistedAtWait: Bool?
    w.onUserPoll[1] = {
        handledAtWait = w.state.lastHandledBootSession; reportExistedAtWait = w.report != nil
        w.prefs = ["items": [cachedItem("a")]]
    }
    #expect(w.run() == 0)
    #expect(handledAtWait == .some(nil))   // the boot was not marked handled on an empty config
    #expect(reportExistedAtWait == false)  // and no results were written for it
    #expect(w.presenters.count == 1)
    #expect(w.report?.items.map(\.state) == [.done])
    #expect(w.state.lastHandledBootSession == "boot-1")
}

@Test func bootWorkButLoginConfigDisabledShowsNothing() {
    let w = World()
    w.prefs = ["items": [cachedItem("a")]]
    w.users = [nil, ("alice", 501)]
    w.onUserPoll[1] = { w.prefs = ["enabled": false, "items": [cachedItem("a")]] }
    #expect(w.run() == 0)
    #expect(w.report?.overall == "DISABLED")
    #expect(w.presenters.isEmpty)
    #expect(w.installs.isEmpty)
}

@Test func loginConfigErrorShowsNothing() {
    let w = World()
    w.prefs = ["items": [cachedItem("a")]]
    w.users = [nil, ("alice", 501)]
    w.onUserPoll[1] = { w.prefs = ["capSeconds": "lots", "items": [cachedItem("a")]] }
    #expect(w.run() == 0)
    #expect(w.report?.overall.hasPrefix("CONFIG ERROR: capSeconds") == true)
    #expect(w.presenters.isEmpty)
}

@Test func loginConfigSettingsAreUsedForTheRun() {
    let w = World()
    w.prefs = ["items": [cachedItem("a")]]
    w.users = [nil, ("alice", 501)]
    w.onUserPoll[1] = { w.prefs = ["items": [cachedItem("a"), cachedItem("b")], "title": "Login title"] }
    #expect(w.run() == 0)
    #expect(w.report?.items.map(\.id) == ["a", "b"])
    #expect(w.presenterGlobals.map(\.title) == ["Login title"])
}

@Test func userIgnoredByLoginConfigIsWaitedPast() {
    let w = World()
    w.prefs = [:]
    w.users = [nil, ("admin", 502), ("admin", 502), ("bob", 503)]
    w.onUserPoll[1] = { w.prefs = ["ignoredUsers": ["admin"], "items": [cachedItem("a")]] }
    #expect(w.run() == 0)
    #expect(w.presenters.map(\.uid) == [503])
    #expect(w.report?.user == "bob")
}

@Test func itemWithUntrustedHookShowsNoBlur() {
    let w = World()
    var a = cachedItem("a"); a["preInstallScript"] = "/nonexistent/threshold-hook.sh"
    w.prefs = ["items": [a]]
    #expect(w.run() == 0)
    #expect(w.presenters.isEmpty)
    #expect(w.installs.isEmpty)
    #expect(w.report?.skipped == [SkippedItem(id: "a", reason: "hook not trusted", countsAsFailure: false)])
    #expect(w.report?.overall == "OK")
}

// MARK: - Cancelled Jamf waits count toward quarantine

@Test func jamfCancelledAtCapCountsTowardQuarantine() throws {
    let w = World()
    w.prefs = ["items": [jamfItem("j")]]
    w.installRunsFor["j"] = 10_000   // stuck "downloading": no non-benign descendant, never finishes
    var s = PersistentState()
    s.failures["j"] = FailureRecord(targetVersion: "2.0", count: 2)
    try w.stateStore.save(s)
    #expect(w.run() == 0)
    #expect(w.installs["j"]?.terminated == true)
    #expect(w.report?.items.first?.reason == "cancelled at cap")
    #expect(w.state.failures["j"] == FailureRecord(targetVersion: "2.0", count: 3))
    // The next boot quarantines it instead of blurring again.
    let config = try Config.parse(w.prefs)
    #expect(w.state.isQuarantined(config.items[0], max: config.global.maxConsecutiveFailures))
}


// MARK: - Network wait and fallback trigger

@Test func jamfOnlyWorkWaitsForNetworkUnderTheBlur() throws {
    let w = World()
    w.prefs = ["items": [jamfItem("j")]]
    w.jamfConnectionSequence = [1, 1, 0]          // offline at login, back a few seconds later
    #expect(w.run() == 0)
    #expect(w.presenters.count == 1)
    #expect(w.report?.items.map(\.state) == [.done])
    #expect(w.jamfConnectionChecks == 3)
}

@Test func jamfOfflineForTheWholeWaitSkipsWithoutCounting() throws {
    let w = World()
    w.prefs = ["items": [jamfItem("j")], "networkWaitSeconds": 20]
    w.jamfConnectionExit = 1
    #expect(w.run() == 0)
    #expect(w.presenters.count == 1)
    #expect(w.report?.items.map(\.state) == [.skipped])
    #expect(w.report?.items.first?.reason == "Jamf Pro server unreachable")
    #expect(w.state.failures.isEmpty)
    #expect(!w.fakeLauncher.launches.contains { $0.arguments.first == "policy" })
}

@Test func networkWaitZeroKeepsTheOldNoBlurBehaviour() {
    let w = World()
    w.prefs = ["items": [jamfItem("j")], "networkWaitSeconds": 0]
    w.jamfConnectionExit = 1
    #expect(w.run() == 0)
    #expect(w.presenters.isEmpty)
    #expect(w.report?.overall == "BLOCKED: Jamf Pro server unreachable")
    #expect(w.jamfConnectionChecks == 1)
}

@Test func missingCachedPackageRunsFallbackPolicy() throws {
    let w = World()
    var item = cachedItem("a")
    item["fallbackTrigger"] = "installa"
    w.prefs = ["items": [item]]
    w.packageChecks["/Library/Caches/a.pkg"] = .missing
    #expect(w.run() == 0)
    let report = try #require(w.report)
    #expect(report.items.map(\.state) == [.done])
    #expect(report.items.first?.reason == "cached package missing; used fallback trigger")
    #expect(w.fakeLauncher.launches.contains { $0.arguments == ["policy", "-event", "installa"] })
    #expect(!w.fakeLauncher.launches.contains { $0.executable == "/usr/sbin/installer" })
}

// MARK: - Standard binary locations (no path keys)

@Test func untrustedUsrLocalDialogFallsBackToTheAppBundleBinary() throws {
    let w = World()
    w.prefs = ["items": [cachedItem("a")]]
    let cli = "/Library/Application Support/Dialog/Dialog.app/Contents/MacOS/dialogcli"
    w.untrustedExecutables = ["/usr/local/bin/dialog"]   // e.g. user-owned /usr/local/bin after migration
    w.files.insert(cli)
    #expect(w.run() == 0)
    #expect(w.presenterGlobals.map(\.swiftDialogPath) == [cli])
    #expect(w.report?.items.map(\.state) == [.done])
}

@Test func untrustedUsrLocalJamfFallsBackToTheRealBinary() throws {
    let w = World()
    w.prefs = ["items": [jamfItem("j")]]
    let real = "/usr/local/jamf/bin/jamf"
    w.untrustedExecutables = ["/usr/local/bin/jamf"]
    w.files.insert(real)
    #expect(w.run() == 0)
    #expect(w.report?.items.map(\.state) == [.done])
    #expect(w.fakeLauncher.launches.contains { $0.executable == real && $0.arguments.first == "policy" })
    #expect(w.detached.map(\.0) == [real])   // recon through the same trusted binary
}

@Test func modernWindowIsTheDefaultWithSwiftDialog3() {
    let w = World()
    w.prefs = ["items": [cachedItem("a")]]
    w.dialogVersion = "3.0.1.4955"
    #expect(w.run() == 0)
    #expect(w.presenterGlobals.map(\.windowStyle) == [.modern])
    #expect(w.report?.items.map(\.state) == [.done])
}

@Test func swiftDialog2FallsBackToTheClassicWindow() {
    let w = World()
    w.prefs = ["items": [cachedItem("a")]]
    w.dialogVersion = "2.5.6.4805"
    #expect(w.run() == 0)
    #expect(w.presenterGlobals.map(\.windowStyle) == [.classic])
    #expect(w.report?.items.map(\.state) == [.done])
}

@Test func classicWindowCanBeChosen() {
    let w = World()
    w.prefs = ["windowStyle": "classic", "items": [cachedItem("a")]]
    w.dialogVersion = "3.1.1.5000"
    #expect(w.run() == 0)
    #expect(w.presenterGlobals.map(\.windowStyle) == [.classic])
}

@Test func macStaysAwakeOnlyWhileTheBlurIsUp() {
    let w = World()
    w.prefs = ["items": [cachedItem("a")]]
    #expect(w.run() == 0)
    #expect(w.awake == ["+display", "+system", "-display", "-system"])
}

@Test func macStaysAwakeUntilABackgroundInstallFinishes() throws {
    let w = World()
    w.prefs = ["capSeconds": 300, "items": [cachedItem("a")]]
    w.installRunsFor["a"] = 1000
    w.installDescendant["a"] = true
    var installRunningAtDisplayRelease: Bool?
    var installRunningAtSystemRelease: Bool?
    w.onAwakeRelease = { event in
        let running = w.installs["a"]?.isRunning
        if event == "-display" { installRunningAtDisplayRelease = running }
        if event == "-system" { installRunningAtSystemRelease = running }
    }
    #expect(w.run() == 0)
    #expect(w.awake == ["+display", "+system", "-display", "-system"])
    #expect(installRunningAtDisplayRelease == true)   // blur lifted at the cap: the display may sleep
    #expect(installRunningAtSystemRelease == false)   // but the Mac stayed awake until the install ended
}

@Test func nothingToDoNeverKeepsTheMacAwake() {
    let w = World()
    w.prefs = ["items": [cachedItem("a")]]
    w.installed["a"] = .version(Version("2.0")!)
    #expect(w.run() == 0)
    #expect(w.awake.isEmpty)
}

@Test func newBuildInstallsAMissingApp() {
    let w = World()
    var a = cachedItem("a"); a["installIfMissing"] = true
    w.prefs = ["items": [a, cachedItem("b")]]
    w.installed["a"] = .notInstalled
    w.installed["b"] = .notInstalled
    #expect(w.run() == 0)
    #expect(w.report?.items.map(\.id) == ["a"])
    #expect(w.report?.items.first?.state == .done)
    #expect(w.report?.items.first?.versionBefore == "0")
    #expect(w.report?.items.first?.versionAfter == "2.0")
    #expect(w.report?.skipped.map(\.id) == ["b"])
    #expect(w.report?.overall == "OK")
}
