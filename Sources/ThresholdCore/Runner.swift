import Foundation

public enum ItemState: String, Codable {
    case pending, waiting, installing, verifying, healthCheck, done, failed, skipped, stillRunning
}

public struct ItemResult: Codable, Equatable {
    public var id: String
    public var displayName: String
    public var state: ItemState
    public var reason: String?
    public var versionBefore: String?
    public var versionAfter: String?
    public var durationSeconds: Double
    public var countsAsFailure: Bool

    public init(id: String, displayName: String, state: ItemState, reason: String?, versionBefore: String?,
                versionAfter: String?, durationSeconds: Double, countsAsFailure: Bool) {
        self.id = id; self.displayName = displayName; self.state = state; self.reason = reason
        self.versionBefore = versionBefore; self.versionAfter = versionAfter
        self.durationSeconds = durationSeconds; self.countsAsFailure = countsAsFailure
    }
}

public struct RunOutcome {
    public var results: [ItemResult]
    /// Installs left running past their deadline. They are never killed.
    public var background: [(item: Item, process: ManagedProcess)]

    public init(results: [ItemResult], background: [(item: Item, process: ManagedProcess)]) {
        self.results = results
        self.background = background
    }
}

/// Installs planned items one at a time behind the blur, within `capSeconds` of run start.
///
/// Safety rules: a process is only ever terminated while it is `waiting` (a Jamf policy whose
/// descendants are all in `jamfBenignDescendants`). Once `installing` — or if that can't be
/// determined — it is left running, reported `stillRunning`, and no further item starts this run.
public final class Runner {
    /// Process names that may run under `jamf policy` without it counting as installing: the policy is
    /// still checking in, downloading or showing UI. Policies install through many tools (`installer`,
    /// scripts, `ditto`, vendor installers, `softwareupdate`, ...), so ANY other descendant of the jamf
    /// process means installing, and that is sticky: a waiting policy may be cancelled at the cap,
    /// an installing one never is. Keep this list short; a wrong entry could kill an install.
    public static let jamfBenignDescendants: Set<String> = ["curl", "jamfAgent", "sleep", "logger", "jamfHelper"]

    private let config: Config
    private let launcher: ProcessLauncher
    private let clock: Clock
    private let versions: VersionReading
    private let dialog: DialogPresenting
    /// The canonical path to run for a configured hook, or nil if it is untrusted.
    private let trustedHookPath: (String) -> String?
    /// Waits (under the blur) for the Jamf Pro server until the given time; true once it answers.
    private let jamfRecheck: ((Date) -> Bool)?
    /// The admin's `statusLog`: `mark()` is called when an item's install starts and returns a reader for the
    /// newest line written since then, shown under the item while it waits or installs; nil = off.
    private let statusLine: (() -> () -> String?)?

    public init(config: Config, launcher: ProcessLauncher, clock: Clock, versions: VersionReading,
                dialog: DialogPresenting,
                trustedHookPath: @escaping (String) -> String? = HookTrust.trustedCanonicalPath(_:),
                jamfRecheck: ((Date) -> Bool)? = nil,
                statusLine: (() -> () -> String?)? = nil) {
        self.jamfRecheck = jamfRecheck
        self.statusLine = statusLine
        self.config = config
        self.launcher = launcher
        self.clock = clock
        self.versions = versions
        self.dialog = dialog
        self.trustedHookPath = trustedHookPath
    }

    private var global: GlobalConfig { config.global }

