import Testing
import Foundation
@testable import ThresholdCore

private let cisco: [String: Any] = ["id": "cisco", "displayName": "Cisco Secure Client",
  "appPath": "/Applications/Cisco/Cisco Secure Client.app", "targetVersion": "5.1.10",
  "source": "cachedPackage", "packagePath": "/Library/Application Support/JAMF/Waiting Room/csc.pkg",
  "sha256": String(repeating: "a", count: 64), "teamID": "DE8Y96K9QP",
  "healthProcess": "Cisco Secure Client"]

@Test func defaultsApplied() throws {
    let c = try Config.parse(["items": [cisco]])
    #expect(c.global.capSeconds == 300)
    #expect(c.global.enabled)
    #expect(c.items[0].timeoutSeconds == 300)
    #expect(c.items[0].probe == .bundle(appPath: "/Applications/Cisco/Cisco Secure Client.app", key: "CFBundleShortVersionString"))
}
@Test func globalDefaultsExact() throws {
    let g = try Config.parse([:]).global
    #expect(g.maxConsecutiveFailures == 3 && g.minBatteryPercent == 20 && !g.requireAC && g.minFreeDiskGB == 5)
    #expect(g.ignoredUsers == [] && g.icon == nil)
    #expect(g.minSwiftDialogVersion == Version("2.5.0")!)
    #expect(g.swiftDialogPath == "/usr/local/bin/dialog" && g.jamfBinaryPath == "/usr/local/bin/jamf")
    #expect(g.healthTimeoutSeconds == 60 && g.hookTimeoutSeconds == 120)
    #expect(g.title == "Updating your Mac")
    #expect(g.message == "Installing important updates. This usually takes a few minutes.")
    #expect(g.supportText == "If this keeps happening, contact IT.")
}
@Test func itemTimeoutDefaultsToCustomCap() throws {
    #expect(try Config.parse(["capSeconds": 120, "items": [cisco]]).items[0].timeoutSeconds == 120)
}
@Test func numericTargetVersionAccepted() throws {
    var i = cisco; i["targetVersion"] = 126
    #expect(try Config.parse(["items": [i]]).items[0].targetVersion == Version("126")!)
    var d = cisco; d["targetVersion"] = 126.0   // a plist <real> that is a whole number
    let whole = try Config.parse(["items": [d]]).items[0].targetVersion
    #expect(whole == Version("126")!)
    #expect(whole.raw == "126")
}
@Test func fractionalRealTargetVersionInvalid() throws {
    // 5.10 as a real is 5.1: the intended version is lost, so the item must be rejected, not guessed.
    for value in [126.5, 5.10] {
        var d = cisco; d["targetVersion"] = value
        let c = try Config.parse(["items": [d]])
        #expect(c.items.isEmpty)
        #expect(c.invalidItems == [InvalidItem(id: "cisco",
                                               reason: "targetVersion must be a string; use quotes for decimals")])
    }
}
@Test func badTargetVersionTypeInvalid() throws {
    var i = cisco; i["targetVersion"] = true
    let c = try Config.parse(["items": [i]])
    #expect(c.items.isEmpty && c.invalidItems.map(\.id) == ["cisco"])
}
@Test func badItemIsSkippedNotFatal() throws {
    var bad = cisco; bad["id"] = "bad"; bad["sha256"] = "xyz"
    var noSrc = cisco; noSrc["id"] = "nosrc"; noSrc["source"] = "ftp"
    let c = try Config.parse(["items": [bad, noSrc, cisco]])
    #expect(c.items.map(\.id) == ["cisco"])
    #expect(c.invalidItems.map(\.id) == ["bad", "nosrc"])
}
@Test func duplicateIDsInvalid() throws {
    let c = try Config.parse(["items": [cisco, cisco]])
    #expect(c.items.count == 1 && c.invalidItems.first?.id == "cisco")
}
@Test func badGlobalThrows() {
    #expect(throws: ConfigError.invalidGlobal(key: "capSeconds", reason: "must be an integer between 30 and 3600")) {
        try Config.parse(["capSeconds": "five"])
    }
    #expect(throws: ConfigError.self) { try Config.parse(["capSeconds": 10]) }
    #expect(throws: ConfigError.self) { try Config.parse(["minBatteryPercent": 101]) }
    #expect(throws: ConfigError.self) { try Config.parse(["items": "nope"]) }
}
@Test func jamfItemNeedsTrigger() throws {
    let j: [String: Any] = ["id": "chrome", "appPath": "/Applications/Google Chrome.app",
        "targetVersion": "130", "source": "jamfTrigger"]
    #expect(try Config.parse(["items": [j]]).invalidItems.first?.reason.contains("trigger") == true)
    var ok = j; ok["trigger"] = "installChrome"
    #expect(try Config.parse(["items": [ok]]).items.first?.source == .jamfTrigger("installChrome"))
}
@Test func probeNeedsExactlyOne() throws {
    var both = cisco; both["versionCommand"] = "/bin/echo 1"
    var neither = cisco; neither["id"] = "n"; neither.removeValue(forKey: "appPath")
    var cmd = cisco; cmd["id"] = "c"; cmd.removeValue(forKey: "appPath"); cmd["versionCommand"] = "/bin/echo 1"
    let c = try Config.parse(["items": [both, neither, cmd]])
    #expect(c.items.map(\.id) == ["c"])
    #expect(c.items[0].probe == .command("/bin/echo 1"))
    #expect(c.invalidItems.count == 2)
}
@Test func sha256LowercasedAndTeamIDChecked() throws {
    var up = cisco; up["sha256"] = String(repeating: "A", count: 64)
    #expect(try Config.parse(["items": [up]]).items[0].source ==
        .cachedPackage(path: "/Library/Application Support/JAMF/Waiting Room/csc.pkg", sha256: String(repeating: "a", count: 64), teamID: "DE8Y96K9QP"))
    var badTeam = cisco; badTeam["teamID"] = "short"
    var relPath = cisco; relPath["id"] = "r"; relPath["packagePath"] = "csc.pkg"
    let c = try Config.parse(["items": [badTeam, relPath]])
    #expect(c.items.isEmpty && c.invalidItems.count == 2)
}
@Test func hooksHealthAndIdValidation() throws {
    var hook = cisco; hook["preInstallScript"] = "relative.sh"
    var url = cisco; url["id"] = "u"; url["healthURL"] = "ftp://x"
    var badID = cisco; badID["id"] = "has space"
    var good = cisco; good["id"] = "g"; good["postInstallScript"] = "/usr/local/bin/post.sh"; good["healthURL"] = "https://x.example/health"
    let c = try Config.parse(["items": [hook, url, badID, good]])
    #expect(c.items.map(\.id) == ["g"])
    #expect(c.items[0].postInstallScript == "/usr/local/bin/post.sh")
    #expect(c.items[0].health.url == URL(string: "https://x.example/health"))
    #expect(c.items[0].health.process == "Cisco Secure Client" && !c.items[0].health.isEmpty)
    #expect(c.invalidItems.map(\.id) == ["cisco", "u", "item[2]"])
}
@Test func timeoutAndBoolHandling() throws {
    var t = cisco; t["timeoutSeconds"] = 90
    #expect(try Config.parse(["items": [t]]).items[0].timeoutSeconds == 90)
    var z = cisco; z["timeoutSeconds"] = 0
    #expect(try Config.parse(["items": [z]]).invalidItems.count == 1)
    #expect(try Config.parse(["enabled": NSNumber(value: false)]).global.enabled == false)
    #expect(try Config.parse(["items": ["notadict"]]).invalidItems.map(\.id) == ["item[0]"])
}

