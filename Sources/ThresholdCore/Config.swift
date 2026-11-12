import Foundation

/// Profile settings plus fixed runtime values. `minSwiftDialogVersion`, `swiftDialogPath`, `jamfBinaryPath`,
/// `healthTimeoutSeconds` and `hookTimeoutSeconds` are not read from the profile (removed as keys 2026-11-08:
/// install-layout details, not policy); the daemon swaps in resolved, trust-checked paths at run time.
public struct GlobalConfig: Equatable {
    public var enabled: Bool
    public var capSeconds: Int
    public var maxConsecutiveFailures: Int
    public var minBatteryPercent: Int
    public var requireAC: Bool
    public var minFreeDiskGB: Double
    public var ignoredUsers: [String]
    public var minSwiftDialogVersion: Version
    public var swiftDialogPath: String
    public var jamfBinaryPath: String
    public var healthTimeoutSeconds: Int
    public var hookTimeoutSeconds: Int
    /// How long Jamf-trigger items wait for the Jamf Pro server when it is unreachable at login
    /// (Wi-Fi often joins after login). 0 = no wait: skip them, and show no blur if nothing else is due.
    public var networkWaitSeconds: Int
    public var title: String
    public var message: String
    public var icon: String?
    public var supportText: String
    /// Which swiftDialog window shows progress. `.modern` needs swiftDialog 3 and falls back to `.classic`.
    public var windowStyle: WindowStyle
    /// false: no blur and no always-on-top; the progress window still shows and can't be quit (testing,
    /// gentler rollouts).
    public var blurScreen: Bool
    /// Absolute path of a log whose newest line is shown under the item while it waits or installs; nil = off.
    public var statusLog: String?

    /// Where else the standard installers put the real binaries. Tried, in order, when the standard path
    /// fails the trust check (e.g. `/usr/local/bin` owned by a user after Migration Assistant).
    public static let swiftDialogFallbacks = [
        "/Library/Application Support/Dialog/Dialog.app/Contents/MacOS/dialogcli",   // swiftDialog 3
        "/Library/Application Support/Dialog/Dialog.app/Contents/MacOS/Dialog",      // swiftDialog 2
    ]
    public static let jamfFallbacks = ["/usr/local/jamf/bin/jamf"]
}

/// `modern`: swiftDialog Inspect Mode cards (swiftDialog 3+). `classic`: the list window (swiftDialog 2.5+).
public enum WindowStyle: String, Equatable {
    case modern, classic
    /// The first swiftDialog with Inspect Mode, item status commands and the cards layout.
    public static let modernMinimumSwiftDialog = Version("3.0.1")!
}

public enum VersionProbe: Equatable {
    case bundle(appPath: String, key: String)
    case command(String)
}

public enum ItemSource: Equatable {
    case jamfTrigger(String)
    case cachedPackage(path: String, sha256: String, teamID: String)
}

public struct HealthCheck: Equatable {
    public var process: String?
    public var command: String?
    public var url: URL?
    public var isEmpty: Bool { process == nil && command == nil && url == nil }
}

public struct Item: Equatable {
    public var id: String
    public var displayName: String
    public var icon: String?
    public var probe: VersionProbe
    public var targetVersion: Version
    public var source: ItemSource
    public var timeoutSeconds: Int
    public var preInstallScript: String?
    public var postInstallScript: String?
    public var health: HealthCheck
    /// For a cached package: the Jamf custom trigger to run instead when the package is unusable
    /// (missing, wrong checksum, bad signature, untrusted location).
    public var fallbackTrigger: String? = nil
}

public struct InvalidItem: Equatable, Codable {
    public var id: String
    public var reason: String
}

public enum ConfigError: Error, Equatable {
    case invalidGlobal(key: String, reason: String)
}

public struct Config: Equatable {
    public var global: GlobalConfig
    public var items: [Item]
    public var invalidItems: [InvalidItem]

