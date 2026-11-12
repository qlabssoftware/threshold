import Darwin
import Foundation

/// The newest line of an admin-chosen log (`statusLog`), cleaned up for a one-line status under an item.
public enum StatusLog {
    static let maxLength = 80
    /// Only the end of the file is read: logs can be large.
    static let tailBytes = 8192

    /// The newest non-empty line of the regular file at `path`, cleaned, or nil (missing, not a regular file,
    /// unreadable, empty).
    public static func latestLine(path: String) -> String? {
        let fd = open(path, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        let size = Int(st.st_size)
        let start = max(0, size - tailBytes)
        var buffer = [UInt8](repeating: 0, count: size - start)
        guard !buffer.isEmpty else { return nil }
        let count = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, off_t(start)) }
        guard count > 0 else { return nil }
        let text = String(decoding: buffer.prefix(count), as: UTF8.self)
        let lines = text.split(whereSeparator: \.isNewline)
        // A partial first line (cut by the tail) is never the newest, so it doesn't matter.
        guard let last = lines.last(where: { !$0.allSatisfy(\.isWhitespace) }) else { return nil }
        let cleaned = clean(String(last))
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Drops the usual log prefixes (date, time, host, process[pid]: or "<ISO time> LEVEL "), squeezes
    /// whitespace and shortens to `maxLength` characters.
    public static func clean(_ line: String) -> String {
        var s = line
        // syslog / install.log / jamf.log style: "... host process[123]: message"
        if let range = s.range(of: #"^.{0,120}?\S+\[\d+\]:\s*"#, options: .regularExpression) {
            s.removeSubrange(range)
        } else if let range = s.range(of: #"^\d{4}-\d{2}-\d{2}[T ][0-9:.]+Z?\s+(INFO|ERROR|WARN|WARNING|DEBUG)?\s*"#,
                                      options: .regularExpression) {
            s.removeSubrange(range)
        }
        s = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if s.count > maxLength { s = String(s.prefix(maxLength - 1)) + "…" }
        return s
    }
}
