import Testing
import Foundation
@testable import ThresholdCore

private struct FakeVersions: VersionReading {
    var byPath: [String: InstalledVersion]
    func read(_ probe: VersionProbe) -> InstalledVersion {
        if case let .bundle(path, _) = probe { return byPath[path] ?? .notInstalled }
        return .notInstalled
    }
}

private final class FakePackages: PackageVerifying {
    var byPath: [String: PackageCheck] = [:]
    private(set) var calls: [String] = []
    func verify(path: String, sha256: String, teamID: String) -> PackageCheck {
        calls.append(path)
        return byPath[path] ?? .ok
    }
}

private func pkgItem(_ id: String, target: String = "2.0") -> [String: Any] {
    ["id": id, "displayName": id, "appPath": "/Applications/\(id).app", "targetVersion": target,
     "source": "cachedPackage", "packagePath": "/pkg/\(id).pkg",
     "sha256": String(repeating: "a", count: 64), "teamID": "TEAM123456"]
}
private func jamfItem(_ id: String, target: String = "2.0") -> [String: Any] {
    ["id": id, "displayName": id, "appPath": "/Applications/\(id).app", "targetVersion": target,
     "source": "jamfTrigger", "trigger": "install\(id)"]
}
private func v(_ s: String) -> InstalledVersion { .version(Version(s)!) }
private func plan(_ items: [[String: Any]], _ installed: [String: InstalledVersion],
                  pkgs: FakePackages = FakePackages(), state: PersistentState = PersistentState(),
                  hookTrusted: @escaping (String) -> Bool = { _ in true }) throws -> Plan {
    let config = try Config.parse(["items": items])
    var map: [String: InstalledVersion] = [:]
    for (k, val) in installed { map["/Applications/\(k).app"] = val }
    return Planner.plan(config, state: state, versions: FakeVersions(byPath: map), packages: pkgs,
                        hookTrusted: hookTrusted)
}

@Test func olderInstalledIsWork() throws {
    let p = try plan([pkgItem("a")], ["a": v("1.0")])
    #expect(p.work.map(\.item.id) == ["a"])
    #expect(p.work[0].installed == Version("1.0")!)
    #expect(p.hasWork)
}
@Test func upToDateSkipsVerifier() throws {
    let pkgs = FakePackages()
    let p = try plan([pkgItem("a"), pkgItem("b")], ["a": v("2.0"), "b": v("3.0")], pkgs: pkgs)
    #expect(p.upToDate == ["a", "b"] && !p.hasWork && p.work.isEmpty && p.skipped.isEmpty)
    #expect(pkgs.calls.isEmpty)
}
@Test func notInstalledSkipped() throws {
    let p = try plan([jamfItem("a")], ["a": .notInstalled])
    #expect(p.skipped == [SkippedItem(id: "a", reason: "not installed", countsAsFailure: false)])
    #expect(!p.hasWork)
}
@Test func unreadableSkipped() throws {
    let p = try plan([jamfItem("a")], ["a": .unreadable("bad plist")])
    #expect(p.skipped == [SkippedItem(id: "a", reason: "version unreadable: bad plist", countsAsFailure: false)])
}
@Test func quarantinedSkippedWithoutReading() throws {
    let config = try Config.parse(["items": [jamfItem("a")]])
    var state = PersistentState()
    for _ in 0..<config.global.maxConsecutiveFailures { state.recordFailure(config.items[0]) }
    let p = Planner.plan(config, state: state, versions: FakeVersions(byPath: ["/Applications/a.app": v("1.0")]), packages: FakePackages())
    #expect(p.skipped == [SkippedItem(id: "a", reason: "quarantined", countsAsFailure: false)])
    #expect(p.work.isEmpty)
}
@Test(arguments: [
    (PackageCheck.missing, "cached package missing"),
    (.untrustedLocation, "cached package in untrusted location"),
    (.checksumMismatch, "cached package checksum mismatch"),
    (.signatureInvalid("expired"), "cached package signature invalid: expired"),
    (.teamMismatch(found: "OTHER"), "cached package team ID mismatch: OTHER"),
])
func packageFailuresSkipped(check: PackageCheck, reason: String) throws {
    let pkgs = FakePackages()
    pkgs.byPath["/pkg/a.pkg"] = check
    let p = try plan([pkgItem("a")], ["a": v("1.0")], pkgs: pkgs)
    #expect(p.skipped == [SkippedItem(id: "a", reason: reason, countsAsFailure: false)])
    #expect(!p.hasWork)
}
@Test func jamfItemsNeverVerified() throws {
    let pkgs = FakePackages()
    let p = try plan([jamfItem("a")], ["a": v("1.0")], pkgs: pkgs)
    #expect(p.work.count == 1 && pkgs.calls.isEmpty)
}
@Test func invalidItemsFirstThenConfigOrder() throws {
    let bad: [String: Any] = ["id": "bad", "displayName": "Bad"]
    let p = try plan([pkgItem("a"), bad, jamfItem("b"), pkgItem("c")],
                     ["a": v("1.0"), "b": .notInstalled, "c": v("1.0")])
    #expect(p.skipped.first?.id == "bad")
    #expect(p.skipped.first?.reason.hasPrefix("invalid config: ") == true)
    #expect(p.skipped.first?.countsAsFailure == false)
    #expect(p.skipped.map(\.id) == ["bad", "b"])
    #expect(p.work.map(\.item.id) == ["a", "c"])
}