    public static func parse(_ dict: [String: Any]) throws -> Config {
        let global = try parseGlobal(dict)
        var items: [Item] = []
        var invalid: [InvalidItem] = []
        var seen = Set<String>()

        var raw: [Any] = []
        if let value = dict["items"] {
            guard let array = value as? [Any] else {
                throw ConfigError.invalidGlobal(key: "items", reason: "must be an array of dictionaries")
            }
            raw = array
        }
        for (index, entry) in raw.enumerated() {
            let fallbackID = "item[\(index)]"
            guard let d = entry as? [String: Any] else {
                invalid.append(InvalidItem(id: fallbackID, reason: "item is not a dictionary"))
                continue
            }
            let id = (d["id"] as? String).flatMap { isValidID($0) ? $0 : nil } ?? fallbackID
            do {
                let item = try parseItem(d, defaultTimeout: global.capSeconds)
                if seen.contains(item.id) {
                    invalid.append(InvalidItem(id: item.id, reason: "duplicate id"))
                } else {
                    seen.insert(item.id)
                    items.append(item)
                }
            } catch let e as ItemFailure {
                invalid.append(InvalidItem(id: id, reason: e.reason))
            }
        }
        return Config(global: global, items: items, invalidItems: invalid)
    }

    // MARK: - Typed accessors

    private static func asBool(_ v: Any) -> Bool? {
        if let n = v as? NSNumber {
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? n.boolValue : nil
        }
        return v as? Bool
    }

    private static func asInt(_ v: Any) -> Int? {
        if let n = v as? NSNumber {
            guard CFGetTypeID(n) != CFBooleanGetTypeID(), !CFNumberIsFloatType(n) else { return nil }
            return n.intValue
        }
        return v as? Int
    }

    private static func asDouble(_ v: Any) -> Double? {
        if let n = v as? NSNumber {
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? nil : n.doubleValue
        }
        return v as? Double
    }

    // MARK: - Global

    private static func parseGlobal(_ d: [String: Any]) throws -> GlobalConfig {
        func bad(_ key: String, _ reason: String) -> ConfigError { .invalidGlobal(key: key, reason: reason) }
        func bool(_ key: String, _ def: Bool) throws -> Bool {
            guard let v = d[key] else { return def }
            guard let b = asBool(v) else { throw bad(key, "must be a boolean") }
            return b
        }
        func int(_ key: String, _ def: Int, _ range: ClosedRange<Int>) throws -> Int {
            guard let v = d[key] else { return def }
            guard let n = asInt(v), range.contains(n) else {
                let upper = range.upperBound == Int.max ? "" : " between \(range.lowerBound) and \(range.upperBound)"
                throw bad(key, upper.isEmpty ? "must be an integer of at least \(range.lowerBound)" : "must be an integer\(upper)")
            }
            return n
        }
        func string(_ key: String, _ def: String) throws -> String {
            guard let v = d[key] else { return def }
            guard let s = v as? String, !s.isEmpty else { throw bad(key, "must be a non-empty string") }
            return s
        }

        var disk = 5.0
        if let v = d["minFreeDiskGB"] {
            guard let x = asDouble(v), x >= 0, x.isFinite else { throw bad("minFreeDiskGB", "must be a non-negative number") }
            disk = x
        }
        var users: [String] = []
        if let v = d["ignoredUsers"] {
            guard let a = v as? [Any], let s = a as? [String] else { throw bad("ignoredUsers", "must be an array of strings") }
            users = s
        }
        var style = WindowStyle.modern
        if let v = d["windowStyle"] {
            guard let s = v as? String, let parsed = WindowStyle(rawValue: s.lowercased()) else {
                throw bad("windowStyle", "must be \"modern\" or \"classic\"")
            }
            style = parsed
        }
        var statusLog: String?
        if let v = d["statusLog"] {
            guard let s = v as? String else { throw bad("statusLog", "must be a string") }
            if !s.isEmpty {
                guard s.hasPrefix("/") else { throw bad("statusLog", "must be an absolute path") }
                statusLog = s
            }
        }
        var icon: String?
        if let v = d["icon"] {
            guard let s = v as? String else { throw bad("icon", "must be a string") }
            icon = s.isEmpty ? nil : s
        }

        return GlobalConfig(
            enabled: try bool("enabled", true),
            capSeconds: try int("capSeconds", 300, 30...3600),
            maxConsecutiveFailures: try int("maxConsecutiveFailures", 3, 1...Int.max),
            minBatteryPercent: try int("minBatteryPercent", 20, 0...100),
            requireAC: try bool("requireAC", false),
            minFreeDiskGB: disk,
            ignoredUsers: users,
            minSwiftDialogVersion: Version("2.5.0")!,
            swiftDialogPath: "/usr/local/bin/dialog",
            jamfBinaryPath: "/usr/local/bin/jamf",
            healthTimeoutSeconds: 60,
            hookTimeoutSeconds: 120,
            networkWaitSeconds: try int("networkWaitSeconds", 30, 0...300),
            title: try string("title", "Updating your Mac"),
            message: try string("message", "Installing important updates. This usually takes a few minutes."),
            icon: icon,
            supportText: try string("supportText", "If this keeps happening, contact IT."),
            windowStyle: style,
            blurScreen: try bool("blurScreen", true),
            statusLog: statusLog)
    }

