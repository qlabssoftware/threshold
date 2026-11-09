import Foundation
import CryptoKit

// MARK: - Version reading

public enum InstalledVersion: Equatable {
    case notInstalled
    case unreadable(String)
    case version(Version)
}

public protocol VersionReading {
    func read(_ probe: VersionProbe) -> InstalledVersion
}

public struct VersionReader: VersionReading {
    private let launcher: ProcessLauncher
    private let clock: Clock

    public init(launcher: ProcessLauncher, clock: Clock) {
        self.launcher = launcher
        self.clock = clock
    }

    public func read(_ probe: VersionProbe) -> InstalledVersion {
        switch probe {
        case let .bundle(appPath, key): return readBundle(appPath: appPath, key: key)
        case let .command(command): return readCommand(command)
        }
    }

    private func readBundle(appPath: String, key: String) -> InstalledVersion {
        guard FileManager.default.fileExists(atPath: appPath) else { return .notInstalled }
        let plistURL = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { return .unreadable("Info.plist missing or unparseable") }
        guard let value = plist[key] else { return .unreadable("key \(key) not found") }
        guard let string = value as? String else { return .unreadable("key \(key) is not a string") }
        guard let version = Version(string) else { return .unreadable("unparseable version \"\(string)\"") }
        return .version(version)
    }

    private func readCommand(_ command: String) -> InstalledVersion {
        let result = runToCompletion(launcher, clock, "/bin/sh", ["-c", command], timeout: 30)
        if result.timedOut { return .unreadable("version command timed out") }
        guard result.succeeded else {
            return .unreadable("version command failed (exit \(result.exitCode.map(String.init) ?? "n/a"))")
        }
        let firstLine = result.output.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard let version = Version(firstLine) else { return .unreadable("unparseable version \"\(firstLine)\"") }
        return .version(version)
    }
}

// MARK: - Package verification

public enum PackageCheck: Equatable {
    case ok
    case missing
    case checksumMismatch
    case signatureInvalid(String)
    case teamMismatch(found: String)
    case untrustedLocation
}

public protocol PackageVerifying {
    func verify(path: String, sha256: String, teamID: String) -> PackageCheck
}

/// Extracts the Team ID, "(XXXXXXXXXX)", from the line starting "1." in `pkgutil --check-signature` output.
public func teamID(fromPkgutilOutput output: String) -> String? {
    for line in output.split(whereSeparator: \.isNewline) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("1.") else { continue }
        guard let close = trimmed.lastIndex(of: ")"), let open = trimmed[..<close].lastIndex(of: "(") else { return nil }
        let id = String(trimmed[trimmed.index(after: open)..<close])
        return id.isEmpty ? nil : id
    }
    return nil
}

public struct PackageVerifier: PackageVerifying {
    public static let defaultAllowUnsignedMarker =
        URL(fileURLWithPath: "/Library/Application Support/Threshold/THRESHOLD_ALLOW_UNSIGNED")

    private let launcher: ProcessLauncher
    private let clock: Clock
    private let allowUnsignedMarker: URL
    private let pathTrusted: (String) -> Bool

    public init(launcher: ProcessLauncher, clock: Clock,
                allowUnsignedMarker: URL = PackageVerifier.defaultAllowUnsignedMarker,
                pathTrusted: @escaping (String) -> Bool = HookTrust.isTrusted(path:)) {
        self.launcher = launcher
        self.clock = clock
        self.allowUnsignedMarker = allowUnsignedMarker
        self.pathTrusted = pathTrusted
    }