@Test func untrustedHooksSkipWithoutCounting() throws {
    var pre = pkgItem("pre"); pre["preInstallScript"] = "/hooks/bad.sh"
    var post = jamfItem("post"); post["postInstallScript"] = "/hooks/bad.sh"
    var ok = pkgItem("ok"); ok["preInstallScript"] = "/hooks/good.sh"; ok["postInstallScript"] = "/hooks/good.sh"
    let pkgs = FakePackages()
    let p = try plan([pre, post, ok], ["pre": v("1.0"), "post": v("1.0"), "ok": v("1.0")], pkgs: pkgs,
                     hookTrusted: { $0 == "/hooks/good.sh" })
    #expect(p.skipped == [SkippedItem(id: "pre", reason: "hook not trusted", countsAsFailure: false),
                          SkippedItem(id: "post", reason: "hook not trusted", countsAsFailure: false)])
    #expect(p.work.map(\.item.id) == ["ok"])
    #expect(pkgs.calls == ["/pkg/ok.pkg"])   // no package work for a skipped item
}

@Test func upToDateItemNeverConsultsHookTrust() throws {
    var a = pkgItem("a"); a["preInstallScript"] = "/hooks/bad.sh"
    var asked = false
    let p = try plan([a], ["a": v("2.0")], hookTrusted: { _ in asked = true; return false })
    #expect(p.upToDate == ["a"] && p.skipped.isEmpty && !asked)
}

@Test func cachedPackageIsVerifiedAndPlannedAtItsCanonicalPath() throws {
    var a = pkgItem("a"); a["packagePath"] = "/tmp/a.pkg"   // /tmp -> /private/tmp
    let pkgs = FakePackages()
    let p = try plan([a], ["a": v("1.0")], pkgs: pkgs)
    #expect(pkgs.calls == ["/private/tmp/a.pkg"])
    guard case let .cachedPackage(path, _, _) = try #require(p.work.first).item.source else {
        Issue.record("not a cached package"); return
    }
    #expect(path == "/private/tmp/a.pkg")
}

// MARK: - Fallback trigger

private func withFallback(_ item: [String: Any], _ trigger: String = "fallback-a") -> [String: Any] {
    var d = item
    d["fallbackTrigger"] = trigger
    return d
}

@Test func unusableCachedPackageFallsBackToTrigger() throws {
    let cases: [(PackageCheck, String)] = [
        (.missing, "cached package missing"),
        (.checksumMismatch, "cached package checksum mismatch"),
        (.untrustedLocation, "cached package in untrusted location"),
        (.teamMismatch(found: "OTHER12345"), "cached package team ID mismatch: OTHER12345"),
        (.signatureInvalid("no signature"), "cached package signature invalid: no signature"),
    ]
    for (check, reason) in cases {
        let pkgs = FakePackages()
        pkgs.byPath["/pkg/a.pkg"] = check
        let p = try plan([withFallback(pkgItem("a"))], ["a": v("1.0")], pkgs: pkgs)
        #expect(p.skipped.isEmpty)
        #expect(p.work.count == 1)
        #expect(p.work.first?.item.source == .jamfTrigger("fallback-a"))
        #expect(p.work.first?.note == "\(reason); used fallback trigger")
    }
}

@Test func usableCachedPackageIgnoresFallback() throws {
    let p = try plan([withFallback(pkgItem("a"))], ["a": v("1.0")])
    #expect(p.work.first?.item.source == .cachedPackage(path: "/pkg/a.pkg", sha256: String(repeating: "a", count: 64),
                                                        teamID: "TEAM123456"))
    #expect(p.work.first?.note == nil)
}

@Test func noFallbackStillSkips() throws {
    let pkgs = FakePackages()
    pkgs.byPath["/pkg/a.pkg"] = .missing
    let p = try plan([pkgItem("a")], ["a": v("1.0")], pkgs: pkgs)
    #expect(p.work.isEmpty)
    #expect(p.skipped == [SkippedItem(id: "a", reason: "cached package missing", countsAsFailure: false)])
}

@Test func missingAppIsInstalledWhenInstallIfMissing() throws {
    var a = jamfItem("a"); a["installIfMissing"] = true
    var b = pkgItem("b"); b["installIfMissing"] = true
    let p = try plan([a, b, jamfItem("c")], ["a": .notInstalled, "b": .notInstalled, "c": .notInstalled])
    #expect(p.work.map(\.item.id) == ["a", "b"])
    #expect(p.work.map(\.installed) == [Version("0")!, Version("0")!])
    #expect(p.skipped == [SkippedItem(id: "c", reason: "not installed", countsAsFailure: false)])
}

@Test func installIfMissingDoesNothingWhenTheAppIsCurrent() throws {
    var a = jamfItem("a"); a["installIfMissing"] = true
    let p = try plan([a], ["a": v("2.0")])
    #expect(p.upToDate == ["a"] && !p.hasWork)
}
