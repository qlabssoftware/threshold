import Testing
import Foundation
@testable import ThresholdCore

private struct FakeProbe: SystemProbe {
    var status: PowerStatus
    var disk: Double = 100
    func power() -> PowerStatus { status }
    func freeDiskGB() -> Double { disk }
}

private func global(_ overrides: [String: Any] = [:]) throws -> GlobalConfig {
    try Config.parse(overrides).global
}

private func check(_ g: GlobalConfig, power: PowerStatus, disk: Double = 100, needsJamf: Bool = false,
                   jamfResolved: String? = "/usr/local/bin/jamf", jamfExit: Int32 = 0) -> (SafetyResult, FakeLauncher) {
    let clock = FakeClock()
    let launcher = FakeLauncher { _, _ in FakeProcess(clock: clock, runsFor: 1, exitCode: jamfExit) }
    let r = Safety.check(g, needsJamf: needsJamf, probe: FakeProbe(status: power, disk: disk),
                         launcher: launcher, clock: clock, resolveExecutable: { _ in jamfResolved })
    return (r, launcher)
}

@Test func lowBatteryBlocks() throws {
    let (r, _) = check(try global(["minBatteryPercent": 20]), power: PowerStatus(onAC: false, batteryPercent: 10))
    #expect(r.globalBlock?.contains("battery") == true)
    #expect(r.globalBlock == "battery below 20%")
    #expect(r.jamfBlock == nil)
}

@Test func lowBatteryOnACIsFine() throws {
    let (r, _) = check(try global(["minBatteryPercent": 20]), power: PowerStatus(onAC: true, batteryPercent: 10))
    #expect(r == SafetyResult(globalBlock: nil, jamfBlock: nil))
}

@Test func requireACOnBatteryBlocks() throws {
    let (r, _) = check(try global(["requireAC": true]), power: PowerStatus(onAC: false, batteryPercent: 90))
    #expect(r.globalBlock == "not on AC power")
}

@Test func noBatteryIsFine() throws {
    let (r, _) = check(try global(["requireAC": true, "minBatteryPercent": 50]),
                       power: PowerStatus(onAC: false, batteryPercent: nil))
    #expect(r.globalBlock == nil)
}

@Test func lowDiskBlocks() throws {
    let (r, _) = check(try global(["minFreeDiskGB": 5]), power: PowerStatus(onAC: true, batteryPercent: nil), disk: 2)
    #expect(r.globalBlock?.contains("disk") == true)
    #expect(r.globalBlock == "less than 5 GB free disk")
}

@Test func missingOrUntrustedJamfBinaryBlocksJamf() throws {
    let (r, launcher) = check(try global(), power: PowerStatus(onAC: true, batteryPercent: nil),
                              needsJamf: true, jamfResolved: nil)
    #expect(r.jamfBlock == "jamf binary missing or untrusted")
    #expect(r.globalBlock == nil)
    #expect(launcher.launches.isEmpty)
}

@Test func unreachableJSSBlocksJamf() throws {
    let (r, launcher) = check(try global(), power: PowerStatus(onAC: true, batteryPercent: nil),
                              needsJamf: true, jamfExit: 1)
    #expect(r.jamfBlock == "Jamf Pro server unreachable")
    #expect(launcher.launches.count == 1)
    #expect(launcher.launches.first?.executable == "/usr/local/bin/jamf")
    #expect(launcher.launches.first?.arguments == ["checkJSSConnection", "-retry", "0"])
}

@Test func hungJSSCheckTimesOutAt20Seconds() throws {
    let clock = FakeClock()
    var process: FakeProcess?
    let launcher = FakeLauncher { _, _ in
        let p = FakeProcess(clock: clock, runsFor: 1000); process = p; return p
    }
    let start = clock.now()
    let r = Safety.check(try global(), needsJamf: true, probe: FakeProbe(status: PowerStatus(onAC: true, batteryPercent: nil)),
                         launcher: launcher, clock: clock, resolveExecutable: { $0 })
    #expect(r.jamfBlock == "Jamf Pro server unreachable")
    #expect(process?.terminated == true)
    let elapsed = clock.now().timeIntervalSince(start)
    #expect(elapsed >= 20 && elapsed < 21)
}

@Test func reachableJSSIsFine() throws {
    let (r, launcher) = check(try global(), power: PowerStatus(onAC: true, batteryPercent: nil), needsJamf: true)
    #expect(r == SafetyResult(globalBlock: nil, jamfBlock: nil))
    #expect(launcher.launches.count == 1)
}

@Test func noJamfNeededNeverInvokesJamf() throws {
    let (r, launcher) = check(try global(), power: PowerStatus(onAC: true, batteryPercent: nil),
                              needsJamf: false, jamfResolved: nil, jamfExit: 1)
    #expect(r.jamfBlock == nil)
    #expect(launcher.launches.isEmpty)
}

@Test func jssCheckRunsTheResolvedJamfPath() throws {
    let (r, launcher) = check(try global(), power: PowerStatus(onAC: true, batteryPercent: nil),
                              needsJamf: true, jamfResolved: "/usr/local/jamf/bin/jamf")
    #expect(r == SafetyResult(globalBlock: nil, jamfBlock: nil))
    #expect(launcher.launches.map(\.executable) == ["/usr/local/jamf/bin/jamf"])
}

// MARK: - Network wait

@Test func unreachableIsRetryableButUntrustedBinaryIsNot() throws {
    let (unreachable, _) = check(try global(), power: PowerStatus(onAC: true, batteryPercent: nil),
                                 needsJamf: true, jamfExit: 1)
    #expect(unreachable.jamfRetryable)
    let (untrusted, _) = check(try global(), power: PowerStatus(onAC: true, batteryPercent: nil),
                               needsJamf: true, jamfResolved: nil)
    #expect(!untrusted.jamfRetryable)
}

/// A launcher whose Nth checkJSSConnection exits with exits[N] (the last value repeats).
private func sequenced(_ clock: FakeClock, _ exits: [Int32], runsFor: TimeInterval = 1) -> FakeLauncher {
    var n = 0
    return FakeLauncher { _, _ in
        let code = exits[min(n, exits.count - 1)]
        n += 1
        return FakeProcess(clock: clock, runsFor: runsFor, exitCode: code)
    }
}

@Test func waitForJamfSucceedsOnceServerAnswers() {
    let clock = FakeClock()
    let start = clock.now()
    let launcher = sequenced(clock, [1, 1, 0])
    #expect(Safety.waitForJamf("/usr/local/bin/jamf", launcher: launcher, clock: clock,
                               until: start.addingTimeInterval(30)))
    #expect(launcher.launches.count == 3)
    #expect(launcher.launches.allSatisfy { $0.arguments == ["checkJSSConnection", "-retry", "0"] })
    #expect(clock.now().timeIntervalSince(start) < 30)
}

@Test func waitForJamfGivesUpByTheDeadline() {
    let clock = FakeClock()
    let start = clock.now()
    let launcher = sequenced(clock, [1], runsFor: 1000)   // every attempt hangs
    #expect(!Safety.waitForJamf("/usr/local/bin/jamf", launcher: launcher, clock: clock,
                                until: start.addingTimeInterval(30)))
    #expect(launcher.launches.count >= 1)
    #expect(clock.now().timeIntervalSince(start) <= 31)
}

@Test func waitForJamfWithNoTimeLeftDoesNothing() {
    let clock = FakeClock()
    let launcher = sequenced(clock, [0])
    #expect(!Safety.waitForJamf("/usr/local/bin/jamf", launcher: launcher, clock: clock, until: clock.now()))
    #expect(launcher.launches.isEmpty)
}
