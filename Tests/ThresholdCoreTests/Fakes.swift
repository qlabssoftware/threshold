import Foundation
@testable import ThresholdCore

/// Deterministic clock: time moves only via `sleep` or `advance`.
final class FakeClock: Clock {
    private var current: Date
    init(start: Date = Date(timeIntervalSince1970: 1_000_000)) { current = start }
    func now() -> Date { current }
    func sleep(_ seconds: TimeInterval) { current = current.addingTimeInterval(seconds) }
    func advance(_ seconds: TimeInterval) { sleep(seconds) }
}

/// A scripted process whose lifetime is measured on a `FakeClock`.
final class FakeProcess: ManagedProcess {
    let runsFor: TimeInterval
    let scriptedExitCode: Int32
    let scriptedOutput: String
    /// Elapsed seconds since launch -> names of the descendant processes (nil = can't determine).
    let descendants: (TimeInterval) -> [String]?
    /// Seconds the process keeps running after `terminate()` (0 = exits at once, .infinity = never).
    let exitsAfterTerminate: TimeInterval
    /// Seconds `isRunning` still reports true after the real exit, like SystemProcess (≤ 1 s while the
    /// pipe drains). Meanwhile the descendant listing is unknown (nil), as for a real exited root.
    let exitLag: TimeInterval
    private(set) var terminatedAt: Date?
    var terminated: Bool { terminatedAt != nil }
    private let clock: FakeClock
    private let launchedAt: Date

    init(clock: FakeClock, runsFor: TimeInterval, exitCode: Int32 = 0, output: String = "",
         descendantNames: @escaping (TimeInterval) -> [String]?, exitsAfterTerminate: TimeInterval = 0,
         exitLag: TimeInterval = 0) {
        self.clock = clock; self.runsFor = runsFor
        self.scriptedExitCode = exitCode; self.scriptedOutput = output
        self.descendants = descendantNames
        self.exitsAfterTerminate = exitsAfterTerminate
        self.exitLag = exitLag
        self.launchedAt = clock.now()
    }

    /// `descendant` true means an `installer` descendant, false none, nil unknown.
    convenience init(clock: FakeClock, runsFor: TimeInterval, exitCode: Int32 = 0, output: String = "",
                     descendant: Bool? = false, exitsAfterTerminate: TimeInterval = 0) {
        self.init(clock: clock, runsFor: runsFor, exitCode: exitCode, output: output,
                  descendant: { _ in descendant }, exitsAfterTerminate: exitsAfterTerminate)
    }

    convenience init(clock: FakeClock, runsFor: TimeInterval, exitCode: Int32 = 0, output: String = "",
                     descendant: @escaping (TimeInterval) -> Bool?, exitsAfterTerminate: TimeInterval = 0) {
        self.init(clock: clock, runsFor: runsFor, exitCode: exitCode, output: output,
                  descendantNames: { t in descendant(t).map { $0 ? ["installer"] : [] } },
                  exitsAfterTerminate: exitsAfterTerminate)
    }

    var elapsed: TimeInterval { clock.now().timeIntervalSince(launchedAt) }
    /// True once the process has really exited (ignoring `exitLag`).
    private var exited: Bool {
        if elapsed >= runsFor { return true }
        guard let t = terminatedAt else { return false }
        return clock.now().timeIntervalSince(t) >= exitsAfterTerminate
    }
    private var exitTime: Date {
        let natural = launchedAt.addingTimeInterval(runsFor)
        guard let t = terminatedAt else { return natural }
        return min(natural, t.addingTimeInterval(exitsAfterTerminate))
    }
    var isRunning: Bool { !exited || clock.now() < exitTime.addingTimeInterval(exitLag) }
    var exitCode: Int32? { isRunning ? nil : (terminated ? 143 : scriptedExitCode) }
    var output: String { scriptedOutput }
    func terminate() { if !exited && terminatedAt == nil { terminatedAt = clock.now() } }
    func hasDescendant(otherThan benign: Set<String>) -> Bool? {
        guard !exited, let names = descendants(elapsed) else { return nil }
        return names.contains { !benign.contains($0) }
    }
}

struct FakeLaunchError: Error {}

final class FakeLauncher: ProcessLauncher {
    private(set) var launches: [(executable: String, arguments: [String])] = []
    var failingExecutables: Set<String> = []
    private let make: (String, [String]) -> FakeProcess

    init(_ make: @escaping (String, [String]) -> FakeProcess) { self.make = make }

    func launch(_ executable: String, _ arguments: [String]) throws -> ManagedProcess {
        launches.append((executable, arguments))
        if failingExecutables.contains(executable) { throw FakeLaunchError() }
        return make(executable, arguments)
    }
}

/// Records every DialogPresenting call in order.
final class RecordingDialog: DialogPresenting {
    enum Call: Equatable {
        case blur([String])
        case update(Int, ItemState, String?)
        case finish(Bool)
        case stillRunning(String)
        case closeStillRunning
    }
    private(set) var calls: [Call] = []
    var blurError: Error?

    func showBlur(items: [Item], global: GlobalConfig) throws {
        calls.append(.blur(items.map(\.id)))
        if let blurError { throw blurError }
    }
    func update(index: Int, state: ItemState, detail: String?) { calls.append(.update(index, state, detail)) }
    func finish(success: Bool, global: GlobalConfig) { calls.append(.finish(success)) }
    func showStillRunning(displayName: String) { calls.append(.stillRunning(displayName)) }
    func closeStillRunning() { calls.append(.closeStillRunning) }
}
