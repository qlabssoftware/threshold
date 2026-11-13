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

/// "OK", or segments BLOCKED / FAILED / STILL RUNNING / QUARANTINED / SKIPPED (in that order) joined with "; ".
/// `blocked` is the reason nothing could be installed this run, if so.
/// SKIPPED lists items dropped at planning that didn't count as failures (e.g. a missing cached package with
/// no fallback), with their reasons, so they show in the EA instead of hiding behind "OK". Quarantined items
/// have their own segment; "not installed" (installIfMissing off) is a deliberate skip and isn't listed.
/// The planner's skip reason for a missing app when installIfMissing is off.
public let notInstalledReason = "not installed"

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
    let reported = skipped.filter {
        !$0.countsAsFailure && !quarantined.contains($0.id) && $0.reason != notInstalledReason
    }
    if !reported.isEmpty {
        segments.append("SKIPPED: " + reported.map { "\($0.id) (\($0.reason))" }.joined(separator: ", "))
    }
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
