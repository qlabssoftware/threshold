import Foundation
import os

/// Logs to the unified log and, best effort, to a file. Never throws, never blocks on failure.
public struct Log {
    public static let shared = Log(fileURL: URL(fileURLWithPath: "/Library/Logs/Threshold/threshold.log"))

    private let logger = Logger(subsystem: "com.qlabs.threshold", category: "daemon")
    private let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func info(_ s: String) {
        logger.info("\(s, privacy: .public)")
        append("INFO", s)
    }

    public func error(_ s: String) {
        logger.error("\(s, privacy: .public)")
        append("ERROR", s)
    }

    private func append(_ level: String, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(level) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: fileURL.path) {
            _ = fm.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o644])
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
