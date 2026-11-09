import Foundation

public struct RunReport: Codable {
    public var runAt: Date
    public var bootSession: String
    public var user: String
    public var overall: String
    public var items: [ItemResult]
    public var skipped: [SkippedItem]
    public var upToDate: [String]
    /// True when the config came from the test-mode plist instead of managed preferences.
    public var testMode: Bool

    public init(runAt: Date, bootSession: String, user: String, overall: String,
                items: [ItemResult], skipped: [SkippedItem], upToDate: [String], testMode: Bool = false) {
        self.testMode = testMode
        self.runAt = runAt; self.bootSession = bootSession; self.user = user; self.overall = overall
        self.items = items; self.skipped = skipped; self.upToDate = upToDate
    }
}

/// "OK", or segments BLOCKED / FAILED / STILL RUNNING / QUARANTINED (in that order) joined with "; ".
/// `blocked` is the reason nothing could be installed this run, if so.
public func overallStatus(results: [ItemResult], skipped: [SkippedItem], quarantined: [String],
                          blocked: String? = nil) -> String {
    let failed = results.filter { $0.state == .failed }.map(\.id)
        + skipped.filter(\.countsAsFailure).map(\.id)
    let running = results.filter { $0.state == .stillRunning }.map(\.id)
    var segments: [String] = []
    if let blocked { segments.append("BLOCKED: " + blocked) }
    if !failed.isEmpty { segments.append("FAILED: " + failed.joined(separator: ",")) }
    if !running.isEmpty { segments.append("STILL RUNNING: " + running.joined(separator: ",")) }
    if !quarantined.isEmpty { segments.append("QUARANTINED: " + quarantined.joined(separator: ",")) }
    return segments.isEmpty ? "OK" : segments.joined(separator: "; ")
}

public struct ResultsWriter {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func write(_ r: RunReport) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(r)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    }
}
