import Foundation

public enum SessionGate {
    /// Should this daemon start treat an already-present console user as "the first login of this boot"?
    /// Only when the machine booted recently (under 10 minutes ago).
    public static func shouldRunForExistingSession(uptimeSeconds: TimeInterval) -> Bool {
        uptimeSeconds < 600
    }

    /// Case-sensitive. Rejects no user, loginwindow, system accounts (leading "_"), root and ignored users.
    public static func isEligibleUser(_ name: String?, ignored: [String]) -> Bool {
        guard let name, !name.isEmpty else { return false }
        if name == "loginwindow" || name == "root" || name.hasPrefix("_") { return false }
        return !ignored.contains(name)
    }
}
