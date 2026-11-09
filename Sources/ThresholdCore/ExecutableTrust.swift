import Darwin
import Foundation

/// Decides whether a configured executable (swiftDialog, jamf) may be run as root, and what to run.
///
/// `/usr/local/bin` is often owned by a user on migrated Macs, so "the file exists" is not enough:
/// whoever can write there could make root run their code. A configured path is trusted only if
/// - its fully resolved target (realpath(3)) passes `HookTrust.isTrusted(path:)`: a root-owned regular file,
///   not group/other-writable, in a root-owned, non-writable directory chain; and
/// - every symlink followed to get there sits in a trusted directory (`HookTrust.isTrustedDirectory(path:)`),
///   so nobody but root can repoint it at another binary.
/// Callers run the returned resolved path, never the configured one.
public enum ExecutableTrust {
    /// The resolved path to execute, or nil if the file is missing or untrusted.
    public static func resolve(_ configured: String,
                               fileTrusted: (String) -> Bool = HookTrust.isTrusted(path:),
                               linkLocationTrusted: (String) -> Bool = HookTrust.isTrustedDirectory(path:)) -> String? {
        guard configured.hasPrefix("/") else { return nil }
        var current = configured
        var hops = 0
        while let target = symlinkTarget(current) {
            hops += 1
            guard hops <= 32 else { return nil }   // symlink loop
            let dir = (current as NSString).deletingLastPathComponent
            guard linkLocationTrusted(dir) else { return nil }
            current = target.hasPrefix("/") ? target : (dir as NSString).appendingPathComponent(target)
        }
        guard let resolved = realpath(configured, nil) else { return nil }
        defer { free(resolved) }
        let path = String(cString: resolved)
        return fileTrusted(path) ? path : nil
    }

    /// The link's target if `path` is a symlink, else nil.
    private static func symlinkTarget(_ path: String) -> String? {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let length = readlink(path, &buffer, buffer.count - 1)
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

extension Platform {
    /// Production wiring: the trusted, resolved path for a configured executable, or nil.
    public func trustedExecutable(_ path: String) -> String? { ExecutableTrust.resolve(path) }
}
