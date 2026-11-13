import Foundation

/// Everything the daemon lifecycle needs from the machine. The real implementation lives in the
/// `threshold` executable; tests supply fakes.
public protocol Platform: AnyObject {
    var clock: Clock { get }
    var launcher: ProcessLauncher { get }
    var probe: SystemProbe { get }
    var versions: VersionReading { get }
    var packages: PackageVerifying { get }
    var stateStore: StateStore { get }
    var resultsWriter: ResultsWriter { get }

    /// Only forced (managed) values for `com.qlabs.threshold`.
    func managedPreferences() -> [String: Any]
    /// Managed preferences, or the test-mode plist when the trusted marker exists (see `ConfigSource`).
    func configSource() -> ConfigSource
    func consoleUser() -> (name: String, uid: uid_t)?
    func bootSessionUUID() -> String
    func uptimeSeconds() -> TimeInterval
    /// The running macOS version, e.g. "27.0.1".
    func osVersion() -> Version
    func fileExists(_ path: String) -> Bool
    /// The resolved path of a configured executable if it may be run as root, else nil (missing or
    /// untrusted). See `ExecutableTrust`; production uses the default in that file.
    func trustedExecutable(_ path: String) -> String?
    /// Kills dialogs left over from a previous daemon process.
    func killStaleDialogs()
    func makePresenter(uid: uid_t, global: GlobalConfig) -> DialogPresenting
    /// Starts a process in its own session so it outlives the daemon.
    func launchDetached(_ executable: String, _ arguments: [String]) throws
    /// Keeps the Mac awake (like `caffeinate`) until the returned closure is called. `display`: also keep the
    /// display on. Failure to take the assertion is logged and returns a no-op.
    func keepAwake(display: Bool, reason: String) -> () -> Void
}

/// The once-per-boot sequence: plan before login, wait for the first eligible login, re-read the config,
/// mark the boot handled, then blur, install, verify and report. Returns the process exit code.
public final class Lifecycle {
    private let platform: Platform
    private let log: Log
    private var testMode = false

    public init(platform: Platform, log: Log = .shared) {
        self.platform = platform
        self.log = log
    }

    private var clock: Clock { platform.clock }

