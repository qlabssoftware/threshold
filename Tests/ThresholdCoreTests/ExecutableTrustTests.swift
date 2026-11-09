import Foundation
import Testing
@testable import ThresholdCore

/// Uses the real filesystem: /bin, /usr/bin and /System are root-owned (SIP), the per-user temp dir is not.
@Suite struct ExecutableTrustTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("thr-exe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func trustedRegularFileResolvesToItself() {
        #expect(ExecutableTrust.resolve("/bin/ls") == "/bin/ls")
    }

    @Test func missingFileIsUntrusted() {
        #expect(ExecutableTrust.resolve("/nonexistent/threshold/dialog") == nil)
        #expect(ExecutableTrust.resolve("relative/dialog") == nil)
    }

    @Test func rootOwnedSymlinkInTrustedDirResolvesToTarget() {
        // /usr/bin/vi -> vim (relative link, root-owned dir)
        #expect(ExecutableTrust.resolve("/usr/bin/vi") == "/usr/bin/vim")
    }

    @Test func userOwnedFileIsUntrusted() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("dialog")
        try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(ExecutableTrust.resolve(file.path) == nil)
    }

    @Test func symlinkInUntrustedDirToTrustedTargetIsUntrusted() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.appendingPathComponent("dialog")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/bin/ls")
        // The target is trusted, but whoever owns the link's directory could repoint it.
        #expect(ExecutableTrust.resolve(link.path) == nil)
        #expect(ExecutableTrust.resolve(link.path, fileTrusted: { _ in true }) == nil)
        // Only the link location is the problem: trusting it yields the resolved target.
        #expect(ExecutableTrust.resolve(link.path, linkLocationTrusted: { _ in true }) == "/bin/ls")
    }

    @Test func everySymlinkHopMustSitInATrustedDir() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let inner = dir.appendingPathComponent("inner")
        let outer = dir.appendingPathComponent("outer")
        try FileManager.default.createSymbolicLink(atPath: inner.path, withDestinationPath: "/bin/ls")
        try FileManager.default.createSymbolicLink(atPath: outer.path, withDestinationPath: "inner")
        // Both hops are checked...
        let checked = Box<[String]>([])
        #expect(ExecutableTrust.resolve(outer.path, linkLocationTrusted: { checked.value.append($0); return true })
                == "/bin/ls")
        #expect(checked.value == [dir.path, dir.path])
        // ...and an untrusted second hop is enough to reject.
        let calls = Box(0)
        #expect(ExecutableTrust.resolve(outer.path, linkLocationTrusted: { _ in calls.value += 1; return calls.value == 1 })
                == nil)
    }

    @Test func untrustedTargetIsUntrusted() {
        #expect(ExecutableTrust.resolve("/bin/ls", fileTrusted: { _ in false }) == nil)
    }

    @Test func directoryChainTrust() throws {
        #expect(HookTrust.isTrustedDirectory(path: "/usr/bin"))
        #expect(HookTrust.isTrustedDirectory(path: "/"))
        #expect(!HookTrust.isTrustedDirectory(path: "/tmp"))     // world-writable
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!HookTrust.isTrustedDirectory(path: dir.path))  // user-owned
        #expect(!HookTrust.isTrustedDirectory(path: "/nonexistent/threshold"))
    }
}

private final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}
