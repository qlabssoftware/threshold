import Foundation

/// The `threshold check` output: parsed config (or the global error), invalid items and the plan,
/// as a JSONSerialization-ready dictionary, plus the exit code (2 on a global config error).
public enum CheckReport {
    public static func make(prefs: [String: Any], state: PersistentState,
                            versions: VersionReading, packages: PackageVerifying) -> (json: [String: Any], exitCode: Int32) {
        make(source: ConfigSource(prefs: prefs, testMode: false, error: nil, warning: nil), state: state,
             versions: versions, packages: packages)
    }

    public static func make(source: ConfigSource, state: PersistentState,
                            versions: VersionReading, packages: PackageVerifying) -> (json: [String: Any], exitCode: Int32) {
        if let error = source.error { return (["error": error, "testMode": source.testMode], 2) }
        let config: Config
        do {
            config = try Config.parse(source.prefs)
        } catch let ConfigError.invalidGlobal(key, reason) {
            return (["error": "\(key) \(reason)", "testMode": source.testMode], 2)
        } catch {
            return (["error": "\(error)", "testMode": source.testMode], 2)
        }
        let plan = Planner.plan(config, state: state, versions: versions, packages: packages)
        let json: [String: Any] = [
            "testMode": source.testMode,
            "config": encode(config),
            "invalidItems": config.invalidItems.map { ["id": $0.id, "reason": $0.reason] },
            "plan": [
                "work": plan.work.map(\.item.id),
                "skipped": plan.skipped.map { ["id": $0.id, "reason": $0.reason] },
                "upToDate": plan.upToDate,
            ] as [String: Any],
        ]
        return (json, 0)
    }

    private static func encode(_ config: Config) -> [String: Any] {
        let g = config.global
        var out: [String: Any] = [
            "enabled": g.enabled,
            "capSeconds": g.capSeconds,
            "maxConsecutiveFailures": g.maxConsecutiveFailures,
            "minBatteryPercent": g.minBatteryPercent,
            "requireAC": g.requireAC,
            "minFreeDiskGB": g.minFreeDiskGB,
            "ignoredUsers": g.ignoredUsers,
            "networkWaitSeconds": g.networkWaitSeconds,
            "title": g.title,
            "message": g.message,
            "supportText": g.supportText,
            "windowStyle": g.windowStyle.rawValue,
            "items": config.items.map(encode),
        ]
        if let icon = g.icon { out["icon"] = icon }
        return out
    }

    private static func encode(_ item: Item) -> [String: Any] {
        var out: [String: Any] = [
            "id": item.id,
            "displayName": item.displayName,
            "targetVersion": item.targetVersion.raw,
            "timeoutSeconds": item.timeoutSeconds,
        ]
        switch item.probe {
        case let .bundle(appPath, key): out["appPath"] = appPath; out["versionKey"] = key
        case let .command(command): out["versionCommand"] = command
        }
        switch item.source {
        case let .jamfTrigger(trigger):
            out["source"] = "jamfTrigger"; out["trigger"] = trigger
        case let .cachedPackage(path, sha256, teamID):
            out["source"] = "cachedPackage"; out["packagePath"] = path; out["sha256"] = sha256; out["teamID"] = teamID
        }
        if let icon = item.icon { out["icon"] = icon }
        if let s = item.fallbackTrigger { out["fallbackTrigger"] = s }
        if let s = item.preInstallScript { out["preInstallScript"] = s }
        if let s = item.postInstallScript { out["postInstallScript"] = s }
        if let s = item.health.process { out["healthProcess"] = s }
        if let s = item.health.command { out["healthCommand"] = s }
        if let u = item.health.url { out["healthURL"] = u.absoluteString }
        return out
    }
}