    public func run() -> Int32 {
        log.info("daemon starting")

        // 1. Stale dialogs from a crashed run must not keep the screen blurred.
        platform.killStaleDialogs()
        log.info("cleared stale dialogs")

        let boot = platform.bootSessionUUID()
        log.info("boot session \(boot.isEmpty ? "(unknown)" : boot)")

        // 2. Config (read again at login, step 7: profiles may not be delivered yet at early boot).
        let bootConfig: Config
        switch loadConfig("boot") {
        case let .stop(overall): return exitEarly(overall: overall, boot: boot)
        case let .ready(c): bootConfig = c
        }

        // Without a boot id we can't remember having handled this boot, so a relaunch could re-blur.
        guard !boot.isEmpty else {
            log.error("boot session UUID unavailable; doing nothing")
            return exitEarly(overall: "ERROR: boot session unknown", boot: boot)
        }

        // 3. Once per boot.
        var state = platform.stateStore.load()
        if state.lastHandledBootSession == boot {
            log.info("boot session already handled; exiting")
            return 0
        }

        // 4. Never blur a session that was already in use.
        if let user = platform.consoleUser(),
           SessionGate.isEligibleUser(user.name, ignored: bootConfig.global.ignoredUsers) {
            let uptime = platform.uptimeSeconds()
            guard SessionGate.shouldRunForExistingSession(uptimeSeconds: uptime) else {
                log.info("user \(user.name) already logged in, uptime \(format(uptime)); marking boot handled, no blur")
                _ = markHandled(&state, boot)
                return 0
            }
            log.info("user \(user.name) already logged in shortly after boot (uptime \(format(uptime))); treating as first login")
        }

        // 5. Plan before anyone logs in. An empty config may just mean the profile hasn't arrived yet:
        //    then don't mark the boot handled; wait for the login and decide from the login config.
        if bootConfig.items.isEmpty && bootConfig.invalidItems.isEmpty {
            log.info("boot config has no items (profile may not be delivered yet); deciding at login")
        } else {
            let bootPlan = plan(bootConfig, state)
            log.info("boot plan: \(describe(bootPlan))")
            guard bootPlan.hasWork else {
                log.info("nothing to do this boot")
                _ = markHandled(&state, boot)
                write(plan: bootPlan, results: [], user: platform.consoleUser()?.name ?? "", boot: boot)
                return 0
            }
        }

        // 6. Wait for the first eligible login.
        log.info("waiting for an eligible console user")
        var user = waitForEligibleUser(ignored: bootConfig.global.ignoredUsers)
        log.info("eligible console user: \(user.name) (uid \(user.uid))")

        // 7. Re-read the config: the login config decides this run.
        let config: Config
        switch loadConfig("login") {
        case let .stop(overall): return exitEarly(overall: overall, boot: boot)
        case let .ready(c): config = c
        }
        let global = config.global
        if !SessionGate.isEligibleUser(user.name, ignored: global.ignoredUsers) {
            log.info("user \(user.name) is ignored by the login config; waiting for an eligible console user")
            user = waitForEligibleUser(ignored: global.ignoredUsers)
            log.info("eligible console user: \(user.name) (uid \(user.uid))")
        }

        // 8. A crash from here on must never re-blur: persist before showing anything.
        guard markHandled(&state, boot) else {
            log.error("could not persist boot as handled; not showing the blur")
            write(plan: Plan(work: [], skipped: [], upToDate: []), results: [], user: user.name, boot: boot,
                  overall: "ERROR: could not save state")
            return 0
        }

        // Re-plan: things may have changed while waiting.
        let loginPlan = plan(config, state)
        log.info("login plan: \(describe(loginPlan))")
        guard loginPlan.hasWork else {
            log.info("nothing to do at login")
            write(plan: loginPlan, results: [], user: user.name, boot: boot)
            return 0
        }

        // 9. No usable swiftDialog means no UI, so no installs.
        let dialogPath: String
        let dialogVersion: Version
        switch usableSwiftDialog(global) {
        case .success(let usable): (dialogPath, dialogVersion) = usable
        case .failure(let unusable):
            log.error("\(unusable.reason); skipping all work")
            write(plan: loginPlan, results: skippedResults(loginPlan.work, unusable.reason),
                  user: user.name, boot: boot, blocked: unusable.reason)
            return 0
        }

        // 10. Safety, then run. From here on only the resolved, trust-checked binaries are executed.
        let needsJamf = loginPlan.work.contains { if case .jamfTrigger = $0.item.source { return true }; return false }
        var runConfig = config
        runConfig.global.swiftDialogPath = dialogPath
        if runConfig.global.windowStyle == .modern && dialogVersion < WindowStyle.modernMinimumSwiftDialog {
            log.info("swiftDialog \(dialogVersion.raw) is older than \(WindowStyle.modernMinimumSwiftDialog.raw); "
                     + "using the classic window")
            runConfig.global.windowStyle = .classic
        }
        if needsJamf, let jamf = trustedJamf(global) {
            runConfig.global.jamfBinaryPath = jamf
        }
        let safety = Safety.check(runConfig.global, needsJamf: needsJamf, probe: platform.probe,
                                  launcher: platform.launcher, clock: clock,
                                  resolveExecutable: platform.trustedExecutable)
        log.info("safety: global=\(safety.globalBlock ?? "ok") jamf=\(safety.jamfBlock ?? "ok")")
        if let reason = blockingEverything(safety, loginPlan.work, networkWait: runConfig.global.networkWaitSeconds) {
            // Nothing could install: a blur would only flash the user for nothing.
            log.info("safety blocks every item (\(reason)); no blur")
            write(plan: loginPlan, results: skippedResults(loginPlan.work, reason), user: user.name, boot: boot,
                  blocked: reason)
            return 0
        }

        // Installs must not stall because the user walked away: display and idle sleep are blocked while the
        // blur is up, idle sleep while installs continue in the background (step 13).
        let releaseDisplay = platform.keepAwake(display: true, reason: "Threshold is installing updates")
        let releaseSystem = platform.keepAwake(display: false, reason: "Threshold is installing updates")
        defer { releaseDisplay(); releaseSystem() }   // idempotent; also covers early returns
        let presenter = platform.makePresenter(uid: user.uid, global: runConfig.global)
        log.info("showing blur (\(runConfig.global.windowStyle.rawValue) window) for "
                 + loginPlan.work.map(\.item.id).joined(separator: ","))
        let jamf = runConfig.global.jamfBinaryPath
        let launcher = platform.launcher
        let statusLog = runConfig.global.statusLog
        let runner = Runner(config: runConfig, launcher: launcher, clock: clock,
                            versions: platform.versions, dialog: presenter,
                            jamfRecheck: { [clock] until in
                                Safety.waitForJamf(jamf, launcher: launcher, clock: clock, until: until)
                            },
                            statusLine: statusLog.map { path in {
                                let offset = StatusLog.currentSize(path: path)
                                return { StatusLog.latestLine(path: path, after: offset) }
                            } })
        let outcome = runner.run(loginPlan.work, safety: safety)
        releaseDisplay()   // the blur is gone; the display may sleep again
        var results = outcome.results
        for r in results {
            log.info("item \(r.id): \(r.state.rawValue)\(r.reason.map { " (\($0))" } ?? "")")
        }

        let items = Dictionary(loginPlan.work.map { ($0.item.id, $0.item) }, uniquingKeysWith: { a, _ in a })
        for r in results {
            guard let item = items[r.id] else { continue }
            if r.countsAsFailure { state.recordFailure(item) }
            if r.state == .done { state.recordSuccess(item) }
        }
        save(state)

        // 11. Results
        write(plan: loginPlan, results: results, user: user.name, boot: boot)

        // 12. Inventory. With installs still running, recon waits until they finish (step 13).
        guard !outcome.background.isEmpty else {
            if results.contains(where: { $0.state == .done }) { recon(global) }
            log.info("daemon finished")
            return 0
        }

        // 13. Installs left running past the cap: wait (never kill), then verify.
        for (item, process) in outcome.background {
            log.info("monitoring \(item.id), still installing in the background")
            let start = clock.now()
            while process.isRunning { clock.sleep(5) }
            let read = platform.versions.read(item.probe)
            guard let index = results.firstIndex(where: { $0.id == item.id }) else { continue }
            var r = results[index]
            r.durationSeconds += clock.now().timeIntervalSince(start)
            switch read {
            case let .version(v) where v >= item.targetVersion:
                r.state = .done; r.reason = nil; r.versionAfter = v.raw; r.countsAsFailure = false
                state.recordSuccess(item)
            case let .version(v):
                r.state = .failed; r.reason = "version unchanged (\(v.raw))"; r.versionAfter = v.raw
                r.countsAsFailure = true
            case .notInstalled:
                r.state = .failed; r.reason = "version unchanged (not installed)"; r.countsAsFailure = true
            case .unreadable:
                r.state = .failed; r.reason = "version unchanged (unreadable)"; r.countsAsFailure = true
            }
            // The failure was already counted when the item was left running.
            results[index] = r
            log.info("background item \(item.id) finished: \(r.state.rawValue)\(r.reason.map { " (\($0))" } ?? "")")
            save(state)
            write(plan: loginPlan, results: results, user: user.name, boot: boot)
        }
        presenter.closeStillRunning()
        if results.contains(where: { $0.state == .done }) { recon(global) }
        log.info("daemon finished")
        return 0
    }

