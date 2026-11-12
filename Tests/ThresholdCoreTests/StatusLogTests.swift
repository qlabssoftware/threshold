import Foundation
import Testing
@testable import ThresholdCore

struct StatusLogTests {
    private func file(_ text: String) -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("thr-log-\(UUID().uuidString)")
        try! text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    @Test func newestNonEmptyLine() {
        let path = file("first\nsecond line\n\n   \n")
        defer { unlink(path) }
        #expect(StatusLog.latestLine(path: path) == "second line")
    }

    @Test func missingEmptyOrNotAFileIsNil() {
        #expect(StatusLog.latestLine(path: "/nonexistent/thr.log") == nil)
        let empty = file("")
        defer { unlink(empty) }
        #expect(StatusLog.latestLine(path: empty) == nil)
        #expect(StatusLog.latestLine(path: NSTemporaryDirectory()) == nil)
    }

    @Test func readsOnlyTheEndOfABigLog() {
        let path = file(String(repeating: "old line\n", count: 50_000) + "newest\n")
        defer { unlink(path) }
        #expect(StatusLog.latestLine(path: path) == "newest")
    }

    @Test func prefixesAreStripped() {
        // install.log
        #expect(StatusLog.clean("2026-11-11 17:40:01-08 Mac-123 installd[512]: PackageKit: Extracting files")
                == "PackageKit: Extracting files")
        // jamf.log
        #expect(StatusLog.clean("Wed Nov 11 17:40:01 Mac-123 jamf[2210]: Installing Zoom.pkg...")
                == "Installing Zoom.pkg...")
        // Threshold's own log
        #expect(StatusLog.clean("2026-11-11T22:54:03Z INFO showing blur for a") == "showing blur for a")
        // anything else is kept
        #expect(StatusLog.clean("Downloading   Zoom   (42%)") == "Downloading Zoom (42%)")
    }

    @Test func longLinesAreShortened() {
        let line = StatusLog.clean(String(repeating: "x", count: 300))
        #expect(line.count == StatusLog.maxLength)
        #expect(line.hasSuffix("…"))
    }
}
