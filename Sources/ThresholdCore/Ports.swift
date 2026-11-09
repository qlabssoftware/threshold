import Foundation

public protocol Clock: AnyObject {
    func now() -> Date
    func sleep(_ seconds: TimeInterval)
}

public final class SystemClock: Clock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }
}

public struct CommandResult: Equatable {
    public var exitCode: Int32?
    public var output: String
    public var timedOut: Bool
    public init(exitCode: Int32?, output: String, timedOut: Bool) {
        self.exitCode = exitCode; self.output = output; self.timedOut = timedOut
    }
    public var succeeded: Bool { exitCode == 0 && !timedOut }
}

public protocol ManagedProcess: AnyObject {
    var isRunning: Bool { get }
    var exitCode: Int32? { get }
    var output: String { get }
    func terminate()
    /// Whether any descendant process (child, grandchild, ...) has a name outside `benign`.
    /// false means: the root is running and every descendant is benign (or there are none);
    /// nil means unknown (the listing failed or the root has exited).
    func hasDescendant(otherThan benign: Set<String>) -> Bool?
}

public protocol ProcessLauncher {
    func launch(_ executable: String, _ arguments: [String]) throws -> ManagedProcess
}

/// Runs a command, polling every 0.1 s on `clock`; terminates it on timeout.
/// A launch failure yields `exitCode == nil`.
public func runToCompletion(_ launcher: ProcessLauncher, _ clock: Clock, _ executable: String,
                            _ arguments: [String], timeout: TimeInterval) -> CommandResult {
    let process: ManagedProcess
    do { process = try launcher.launch(executable, arguments) }
    catch { return CommandResult(exitCode: nil, output: "launch failed: \(error)", timedOut: false) }

    let deadline = clock.now().addingTimeInterval(timeout)
    while process.isRunning {
        if clock.now() >= deadline {
            process.terminate()
            // Give the process a moment to actually exit after SIGTERM.
            var waited = 0.0
            while process.isRunning && waited < 6 { clock.sleep(0.1); waited += 0.1 }
            return CommandResult(exitCode: process.exitCode, output: process.output, timedOut: true)
        }
        clock.sleep(0.1)
    }
    return CommandResult(exitCode: process.exitCode, output: process.output, timedOut: false)
}