    // MARK: - Steps

    private enum LoadedConfig {
        case ready(Config)
        /// Stop the run with this `overall` (config error or kill switch).
        case stop(String)
    }

    /// Reads and parses the config source; `moment` ("boot" / "login") is for the log.
    private func loadConfig(_ moment: String) -> LoadedConfig {
        let source = platform.configSource()
        testMode = source.testMode
        if let warning = source.warning { log.error(warning) }
        if source.testMode { log.error(ConfigSource.testModeLogLine) }
        if let error = source.error { return .stop("CONFIG ERROR: \(error)") }
        let config: Config
        do {
            config = try Config.parse(source.prefs)
        } catch let ConfigError.invalidGlobal(key, reason) {
            return .stop("CONFIG ERROR: \(key) \(reason)")
        } catch {
            return .stop("CONFIG ERROR: \(error)")
        }
        log.info("config loaded (\(moment)): \(config.items.count) item(s), \(config.invalidItems.count) invalid")
        for invalid in config.invalidItems { log.error("invalid item \(invalid.id): \(invalid.reason)") }
        guard config.global.enabled else { return .stop("DISABLED") }
        // The OS gate comes before any planning, so a Mac below the minimum never blurs.
        if let minimum = config.global.minimumOSVersion {
            let os = platform.osVersion()
            guard os >= minimum else { return .stop("OS BELOW MINIMUM: macOS \(os) < \(minimum)") }
            log.info("macOS \(os) meets minimum \(minimum)")
        }
        return .ready(config)
    }

    private func exitEarly(overall: String, boot: String) -> Int32 {
        log.info("exiting: \(overall)")
        write(plan: Plan(work: [], skipped: [], upToDate: []), results: [],
              user: platform.consoleUser()?.name ?? "", boot: boot, overall: overall)
        return 0
    }

    private func plan(_ config: Config, _ state: PersistentState) -> Plan {
        Planner.plan(config, state: state, versions: platform.versions, packages: platform.packages)
    }

    private func describe(_ plan: Plan) -> String {
        "work=[\(plan.work.map { $0.item.id + ($0.note.map { " (\($0))" } ?? "") }.joined(separator: ","))] "
            + "upToDate=[\(plan.upToDate.joined(separator: ","))] "
            + "skipped=[\(plan.skipped.map { "\($0.id): \($0.reason)" }.joined(separator: "; "))]"
    }

