import Testing
import Foundation
@testable import ThresholdCore

private struct FixedVersions: VersionReading {
    var answers: [String: InstalledVersion]
    func read(_ probe: VersionProbe) -> InstalledVersion {
        guard case let .bundle(path, _) = probe else { return .notInstalled }
        return answers[path] ?? .notInstalled
    }
}

private struct OKPackages: PackageVerifying {
    func verify(path: String, sha256: String, teamID: String) -> PackageCheck { .ok }
}

@Test func checkReportWithNoPrefsShowsDefaults() throws {
    let (json, code) = CheckReport.make(prefs: [:], state: PersistentState(),
                                        versions: FixedVersions(answers: [:]), packages: OKPackages())
    #expect(code == 0)
    let config = try #require(json["config"] as? [String: Any])
    #expect(config["capSeconds"] as? Int == 300)
    #expect(config["networkWaitSeconds"] as? Int == 30)
    #expect(config["swiftDialogPath"] == nil && config["jamfBinaryPath"] == nil)
    #expect((config["items"] as? [Any])?.isEmpty == true)
    #expect((json["invalidItems"] as? [Any])?.isEmpty == true)
    let plan = try #require(json["plan"] as? [String: Any])
    #expect((plan["work"] as? [String])?.isEmpty == true)
    #expect(try JSONSerialization.data(withJSONObject: json).isEmpty == false)
}

@Test func checkReportShowsPlanAndInvalidItems() throws {
    let prefs: [String: Any] = ["items": [
        ["id": "a", "appPath": "/Applications/A.app", "targetVersion": "2.0", "source": "jamfTrigger", "trigger": "a"],
        ["id": "b", "appPath": "/Applications/B.app", "targetVersion": "2.0", "source": "jamfTrigger", "trigger": "b"],
        ["id": "c", "appPath": "/Applications/C.app", "targetVersion": "2.0", "source": "jamfTrigger", "trigger": "c"],
        ["id": "bad"],
    ]]
    let versions = FixedVersions(answers: ["/Applications/A.app": .version(Version("1.0")!),
                                           "/Applications/B.app": .version(Version("2.0")!)])
    let (json, code) = CheckReport.make(prefs: prefs, state: PersistentState(), versions: versions,
                                        packages: OKPackages())
    #expect(code == 0)
    #expect((json["invalidItems"] as? [[String: Any]])?.first?["id"] as? String == "bad")
    let plan = try #require(json["plan"] as? [String: Any])
    #expect(plan["work"] as? [String] == ["a"])
    #expect(plan["upToDate"] as? [String] == ["b"])
    let skipped = try #require(plan["skipped"] as? [[String: Any]])
    #expect(skipped.compactMap { $0["id"] as? String } == ["bad", "c"])
    #expect(skipped.last?["reason"] as? String == "not installed")
    #expect(try JSONSerialization.data(withJSONObject: json).isEmpty == false)
}

@Test func checkReportGlobalErrorExitsTwo() {
    let (json, code) = CheckReport.make(prefs: ["capSeconds": 5], state: PersistentState(),
                                        versions: FixedVersions(answers: [:]), packages: OKPackages())
    #expect(code == 2)
    #expect((json["error"] as? String)?.contains("capSeconds") == true)
    #expect(json["plan"] == nil)
}

@Test func checkReportIncludesTestMode() throws {
    let normal = CheckReport.make(prefs: [:], state: PersistentState(),
                                  versions: FixedVersions(answers: [:]), packages: OKPackages())
    #expect(normal.json["testMode"] as? Bool == false)
    let test = CheckReport.make(source: ConfigSource(prefs: [:], testMode: true, error: nil, warning: nil),
                                state: PersistentState(), versions: FixedVersions(answers: [:]),
                                packages: OKPackages())
    #expect(test.exitCode == 0)
    #expect(test.json["testMode"] as? Bool == true)
    let broken = CheckReport.make(source: ConfigSource(prefs: [:], testMode: true, error: ConfigSource.testConfigError,
                                                       warning: nil),
                                  state: PersistentState(), versions: FixedVersions(answers: [:]),
                                  packages: OKPackages())
    #expect(broken.exitCode == 2)
    #expect(broken.json["error"] as? String == ConfigSource.testConfigError)
    #expect(broken.json["testMode"] as? Bool == true)
}

@Test func checkReportShowsFallbackTriggerAndNoRemovedKeys() throws {
    let item: [String: Any] = ["id": "cisco", "appPath": "/Applications/Cisco.app", "targetVersion": "2.0",
                               "source": "cachedPackage", "packagePath": "/Library/Caches/c.pkg",
                               "sha256": String(repeating: "a", count: 64), "teamID": "DE8Y96K9QP",
                               "fallbackTrigger": "install-cisco", "healthProcess": "vpnagentd"]
    let (json, _) = CheckReport.make(prefs: ["items": [item]], state: PersistentState(),
                                     versions: FixedVersions(answers: [:]), packages: OKPackages())
    let config = try #require(json["config"] as? [String: Any])
    let encoded = try #require((config["items"] as? [[String: Any]])?.first)
    #expect(encoded["fallbackTrigger"] as? String == "install-cisco")
    #expect(encoded["healthProcess"] as? String == "vpnagentd")
    #expect(encoded["networkCritical"] == nil)
}