    public func run(_ plan: [PlannedItem], safety: SafetyResult) -> RunOutcome {
        // Nothing to do: never show the blur.
        guard !plan.isEmpty else { return RunOutcome(results: [], background: []) }
        let deadline = clock.now().addingTimeInterval(TimeInterval(global.capSeconds))

        do {
            try dialog.showBlur(items: plan.map(\.item), global: global)
        } catch {
            // No UI means no installs: never install silently.
            let results = plan.map { result($0, .skipped, "swiftDialog failed to launch", counts: false) }
            return RunOutcome(results: results, background: [])
        }

        var results: [ItemResult] = []
        var background: [(item: Item, process: ManagedProcess)] = []
        var stopped = false
        var jamfBlock = safety.jamfBlock
        var recheckPending = safety.jamfRetryable && global.networkWaitSeconds > 0 && jamfRecheck != nil

        for (index, planned) in plan.enumerated() {
            if recheckPending, jamfBlock != nil, case .jamfTrigger = planned.item.source,
               safety.globalBlock == nil, !stopped, clock.now() < deadline, let recheck = jamfRecheck {
                // Once per run, at the first Jamf item: Wi-Fi often joins only after login.
                recheckPending = false
                dialog.update(index: index, state: .waiting, detail: "Waiting for network")
                let until = min(clock.now().addingTimeInterval(TimeInterval(global.networkWaitSeconds)), deadline)
                if recheck(until) { jamfBlock = nil }
            }
            let outcome: ItemResult
            if let block = safety.globalBlock {
                outcome = result(planned, .skipped, block, counts: false)
            } else if stopped || clock.now() >= deadline {
                stopped = true
                outcome = result(planned, .skipped, "not started (cap)", counts: false)
            } else if let block = jamfBlock, case .jamfTrigger = planned.item.source {
                outcome = result(planned, .skipped, block, counts: false)
            } else {
                let (r, leftRunning) = install(planned, index: index, deadline: deadline)
                outcome = r
                if let leftRunning {
                    background.append((item: planned.item, process: leftRunning))
                    // Never run two installers at once: nothing else starts this run.
                    stopped = true
                }
            }
            let detail = (outcome.state == .skipped || outcome.state == .failed) ? outcome.reason : nil
            dialog.update(index: index, state: outcome.state, detail: detail)
            results.append(outcome)
        }

        dialog.finish(success: results.allSatisfy { $0.state == .done }, global: global)
        if let first = results.first(where: { $0.state == .stillRunning }) {
            dialog.showStillRunning(displayName: first.displayName)
        }
        return RunOutcome(results: results, background: background)
    }

    // MARK: - One item

    /// Returns the final result, plus the process if it was left running.
    private func install(_ planned: PlannedItem, index: Int, deadline: Date) -> (ItemResult, ManagedProcess?) {
        let item = planned.item
        let start = clock.now()
        let itemDeadline = min(start.addingTimeInterval(TimeInterval(item.timeoutSeconds)), deadline)

        func finish(_ state: ItemState, _ reason: String?, counts: Bool, after: String? = nil) -> ItemResult {
            result(planned, state, reason, counts: counts, after: after,
                   duration: clock.now().timeIntervalSince(start))
        }

        // 1. Pre-install hook
        // Hooks were trust-checked when planning; check again here (and run the checked canonical path).
        if let configured = item.preInstallScript {
            guard let hook = trustedHookPath(configured) else {
                return (finish(.skipped, "hook not trusted", counts: true), nil)
            }
            guard runHook(hook, item, deadline: itemDeadline).succeeded else {
                return (finish(.skipped, "pre-install hook failed", counts: true), nil)
            }
            // Never launch an installer past the item's deadline.
            guard clock.now() < itemDeadline else {
                return (finish(.skipped, "pre-install hook exceeded item timeout", counts: true), nil)
            }
        }

        // 2. Install
        let executable: String
        let arguments: [String]
        var state: ItemState
        switch item.source {
        case let .cachedPackage(path, _, _):
            (executable, arguments) = ("/usr/sbin/installer", ["-pkg", path, "-target", "/"])
            state = .installing
        case let .jamfTrigger(trigger):
            (executable, arguments) = (global.jamfBinaryPath, ["policy", "-event", trigger])
            state = .waiting
        }
        let process: ManagedProcess
        do {
            process = try launcher.launch(executable, arguments)
        } catch {
            return (finish(.failed, "launch failed: \(error)", counts: true), nil)
        }
        dialog.update(index: index, state: state, detail: nil)

        // 3. Poll until exit or the item deadline.
        var shownLine: String?
        let newestLine = statusLine?()   // only lines this install writes, never an old one
        while process.isRunning {
            // Sticky: once installing (or unknown), never back to waiting.
            if state == .waiting, process.hasDescendant(otherThan: Self.jamfBenignDescendants) != false {
                state = .installing
                dialog.update(index: index, state: state, detail: nil)
                shownLine = nil
            }
            if let newestLine, let line = newestLine(), line != shownLine {
                shownLine = line
                dialog.update(index: index, state: state, detail: line)
            }
            if clock.now() >= itemDeadline {
                guard process.isRunning else { break }
                if state == .waiting, cancel(process) {
                    // Counts toward quarantine: a permanently stuck download
                    // must not blur every boot forever. "not started (cap)" and safety skips still don't count.
                    return (finish(.skipped, "cancelled at cap", counts: true), nil)
                }
                return (finish(.stillRunning, nil, counts: true), process)
            }
            clock.sleep(1)
        }

        // 4. Verify (exit code ignored: the installed version is the truth).
        dialog.update(index: index, state: .verifying, detail: nil)
        let read = versions.read(item.probe)
        var after: String?
        let readDescription: String
        switch read {
        case let .version(v): after = v.raw; readDescription = v.raw
        case .notInstalled: readDescription = "not installed"
        case .unreadable: readDescription = "unreadable"
        }
        guard case let .version(v) = read, v >= item.targetVersion else {
            return (finish(.failed, "version unchanged (\(readDescription))", counts: true, after: after), nil)
        }

        // 5. Post-install hook (the app is updated, so a failure here doesn't count toward quarantine).
        if let configured = item.postInstallScript {
            guard let hook = trustedHookPath(configured) else {
                return (finish(.failed, "post-install hook not trusted", counts: false, after: after), nil)
            }
            guard runHook(hook, item, deadline: deadline).succeeded else {
                return (finish(.failed, "post-install hook failed", counts: false, after: after), nil)
            }
        }

        // 6. Health
        if !item.health.isEmpty {
            dialog.update(index: index, state: .healthCheck, detail: nil)
            let budget = min(TimeInterval(global.healthTimeoutSeconds), deadline.timeIntervalSince(clock.now()))
            guard budget >= 1 else {
                return (finish(.done, "health not checked (cap)", counts: false, after: after), nil)
            }
            let healthDeadline = clock.now().addingTimeInterval(budget)
            if let failed = firstFailingHealthCheck(item.health, deadline: healthDeadline) {
                return (finish(.failed, "health check failed: \(failed)", counts: true, after: after), nil)
            }
        }

        // 7. Done
        return (finish(.done, nil, counts: false, after: after), nil)
    }