    public func verify(path: String, sha256: String, teamID expectedTeam: String) -> PackageCheck {
        guard FileManager.default.fileExists(atPath: path) else { return .missing }
        guard pathTrusted(path) else { return .untrustedLocation }
        guard let actual = Self.sha256Hex(ofFileAt: path) else { return .missing }
        guard actual.lowercased() == sha256.lowercased() else { return .checksumMismatch }

        if expectedTeam == "UNSIGNED00" && FileManager.default.fileExists(atPath: allowUnsignedMarker.path),
            pathTrusted(allowUnsignedMarker.path) {
            return .ok
        }

        let result = runToCompletion(launcher, clock, "/usr/sbin/pkgutil", ["--check-signature", path], timeout: 60)
        if result.timedOut { return .signatureInvalid("timed out") }
        guard result.succeeded else {
            let status = result.output.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix("Status:") }
            return .signatureInvalid(status ?? "pkgutil exit \(result.exitCode.map(String.init) ?? "n/a")")
        }
        guard let found = ThresholdCore.teamID(fromPkgutilOutput: result.output) else {
            return .signatureInvalid("no team ID in pkgutil output")
        }
        return found == expectedTeam ? .ok : .teamMismatch(found: found)
    }

    static func sha256Hex(ofFileAt path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            // read(upToCount:) returns nil (not empty Data) at EOF; a mid-read error just yields a wrong hash.
            guard let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Hook trust

public enum HookTrust {
    /// Trusted only if the file and every ancestor directory up to "/" are root-owned, not group/other-writable,
    /// and the file is a regular file / ancestors are real directories (no symlinks).
    /// The parent directory is canonicalized with realpath(3) first (so /etc, /var, /tmp expand to /private/...
    /// and don't false-fail); the final component is not resolved, so a symlinked file is rejected.
    public static func isTrusted(path: String) -> Bool {
        trustedCanonicalPath(path) != nil
    }

    /// `path` with its parent directory resolved by realpath(3) and the final component kept as is;
    /// nil if the parent can't be resolved. This is the path that `isTrusted(path:)` checks.
    public static func canonicalPath(_ path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard path.hasPrefix("/"), let resolved = realpath(url.deletingLastPathComponent().path, nil) else { return nil }
        defer { free(resolved) }
        let parent = String(cString: resolved)
        return (parent == "/" ? "" : parent) + "/" + url.lastPathComponent
    }

    /// The canonical path if it is trusted, else nil. Run what this returns, never the original path:
    /// a symlinked parent could be repointed between the check and the launch.
    public static func trustedCanonicalPath(_ path: String) -> String? {
        guard let canonical = canonicalPath(path), isTrusted(path: canonical, stat: lstatEntry) else { return nil }
        return canonical
    }

    /// True if the directory (resolved with realpath(3)) and every ancestor up to "/" are real directories,
    /// root-owned and not group/other-writable, i.e. only root can add, remove or replace entries in it.
    public static func isTrustedDirectory(path: String) -> Bool {
        guard path.hasPrefix("/"), let resolved = realpath(path, nil) else { return false }
        defer { free(resolved) }
        return isTrustedDirectoryChain(String(cString: resolved), stat: lstatEntry)
    }

    private static func isTrustedDirectoryChain(_ path: String, stat: (String) -> (uid: uid_t, mode: mode_t)?) -> Bool {
        var current = URL(fileURLWithPath: path)
        while true {
            guard let dir = stat(current.path),
                  (dir.mode & S_IFMT) == S_IFDIR, dir.uid == 0, (dir.mode & 0o022) == 0 else { return false }
            if current.path == "/" { return true }
            current = current.deletingLastPathComponent()
        }
    }

    /// Chain evaluation with an injectable lstat. `mode` includes the file-type bits.
    public static func isTrusted(path: String, stat: (String) -> (uid: uid_t, mode: mode_t)?) -> Bool {
        guard path.hasPrefix("/"), let file = stat(path) else { return false }
        guard isTrusted(ownerUID: file.uid, permissions: Int(file.mode & 0o7777),
                        isRegularFile: (file.mode & S_IFMT) == S_IFREG) else { return false }
        return isTrustedDirectoryChain(URL(fileURLWithPath: path).deletingLastPathComponent().path, stat: stat)
    }

    public static func isTrusted(ownerUID: uid_t, permissions: Int, isRegularFile: Bool) -> Bool {
        isRegularFile && ownerUID == 0 && (permissions & 0o022) == 0
    }

    private static func lstatEntry(_ path: String) -> (uid: uid_t, mode: mode_t)? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return (st.st_uid, st.st_mode)
    }
}