// MARK: - Network wait and fallback trigger

@Test func networkWaitSecondsDefaultsTo30AndAcceptsRange() throws {
    #expect(try Config.parse([:]).global.networkWaitSeconds == 30)
    #expect(try Config.parse(["networkWaitSeconds": 0]).global.networkWaitSeconds == 0)
    #expect(try Config.parse(["networkWaitSeconds": 300]).global.networkWaitSeconds == 300)
    #expect(throws: ConfigError.self) { try Config.parse(["networkWaitSeconds": -1]) }
    #expect(throws: ConfigError.self) { try Config.parse(["networkWaitSeconds": 301]) }
    #expect(throws: ConfigError.self) { try Config.parse(["networkWaitSeconds": "30"]) }
}
@Test func fallbackTriggerParsedForCachedPackage() throws {
    var item = cisco
    item["fallbackTrigger"] = "install-cisco"
    let c = try Config.parse(["items": [item]])
    #expect(c.invalidItems.isEmpty)
    #expect(c.items[0].fallbackTrigger == "install-cisco")
    #expect(try Config.parse(["items": [cisco]]).items[0].fallbackTrigger == nil)
}
@Test func fallbackTriggerRejectsWhitespaceAndJamfSource() throws {
    var spaced = cisco
    spaced["fallbackTrigger"] = "install cisco"
    #expect(try Config.parse(["items": [spaced]]).invalidItems
            == [InvalidItem(id: "cisco", reason: "fallbackTrigger must be non-empty without whitespace")])
    let jamf: [String: Any] = ["id": "chrome", "appPath": "/Applications/Google Chrome.app", "targetVersion": "130",
                               "source": "jamfTrigger", "trigger": "chrome", "fallbackTrigger": "chrome2"]
    #expect(try Config.parse(["items": [jamf]]).invalidItems
            == [InvalidItem(id: "chrome", reason: "fallbackTrigger is only valid with source cachedPackage")])
}

@Test func removedKeysAreIgnoredSoOldProfilesKeepWorking() throws {
    var item = cisco
    item["networkCritical"] = false                // health check still runs: it is set by healthProcess
    let c = try Config.parse(["items": [item], "minSwiftDialogVersion": "abc", "swiftDialogPath": "/opt/dialog",
                              "jamfBinaryPath": "/opt/jamf", "healthTimeoutSeconds": "x", "hookTimeoutSeconds": -5])
    #expect(c.invalidItems.isEmpty)
    #expect(!c.items[0].health.isEmpty)
    #expect(c.global.swiftDialogPath == "/usr/local/bin/dialog" && c.global.jamfBinaryPath == "/usr/local/bin/jamf")
    #expect(c.global.minSwiftDialogVersion == Version("2.5.0")!)
    #expect(c.global.healthTimeoutSeconds == 60 && c.global.hookTimeoutSeconds == 120)
}
