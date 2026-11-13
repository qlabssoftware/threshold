import Foundation
import Testing
@testable import ThresholdCore

struct ResultsTests {
    private func r(_ id: String, _ state: ItemState, counts: Bool = false) -> ItemResult {
        ItemResult(id: id, displayName: id, state: state, reason: nil, versionBefore: nil,
                   versionAfter: nil, durationSeconds: 1, countsAsFailure: counts)
    }

    @Test func overallVariants() {
        #expect(overallStatus(results: [r("a", .done)], skipped: [], quarantined: []) == "OK")
        #expect(overallStatus(results: [r("a", .failed), r("b", .done)], skipped: [], quarantined: []) == "FAILED: a")
        #expect(overallStatus(results: [r("a", .failed)],
                              skipped: [SkippedItem(id: "s", reason: "x", countsAsFailure: true),
                                        SkippedItem(id: "n", reason: "x", countsAsFailure: false)],
                              quarantined: []) == "FAILED: a,s; SKIPPED: n (x)")
        #expect(overallStatus(results: [r("a", .stillRunning)], skipped: [], quarantined: []) == "STILL RUNNING: a")
        #expect(overallStatus(results: [], skipped: [], quarantined: ["q", "z"]) == "QUARANTINED: q,z")
        #expect(overallStatus(results: [r("a", .failed), r("b", .stillRunning)], skipped: [],
                              quarantined: ["q"]) == "FAILED: a; STILL RUNNING: b; QUARANTINED: q")
    }

    @Test func skippedAtPlanningIsReportedWithReasons() {
        let missing = SkippedItem(id: "zscaler", reason: "cached package missing", countsAsFailure: false)
        let hook = SkippedItem(id: "cisco", reason: "hook not trusted", countsAsFailure: false)
        let notInstalled = SkippedItem(id: "zoom", reason: "not installed", countsAsFailure: false)
        let quarantined = SkippedItem(id: "q", reason: "quarantined", countsAsFailure: false)
        #expect(overallStatus(results: [], skipped: [missing], quarantined: [])
                == "SKIPPED: zscaler (cached package missing)")
        #expect(overallStatus(results: [r("a", .done)], skipped: [missing, hook], quarantined: [])
                == "SKIPPED: zscaler (cached package missing), cisco (hook not trusted)")
        #expect(overallStatus(results: [r("a", .failed)], skipped: [quarantined, missing], quarantined: ["q"])
                == "FAILED: a; QUARANTINED: q; SKIPPED: zscaler (cached package missing)")
        // Deliberate skips stay "OK".
        #expect(overallStatus(results: [r("a", .done)], skipped: [notInstalled], quarantined: []) == "OK")
    }

    @Test func blockedComesFirst() {
        #expect(overallStatus(results: [r("a", .skipped)], skipped: [], quarantined: [],
                              blocked: "battery below 20%") == "BLOCKED: battery below 20%")
        #expect(overallStatus(results: [r("a", .skipped)], skipped: [], quarantined: ["q"],
                              blocked: "swiftDialog missing or too old")
                == "BLOCKED: swiftDialog missing or too old; QUARANTINED: q")
        #expect(overallStatus(results: [r("a", .done)], skipped: [], quarantined: [], blocked: nil) == "OK")
    }

    @Test func writerRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("thr-\(UUID().uuidString)/sub")
        let url = dir.appendingPathComponent("results.json")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let report = RunReport(runAt: Date(timeIntervalSince1970: 1_000_000), bootSession: "b", user: "alice",
                               overall: "FAILED: a; QUARANTINED: q", items: [r("a", .failed)], skipped: [],
                               upToDate: ["u"])
        try ResultsWriter(url: url).write(report)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
        p.arguments = ["-extract", "overall", "raw", url.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        #expect(String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                == "FAILED: a; QUARANTINED: q")

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("1970-01-12T13:46:40Z"))
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(perms == 0o644)
    }

    @Test func logSurvivesUnwritableDirectory() throws {
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("thr-\(UUID().uuidString)")
        try "x".write(to: blocker, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let log = blocker.appendingPathComponent("x/log")
        Log(fileURL: log).info("hello")
        Log(fileURL: log).error("hello")
        #expect(!FileManager.default.fileExists(atPath: log.path))
    }
}
