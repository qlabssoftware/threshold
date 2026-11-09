import Darwin
import Foundation
import IOKit.ps
import SystemConfiguration
import ThresholdCore

let preferenceDomain = "com.qlabs.threshold"
let installDirectory = URL(fileURLWithPath: "/Library/Application Support/Threshold")

/// The real machine.
final class SystemPlatform: Platform {
    let clock: Clock = SystemClock()
    let launcher: ProcessLauncher = SystemProcessLauncher()
    let probe: SystemProbe = SystemProbeImpl()
    let stateStore = StateStore(url: installDirectory.appendingPathComponent("state.json"))
    let resultsWriter = ResultsWriter(url: installDirectory.appendingPathComponent("results.json"))
    var versions: VersionReading { VersionReader(launcher: launcher, clock: clock) }
    var packages: PackageVerifying { PackageVerifier(launcher: launcher, clock: clock) }

    func managedPreferences() -> [String: Any] {
        let domain = preferenceDomain as CFString
        var keys = Set<String>()
        for host in [kCFPreferencesAnyHost, kCFPreferencesCurrentHost] {
            if let list = CFPreferencesCopyKeyList(domain, kCFPreferencesAnyUser, host) as? [String] {
                keys.formUnion(list)
            }
        }
        let managedPlist = "/Library/Managed Preferences/\(preferenceDomain).plist"
        if let dict = NSDictionary(contentsOfFile: managedPlist) as? [String: Any] {
            keys.formUnion(dict.keys)
        }
        var out: [String: Any] = [:]
        for key in keys where CFPreferencesAppValueIsForced(key as CFString, domain) {
            if let value = CFPreferencesCopyAppValue(key as CFString, domain) {
                out[key] = value
            }
        }
        return out
    }

    func consoleUser() -> (name: String, uid: uid_t)? {
        var uid: uid_t = 0
        guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as String? else { return nil }
        return (name, uid)
    }

    func bootSessionUUID() -> String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer)
    }

    func uptimeSeconds() -> TimeInterval {
        var boottime = timeval()
        var size = MemoryLayout<timeval>.size
        // Unknown uptime: report a long one, so an existing session is never blurred.
        guard sysctlbyname("kern.boottime", &boottime, &size, nil, 0) == 0, boottime.tv_sec > 0 else {
            return .infinity
        }
        let booted = TimeInterval(boottime.tv_sec) + TimeInterval(boottime.tv_usec) / 1_000_000
        return Date().timeIntervalSince1970 - booted
    }

    func fileExists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    func killStaleDialogs() {
        // Every dialog Threshold starts carries a command file from this root-owned directory.
        let pattern = SwiftDialogPresenter.defaultCommandFile.deletingLastPathComponent().path + "/"
        _ = runToCompletion(launcher, clock, "/usr/bin/pkill", ["-f", pattern], timeout: 10)
    }

    func makePresenter(uid: uid_t, global: GlobalConfig) -> DialogPresenting {
        SwiftDialogPresenter(dialogPath: global.swiftDialogPath, consoleUID: uid,
                             commandFile: SwiftDialogPresenter.defaultCommandFile, launcher: launcher, clock: clock)
    }

    /// posix_spawn with POSIX_SPAWN_SETSID: launchd reaps the daemon's process group on exit, so the
    /// child needs its own session to outlive us. stdio goes to /dev/null.
    func launchDetached(_ executable: String, _ arguments: [String]) throws {
        // Any setup failure throws: never spawn without SETSID (the child would die with us).
        func check(_ rc: Int32, _ step: String) throws {
            guard rc == 0 else {
                Log.shared.error("launchDetached: \(step) failed (\(rc))")
                throw POSIXError(POSIXErrorCode(rawValue: rc) ?? .EIO)
            }
        }
        var attr: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attr), "posix_spawnattr_init")
        defer { posix_spawnattr_destroy(&attr) }
        try check(posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID)), "posix_spawnattr_setflags")

        var actions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&actions), "posix_spawn_file_actions_init")
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0), "addopen stdin")
        try check(posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0), "addopen stdout")
        try check(posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0), "addopen stderr")

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        try check(posix_spawn(&pid, executable, &actions, &attr, argv, environ), "posix_spawn")
        // Reap it whenever it exits so it doesn't linger as a zombie while we're alive.
        DispatchQueue.global().async { var status: Int32 = 0; waitpid(pid, &status, 0) }
    }
}

struct SystemProbeImpl: SystemProbe {
    func power() -> PowerStatus {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return PowerStatus(onAC: true, batteryPercent: nil)
        }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let onAC = providing != kIOPSBatteryPowerValue
        var percent: Int?
        let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            percent = current * 100 / max
        }
        return PowerStatus(onAC: onAC, batteryPercent: percent)
    }

    /// 0 when it can't be read, so an unknown disk blocks installs rather than filling a full disk.
    func freeDiskGB() -> Double {
        let root = URL(fileURLWithPath: "/")
        if let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let bytes = values.volumeAvailableCapacityForImportantUsage, bytes > 0 {
            return Double(bytes) / 1_000_000_000
        }
        if let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
           let bytes = values.volumeAvailableCapacity {
            return Double(bytes) / 1_000_000_000
        }
        return 0
    }
}