    private func waitForEligibleUser(ignored: [String]) -> (name: String, uid: uid_t) {
        while true {
            if let user = platform.consoleUser(), SessionGate.isEligibleUser(user.name, ignored: ignored) {
                return user
            }
            clock.sleep(1)
        }
    }

    /// Returns false if the state could not be saved.
    private func markHandled(_ state: inout PersistentState, _ boot: String) -> Bool {
        state.lastHandledBootSession = boot
        do {
            try platform.stateStore.save(state)
            log.info("boot session marked handled")
            return true
        } catch {
            log.error("could not save state: \(error)")
            return false
        }
    }

    private func save(_ state: PersistentState) {
        do { try platform.stateStore.save(state) } catch { log.error("could not save state: \(error)") }
    }

    /// The first candidate that resolves to a trusted executable (resolved path), or nil.
    private func firstTrusted(_ candidates: [String]) -> String? {
        for candidate in candidates {
            if let path = platform.trustedExecutable(candidate) { return path }
        }
        return nil
    }

    private func trustedJamf(_ global: GlobalConfig) -> String? {
        firstTrusted([global.jamfBinaryPath] + GlobalConfig.jamfFallbacks)
    }

    /// The resolved swiftDialog path if it is trusted and new enough (it is never executed otherwise),
    /// or the reason it can't be used.
    private func usableSwiftDialog(_ global: GlobalConfig) -> Result<(path: String, version: Version), SwiftDialogUnusable> {
        guard let path = firstTrusted([global.swiftDialogPath] + GlobalConfig.swiftDialogFallbacks) else {
            log.error("swiftDialog at \(global.swiftDialogPath) (and inside Dialog.app) is missing or untrusted")
            return .failure(SwiftDialogUnusable(reason: "swiftDialog missing or untrusted"))
        }
        switch swiftDialogVersion(path: path, launcher: platform.launcher, clock: clock) {
        case .failure(let problem):
            log.error("swiftDialog at \(path): --version \(problem)")
            return .failure(SwiftDialogUnusable(reason: "swiftDialog version check failed (\(problem))"))
        case .success(let version):
            log.info("swiftDialog \(version.raw) at \(path)")
            guard version >= global.minSwiftDialogVersion else {
                let reason = "swiftDialog \(version.raw) older than \(global.minSwiftDialogVersion.raw)"
                log.error(reason)
                return .failure(SwiftDialogUnusable(reason: reason))
            }
            return .success((path, version))
        }
    }

    /// The reason nothing in `work` could be installed this run, if so.
    /// An unreachable Jamf server doesn't block everything while a network wait is configured: the Runner
    /// waits for it under the blur.
    private func blockingEverything(_ safety: SafetyResult, _ work: [PlannedItem], networkWait: Int) -> String? {
        if let block = safety.globalBlock { return block }
        if let block = safety.jamfBlock, !(safety.jamfRetryable && networkWait > 0),
           work.allSatisfy({ if case .jamfTrigger = $0.item.source { return true }; return false }) {
            return block
        }
        return nil
    }

    private func skippedResults(_ work: [PlannedItem], _ reason: String) -> [ItemResult] {
        work.map {
            ItemResult(id: $0.item.id, displayName: $0.item.displayName, state: .skipped, reason: reason,
                       versionBefore: $0.installed.raw, versionAfter: nil, durationSeconds: 0,
                       countsAsFailure: false)
        }
    }

    private func recon(_ global: GlobalConfig) {
        guard let jamf = trustedJamf(global) else {
            log.info("jamf binary missing or untrusted; skipping recon")
            return
        }
        do {
            try platform.launchDetached(jamf, ["recon"])
            log.info("launched jamf recon")
        } catch {
            log.error("could not launch jamf recon: \(error)")
        }
    }

    /// Uptime for logs; never traps on a non-finite value.
    private func format(_ uptime: TimeInterval) -> String {
        uptime.isFinite && abs(uptime) < 1e15 ? "\(Int(uptime)) s" : "unknown"
    }

    private func write(plan: Plan, results: [ItemResult], user: String, boot: String, overall: String? = nil,
                       blocked: String? = nil) {
        let quarantined = plan.skipped.filter { $0.reason == "quarantined" }.map(\.id)
        let status = overall ?? overallStatus(results: results, skipped: plan.skipped, quarantined: quarantined,
                                                  blocked: blocked)
        let report = RunReport(runAt: clock.now(), bootSession: boot, user: user, overall: status,
                               items: results, skipped: plan.skipped, upToDate: plan.upToDate, testMode: testMode)
        do {
            try platform.resultsWriter.write(report)
            log.info("results written: \(status)")
        } catch {
            log.error("could not write results: \(error)")
        }
    }
}

/// Why swiftDialog can't be used this run; `reason` goes into results.json.
struct SwiftDialogUnusable: Error { let reason: String }