    // MARK: - Items

    private static func isValidID(_ id: String) -> Bool {
        id.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
    }

    private struct ItemFailure: Error { let reason: String }

    private static func parseItem(_ d: [String: Any], defaultTimeout: Int) throws -> Item {
        func fail(_ r: String) -> ItemFailure { ItemFailure(reason: r) }
        func optString(_ key: String) throws -> String? {
            guard let v = d[key] else { return nil }
            guard let s = v as? String else { throw fail("\(key) must be a string") }
            return s.isEmpty ? nil : s
        }
        func absPath(_ key: String) throws -> String? {
            guard let s = try optString(key) else { return nil }
            guard s.hasPrefix("/") else { throw fail("\(key) must be an absolute path") }
            return s
        }

        guard let id = d["id"] as? String, isValidID(id) else {
            throw fail("id must be non-empty and contain only letters, digits, '.', '_' or '-'")
        }

        let appPath = try optString("appPath")
        let versionCommand = try optString("versionCommand")
        let probe: VersionProbe
        switch (appPath, versionCommand) {
        case let (app?, nil): probe = .bundle(appPath: app, key: try optString("versionKey") ?? "CFBundleShortVersionString")
        case let (nil, cmd?): probe = .command(cmd)
        default: throw fail("exactly one of appPath or versionCommand is required")
        }

        let versionString: String
        switch d["targetVersion"] {
        case let s as String: versionString = s
        case let v? where asBool(v) == nil && asInt(v) != nil: versionString = String(asInt(v)!)
        case let v? where asBool(v) == nil && asDouble(v) != nil:
            // A plist <real> loses information (5.10 reads back as 5.1), so only whole numbers are accepted.
            let x = asDouble(v)!
            guard x.isFinite, x == x.rounded(), abs(x) < 1e15 else {
                throw fail("targetVersion must be a string; use quotes for decimals")
            }
            versionString = String(Int(x))
        default: throw fail("targetVersion must be a string or number")
        }
        guard let target = Version(versionString) else { throw fail("targetVersion is not a valid version") }

        let source: ItemSource
        switch d["source"] as? String {
        case "jamfTrigger":
            guard let t = try optString("trigger"), t.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
                throw fail("jamfTrigger requires a non-empty trigger without whitespace")
            }
            source = .jamfTrigger(t)
        case "cachedPackage":
            guard let path = try absPath("packagePath") else { throw fail("cachedPackage requires an absolute packagePath") }
            let sha = (try optString("sha256") ?? "").lowercased()
            guard sha.count == 64, sha.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
                throw fail("sha256 must be 64 hex characters")
            }
            let team = try optString("teamID") ?? ""
            guard team.count == 10, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
                throw fail("teamID must be 10 alphanumeric characters")
            }
            source = .cachedPackage(path: path, sha256: sha, teamID: team)
        default:
            throw fail("source must be jamfTrigger or cachedPackage")
        }

        let fallback = try optString("fallbackTrigger")
        if let fallback {
            guard case .cachedPackage = source else {
                throw fail("fallbackTrigger is only valid with source cachedPackage")
            }
            guard fallback.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
                throw fail("fallbackTrigger must be non-empty without whitespace")
            }
        }

        var timeout = defaultTimeout
        if let v = d["timeoutSeconds"] {
            guard let n = asInt(v), n > 0 else { throw fail("timeoutSeconds must be a positive integer") }
            timeout = n
        }

        var url: URL?
        if let s = try optString("healthURL") {
            guard let u = URL(string: s), let scheme = u.scheme?.lowercased(),
                  scheme == "http" || scheme == "https", u.host?.isEmpty == false else {
                throw fail("healthURL must be an http(s) URL")
            }
            url = u
        }

        return Item(
            id: id,
            displayName: try optString("displayName") ?? id,
            icon: try optString("icon"),
            probe: probe,
            targetVersion: target,
            source: source,
            timeoutSeconds: timeout,
            preInstallScript: try absPath("preInstallScript"),
            postInstallScript: try absPath("postInstallScript"),
            health: HealthCheck(process: try optString("healthProcess"),
                                command: try optString("healthCommand"), url: url),
            fallbackTrigger: fallback)
    }
}
