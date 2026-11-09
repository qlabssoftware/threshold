import Foundation

/// Where the daemon reads its configuration from, and what to tell the operator about it.
///
/// Normally that is the managed preferences of `com.qlabs.threshold`. Unmanaged test VMs have no MDM
/// (and macOS wipes `/Library/Managed Preferences` at boot), so a root-owned marker file switches the
/// daemon to a plist next to it. Never create the marker on a production Mac.
public struct ConfigSource {
    public static let supportDirectory = "/Library/Application Support/Threshold"
    public static let testModeMarker = supportDirectory + "/THRESHOLD_TEST_MODE"
    public static let testConfigPath = supportDirectory + "/test-config.plist"
    public static let testConfigError = "test mode: test-config.plist missing or untrusted"
    public static let testModeLogLine = "TEST MODE: config from test-config.plist (managed preferences ignored)"

    /// The preference dictionary to parse (empty when `error` is set).
    public var prefs: [String: Any]
    /// True when the config came from test-config.plist (or should have).
    public var testMode: Bool
    /// A global config error that must stop the run; never falls back to managed preferences.
    public var error: String?
    /// Something worth logging, e.g. an untrusted marker that was ignored.
    public var warning: String?

    /// - Parameters:
    ///   - fileExists: whether a path exists.
    ///   - isTrusted: root-owned, not group/other-writable, whole chain (`HookTrust.isTrusted(path:)`).
    ///   - readPlist: the plist at a path as a dictionary, nil if unreadable or not a dictionary.
    ///   - managed: the forced managed preferences.
    public static func resolve(fileExists: (String) -> Bool, isTrusted: (String) -> Bool,
                               readPlist: (String) -> [String: Any]?,
                               managed: () -> [String: Any]) -> ConfigSource {
        guard fileExists(testModeMarker) else {
            return ConfigSource(prefs: managed(), testMode: false, error: nil, warning: nil)
        }
        guard isTrusted(testModeMarker) else {
            return ConfigSource(prefs: managed(), testMode: false, error: nil,
                                warning: "ignoring untrusted \(testModeMarker); using managed preferences")
        }
        guard fileExists(testConfigPath), isTrusted(testConfigPath), let dict = readPlist(testConfigPath) else {
            return ConfigSource(prefs: [:], testMode: true, error: testConfigError, warning: nil)
        }
        return ConfigSource(prefs: dict, testMode: true, error: nil, warning: nil)
    }
}

public func readPlistDictionary(_ path: String) -> [String: Any]? {
    NSDictionary(contentsOfFile: path) as? [String: Any]
}

extension Platform {
    /// Production wiring; tests override it with fakes.
    public func configSource() -> ConfigSource {
        ConfigSource.resolve(fileExists: fileExists, isTrusted: HookTrust.isTrusted(path:),
                             readPlist: readPlistDictionary, managed: managedPreferences)
    }
}
