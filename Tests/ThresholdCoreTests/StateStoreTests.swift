import Testing
import Foundation
@testable import ThresholdCore

private func item(_ id: String = "cisco", _ version: String = "5.1.10") throws -> Item {
    let c = try Config.parse(["items": [[
        "id": id, "appPath": "/Applications/X.app", "targetVersion": version,
        "source": "jamfTrigger", "trigger": "x",
    ] as [String: Any]]])
    return c.items[0]
}

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("threshold-state-\(UUID().uuidString)")
        .appendingPathComponent("state.json")
}

@Test func quarantineAfterMaxFailures() throws {
    var s = PersistentState()
    let i = try item()
    s.recordFailure(i); s.recordFailure(i)
    #expect(!s.isQuarantined(i, max: 3))
    s.recordFailure(i)
    #expect(s.isQuarantined(i, max: 3))
}

@Test func newTargetVersionResetsCount() throws {
    var s = PersistentState()
    s.recordFailure(try item()); s.recordFailure(try item()); s.recordFailure(try item())
    let newer = try item("cisco", "5.2.0")
    #expect(!s.isQuarantined(newer, max: 3))
    s.recordFailure(newer)
    #expect(s.failures["cisco"] == FailureRecord(targetVersion: "5.2.0", count: 1))
}

@Test func successClearsRecord() throws {
    var s = PersistentState()
    let i = try item()
    s.recordFailure(i)
    s.recordSuccess(i)
    #expect(s.failures["cisco"] == nil)
}

@Test func saveLoadRoundTrip() throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    var s = PersistentState()
    s.lastHandledBootSession = "boot-1"
    s.recordFailure(try item())
    let store = StateStore(url: url)
    try store.save(s)
    #expect(store.load() == s)
    let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    #expect(perms == 0o644)
}

@Test func corruptOrMissingLoadsEmpty() throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    #expect(StateStore(url: url).load() == PersistentState())
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("not json{".utf8).write(to: url)
    #expect(StateStore(url: url).load() == PersistentState())
}

@Test func recordFailureSaturatesAtIntMax() throws {
    var s = PersistentState()
    let i = try item()
    s.failures["cisco"] = FailureRecord(targetVersion: "5.1.10", count: Int.max)
    s.recordFailure(i)
    #expect(s.failures["cisco"]?.count == Int.max)
    #expect(s.isQuarantined(i, max: 3))
}
