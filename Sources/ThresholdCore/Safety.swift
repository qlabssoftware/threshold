import Foundation

public struct PowerStatus: Equatable {
    public var onAC: Bool
    /// nil means the Mac has no battery.
    public var batteryPercent: Int?

    public init(onAC: Bool, batteryPercent: Int?) {
        self.onAC = onAC
        self.batteryPercent = batteryPercent
    }
}

public protocol SystemProbe {
    func power() -> PowerStatus
    func freeDiskGB() -> Double
}

public struct SafetyResult: Equatable {
    /// Set when nothing may be installed this run.
    public var globalBlock: String?
    /// Set when Jamf-triggered items may not run this run.
    public var jamfBlock: String?
    /// The Jamf block is a failed reachability check, which may clear once the network is up.
    public var jamfRetryable: Bool

    public init(globalBlock: String?, jamfBlock: String?, jamfRetryable: Bool = false) {
        self.globalBlock = globalBlock
        self.jamfBlock = jamfBlock
        self.jamfRetryable = jamfRetryable
    }
}

public enum Safety {
    public static func check(_ g: GlobalConfig, needsJamf: Bool, probe: SystemProbe,
                             launcher: ProcessLauncher, clock: Clock,
                             resolveExecutable: (String) -> String? = { ExecutableTrust.resolve($0) }) -> SafetyResult {
        let global = globalBlock(g, probe: probe)
        // Don't spend up to 20 s asking Jamf if nothing can be installed anyway.
        guard global == nil, needsJamf else { return SafetyResult(globalBlock: global, jamfBlock: nil) }

        // Never run a jamf binary that a non-root user could have replaced.
        guard let jamf = resolveExecutable(g.jamfBinaryPath) else {
            return SafetyResult(globalBlock: nil, jamfBlock: "jamf binary missing or untrusted")
        }
        let result = runToCompletion(launcher, clock, jamf, checkArguments, timeout: 20)
        return result.succeeded ? SafetyResult(globalBlock: nil, jamfBlock: nil)
            : SafetyResult(globalBlock: nil, jamfBlock: unreachable, jamfRetryable: true)
    }

    public static let unreachable = "Jamf Pro server unreachable"
    private static let checkArguments = ["checkJSSConnection", "-retry", "0"]

    /// Re-checks the Jamf Pro server every few seconds until it answers or `until` passes.
    /// No attempt runs past `until`. `jamf` must already be the resolved, trusted binary.
    public static func waitForJamf(_ jamf: String, launcher: ProcessLauncher, clock: Clock, until: Date) -> Bool {
        while true {
            let remaining = until.timeIntervalSince(clock.now())
            guard remaining > 0 else { return false }
            if runToCompletion(launcher, clock, jamf, checkArguments, timeout: min(20, remaining)).succeeded {
                return true
            }
            let left = until.timeIntervalSince(clock.now())
            guard left > 0 else { return false }
            clock.sleep(min(5, left))
        }
    }

    private static func globalBlock(_ g: GlobalConfig, probe: SystemProbe) -> String? {
        let power = probe.power()
        if let percent = power.batteryPercent, !power.onAC {
            if g.requireAC { return "not on AC power" }
            if percent < g.minBatteryPercent { return "battery below \(g.minBatteryPercent)%" }
        }
        if probe.freeDiskGB() < g.minFreeDiskGB {
            return "less than \(formatGB(g.minFreeDiskGB)) GB free disk"
        }
        return nil
    }

    private static func formatGB(_ x: Double) -> String {
        x == x.rounded() && abs(x) < 1e15 ? String(Int(x)) : String(x)
    }
}
