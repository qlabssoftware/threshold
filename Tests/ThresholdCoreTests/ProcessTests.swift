import Foundation
import Testing
@testable import ThresholdCore

@Suite struct ProcessTests {
    @Test func capturesOutputAndExit() {
        let r = runToCompletion(SystemProcessLauncher(), SystemClock(), "/bin/sh", ["-c", "echo hi; exit 3"], timeout: 5)
        #expect(r.exitCode == 3 && r.output == "hi\n" && !r.timedOut)
    }
    @Test func timeoutKills() {
        let r = runToCompletion(SystemProcessLauncher(), SystemClock(), "/bin/sleep", ["30"], timeout: 0.5)
        #expect(r.timedOut && !r.succeeded)
    }
    @Test func missingExecutable() {
        #expect(runToCompletion(SystemProcessLauncher(), SystemClock(), "/nope", [], timeout: 1).exitCode == nil)
    }
    @Test func detectsDescendant() throws {
        let p = try SystemProcessLauncher().launch("/bin/sh", ["-c", "/bin/sleep 5 & wait"])
        SystemClock().sleep(0.3)
        #expect(p.hasDescendant(otherThan: []) == true)
        #expect(p.hasDescendant(otherThan: ["curl"]) == true)
        #expect(p.hasDescendant(otherThan: ["sleep"]) == false)
        p.terminate()
    }
    @Test func largeOutputDoesNotDeadlock() {
        let r = runToCompletion(SystemProcessLauncher(), SystemClock(), "/bin/sh",
                                ["-c", "head -c 500000 /dev/zero | tr '\\0' x"], timeout: 10)
        #expect(r.exitCode == 0 && r.output.count == 500_000)
    }

    @Test func fakesBehaveAsScripted() throws {
        let clock = FakeClock()
        let start = clock.now()
        let launcher = FakeLauncher { _, _ in
            FakeProcess(clock: clock, runsFor: 1, exitCode: 7, output: "out",
                        descendant: { $0 >= 0.5 ? true : false })
        }
        let r = runToCompletion(launcher, clock, "/x", ["a"], timeout: 10)
        #expect(r == CommandResult(exitCode: 7, output: "out", timedOut: false))
        #expect(launcher.launches.count == 1 && launcher.launches[0].executable == "/x"
                && launcher.launches[0].arguments == ["a"])
        #expect(clock.now().timeIntervalSince(start) >= 1)

        let p = try launcher.launch("/y", [])
        #expect(p.isRunning && p.exitCode == nil && p.hasDescendant(otherThan: []) == false)
        clock.advance(0.6)
        #expect(p.hasDescendant(otherThan: []) == true)
        #expect(p.hasDescendant(otherThan: ["installer"]) == false)
        p.terminate()
        #expect(!p.isRunning && p.exitCode == 143)
    }
    @Test func fakeTimeoutAndLaunchFailure() {
        let clock = FakeClock()
        let launcher = FakeLauncher { _, _ in FakeProcess(clock: clock, runsFor: 100) }
        let r = runToCompletion(launcher, clock, "/x", [], timeout: 2)
        #expect(r.timedOut && !r.succeeded)
        launcher.failingExecutables = ["/bad"]
        #expect(runToCompletion(launcher, clock, "/bad", [], timeout: 2).exitCode == nil)
    }

    @Test func fakeExitLagKeepsRunningButDescendantsUnknown() {
        let clock = FakeClock()
        let p = FakeProcess(clock: clock, runsFor: 1000, descendantNames: { _ in [] }, exitLag: 0.8)
        p.terminate()
        #expect(p.isRunning && p.hasDescendant(otherThan: []) == nil)
        clock.advance(1)
        #expect(!p.isRunning && p.exitCode == 143)
    }

    @Test func fakeTerminateAfterFinishKeepsExitCode() {
        let clock = FakeClock()
        let p = FakeProcess(clock: clock, runsFor: 1, exitCode: 5)
        clock.advance(2)
        p.terminate()
        #expect(p.exitCode == 5)
    }
    @Test func descendantUnknownAfterExit() throws {
        let p = try SystemProcessLauncher().launch("/bin/sh", ["-c", "exit 0"])
        for _ in 0..<50 where p.isRunning { SystemClock().sleep(0.1) }
        #expect(!p.isRunning)
        #expect(p.hasDescendant(otherThan: []) == nil)
    }
    @Test func detectsGrandchild() throws {
        let p = try SystemProcessLauncher().launch("/bin/sh", ["-c", "/bin/sh -c \"/bin/sleep 5\" & wait"])
        SystemClock().sleep(0.5)
        // Child is `sh`, grandchild is `sleep`: the walk must reach the grandchild.
        #expect(p.hasDescendant(otherThan: ["sh"]) == true)
        #expect(p.hasDescendant(otherThan: ["sh", "sleep"]) == false)
        p.terminate()
        _ = Process.launchedProcess(launchPath: "/usr/bin/pkill", arguments: ["-f", "^/bin/sleep 5$"])
    }
    @Test func sigkillEscalationSurvivesRelease() throws {
        let pidFile = NSTemporaryDirectory() + "thr-\(UUID().uuidString).pid"
        var pid: pid_t = 0
        do {
            let p = try SystemProcessLauncher().launch(
                "/bin/sh", ["-c", "trap '' TERM; echo $$ > \(pidFile); while :; do sleep 1; done"])
            for _ in 0..<30 where !FileManager.default.fileExists(atPath: pidFile) { SystemClock().sleep(0.1) }
            SystemClock().sleep(0.2)
            pid = pid_t((try String(contentsOfFile: pidFile, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            #expect(pid > 0)
            p.terminate()
        } // handle dropped here
        SystemClock().sleep(6.5)
        errno = 0
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        try? FileManager.default.removeItem(atPath: pidFile)
    }
}