    /// Terminates a `waiting` process and waits up to 6 s for it to exit, so it can't start an installer
    /// alongside the next item. Returns true only if it exited cleanly with no install seen meanwhile;
    /// false means it must be treated as installing (left running, never killed further).
    private func cancel(_ process: ManagedProcess) -> Bool {
        process.terminate()
        let waitStart = clock.now()
        while process.isRunning {
            switch process.hasDescendant(otherThan: Self.jamfBenignDescendants) {
            case false?:
                break
            case true?:
                return false
            case nil:
                // Unknown is usually the root exiting: SystemProcess.isRunning lags the real exit by up
                // to 1 s. If it has exited one tick later, that was a clean exit; otherwise installing.
                clock.sleep(1)
                return !process.isRunning
            }
            if clock.now().timeIntervalSince(waitStart) >= 6 { return false }
            clock.sleep(1)
        }
        return true
    }

    private func runHook(_ path: String, _ item: Item, deadline: Date) -> CommandResult {
        let remaining = max(deadline.timeIntervalSince(clock.now()), 1)
        let timeout = min(TimeInterval(global.hookTimeoutSeconds), remaining)
        return runToCompletion(launcher, clock, path, [item.id], timeout: timeout)
    }

    /// Runs the configured checks in order process → command → url; returns the first failing one's name.
    private func firstFailingHealthCheck(_ health: HealthCheck, deadline: Date) -> String? {
        var checks: [(name: String, executable: String, arguments: [String])] = []
        if let name = health.process { checks.append(("process", "/usr/bin/pgrep", ["-x", name])) }
        if let command = health.command { checks.append(("command", "/bin/sh", ["-c", command])) }
        if let url = health.url {
            checks.append(("url", "/usr/bin/curl", ["-sS", "-o", "/dev/null", "-m", "10", url.absoluteString]))
        }
        for check in checks {
            let timeout = max(deadline.timeIntervalSince(clock.now()), 0)
            if !runToCompletion(launcher, clock, check.executable, check.arguments, timeout: timeout).succeeded {
                return check.name
            }
        }
        return nil
    }

    private func result(_ planned: PlannedItem, _ state: ItemState, _ reason: String?, counts: Bool,
                        after: String? = nil, duration: Double = 0) -> ItemResult {
        ItemResult(id: planned.item.id, displayName: planned.item.displayName, state: state,
                   reason: reason ?? planned.note,
                   versionBefore: planned.installed.raw, versionAfter: after,
                   durationSeconds: duration, countsAsFailure: counts)
    }
}
