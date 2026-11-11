import Foundation
import Testing
@testable import ThresholdCore

struct InspectPresenterTests {
    private func item(_ id: String, name: String? = nil, icon: String? = nil, app: Bool = true) -> Item {
        Item(id: id, displayName: name ?? id, icon: icon,
             probe: app ? .bundle(appPath: "/Applications/\(id).app", key: "CFBundleShortVersionString") : .command("echo 1"),
             targetVersion: Version("2")!, source: .jamfTrigger("t"), timeoutSeconds: 60,
             preInstallScript: nil, postInstallScript: nil, health: HealthCheck())
    }

    private func global(icon: String? = nil) -> GlobalConfig {
        var c = try! Config.parse([:]).global
        c.icon = icon
        c.title = "T"; c.message = "M"
        return c
    }

    private func makeDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("thr-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func configUsesCardsHidesQuitButtonAndFollowsAppearance() throws {
        let markers = URL(fileURLWithPath: "/run/done")
        let items = [item("a", name: "Alpha\nBeta"), item("b", icon: "/i.png"), item("c", app: false),
                     item("d", icon: "/d.png", app: false)]
        let c = InspectPresenter.config(items: items, global: global(), markerDirectory: markers)
        #expect(c["preset"] as? String == "preset2")
        #expect(c["button2visible"] as? Bool == false)   // button2 would quit the dialog
        #expect(c["button1disabled"] as? Bool == true)
        #expect(c["autoEnableButton"] as? Bool == false)
        #expect(c["appearance"] == nil)                   // swiftDialog follows the user's light/dark mode
        #expect(c["icon"] as? String == InspectPresenter.defaultIcon)
        #expect(c["title"] as? String == "T" && c["message"] as? String == "M")
        let entries = try #require(c["items"] as? [[String: Any]])
        #expect(entries.map { $0["id"] as? String } == ["item0", "item1", "item2", "item3"])
        #expect(entries.map { $0["guiIndex"] as? Int } == [0, 1, 2, 3])
        #expect(entries[0]["displayName"] as? String == "Alpha Beta")
        #expect(entries.map { $0["icon"] as? String } == ["/Applications/a.app", "/i.png", nil, "/d.png"])
        #expect(entries[1]["paths"] as? [String] == ["/run/done/item1"])
        #expect(InspectPresenter.config(items: [], global: global(icon: "/g.png"), markerDirectory: markers)["icon"]
                as? String == "/g.png")
    }

    @Test func commandMapping() {
        #expect(InspectPresenter.command(index: 0, state: .pending, detail: nil) == "item:item0:pending:Pending")
        #expect(InspectPresenter.command(index: 0, state: .waiting, detail: "Waiting for network")
                == "item:item0:pending:Waiting for network")
        #expect(InspectPresenter.command(index: 1, state: .installing, detail: nil) == "item:item1:installing:Installing")
        #expect(InspectPresenter.command(index: 1, state: .verifying, detail: nil) == "item:item1:installing:Verifying")
        #expect(InspectPresenter.command(index: 1, state: .healthCheck, detail: nil) == "item:item1:installing:Checking")
        #expect(InspectPresenter.command(index: 1, state: .stillRunning, detail: nil)
                == "item:item1:installing:Still installing")
        #expect(InspectPresenter.command(index: 2, state: .done, detail: nil) == "item:item2:success:Done")
        #expect(InspectPresenter.command(index: 2, state: .failed, detail: "version unchanged (1.0)")
                == "item:item2:failed:version unchanged (1.0)")
        #expect(InspectPresenter.command(index: 2, state: .skipped, detail: "battery below 20%")
                == "item:item2:failed:battery below 20%")
        #expect(InspectPresenter.command(index: 3, state: .failed, detail: "a\nquit:")
                == "item:item3:failed:a quit:")   // a newline would start a new command
    }

    @Test func fullRun() throws {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let run = dir.appendingPathComponent("run")
        let shared = dir.appendingPathComponent("dialog.log")
        try "stale: quit:\n".write(to: shared, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: run.appendingPathComponent("done"), withIntermediateDirectories: true)
        try Data().write(to: run.appendingPathComponent("done/item0"))   // left over from an earlier run

        let clock = FakeClock()
        var watchdog: FakeProcess?
        let launcher = FakeLauncher { exe, _ in
            let p = FakeProcess(clock: clock, runsFor: exe == "/bin/launchctl" ? 10_000 : 0)
            if exe == "/bin/launchctl" { watchdog = p }
            return p
        }
        let p = InspectPresenter(dialogPath: "/usr/local/bin/dialog", consoleUID: 501, runDirectory: run,
                                 commandFile: shared, launcher: launcher, clock: clock, requiredOwnerUID: nil)
        try p.showBlur(items: [item("a"), item("b")], global: global())

        let args = launcher.launches[0].arguments
        #expect(launcher.launches[0].executable == "/bin/launchctl")
        #expect(Array(args.prefix(4)) == ["asuser", "501", "/bin/sh", "-c"])
        #expect(args[4] == InspectPresenter.watchdogScript)
        #expect(Array(args.dropFirst(5)) == ["threshold-dialog", "/usr/local/bin/dialog",
                                             run.appendingPathComponent("inspect.json").path, "360", "\u{E000}"])
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: run.appendingPathComponent("inspect.json")))
        #expect((json as? [String: Any])?["preset"] as? String == "preset2")
        #expect(try String(contentsOf: shared, encoding: .utf8) == "")   // recreated empty
        #expect(!FileManager.default.fileExists(atPath: run.appendingPathComponent("done/item0").path))

        p.update(index: 0, state: .installing, detail: nil)
        p.update(index: 0, state: .done, detail: nil)
        p.update(index: 1, state: .failed, detail: "version unchanged")
        p.update(index: 7, state: .done, detail: nil)   // out of range: ignored
        #expect(FileManager.default.fileExists(atPath: run.appendingPathComponent("done/item0").path))
        #expect(!FileManager.default.fileExists(atPath: run.appendingPathComponent("done/item1").path))
        #expect(try String(contentsOf: shared, encoding: .utf8).split(separator: "\n")
                == ["item:item0:installing:Installing", "item:item0:success:Done",
                    "item:item1:failed:version unchanged"])

        let before = clock.now()
        p.finish(success: true, global: global())
        #expect(clock.now().timeIntervalSince(before) >= 3)
        #expect(watchdog?.terminated == true)
        #expect(!FileManager.default.fileExists(atPath: shared.path))   // no root-owned dialog.log left behind
        #expect(launcher.launches.count == 1)                          // SIGTERM was enough: no pkill
    }

    @Test func finishFallsBackToPkillWhenTheDialogIgnoresSigterm() throws {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = FakeClock()
        let launcher = FakeLauncher { _, _ in FakeProcess(clock: clock, runsFor: 10_000, exitsAfterTerminate: .infinity) }
        let p = InspectPresenter(dialogPath: "/d", consoleUID: 501, runDirectory: dir.appendingPathComponent("run"),
                                 commandFile: dir.appendingPathComponent("dialog.log"), launcher: launcher,
                                 clock: clock, requiredOwnerUID: nil)
        try p.showBlur(items: [item("a")], global: global())
        p.finish(success: false, global: global())
        #expect(launcher.launches.last?.executable == "/usr/bin/pkill")
        #expect(launcher.launches.last?.arguments == ["-f", dir.appendingPathComponent("run/inspect.json").path])
    }

    @Test func dialogDyingAtLaunchThrows() throws {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = FakeClock()
        let launcher = FakeLauncher { _, _ in FakeProcess(clock: clock, runsFor: 0.5, exitCode: 1, output: "no GUI") }
        let p = InspectPresenter(dialogPath: "/d", consoleUID: 501, runDirectory: dir.appendingPathComponent("run"),
                                 commandFile: dir.appendingPathComponent("dialog.log"), launcher: launcher,
                                 clock: clock, requiredOwnerUID: nil)
        #expect(throws: SwiftDialogPresenter.LaunchError.self) { try p.showBlur(items: [item("a")], global: global()) }
    }

    @Test func symlinkedSharedCommandFileIsReplacedNotFollowed() throws {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("target")
        try "keep".write(to: target, atomically: true, encoding: .utf8)
        let shared = dir.appendingPathComponent("dialog.log")
        try FileManager.default.createSymbolicLink(at: shared, withDestinationURL: target)
        try InspectPresenter.prepareSharedFile(shared)
        var st = stat()
        #expect(lstat(shared.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG)
        #expect(st.st_mode & 0o777 == 0o644)
        #expect(try String(contentsOf: target, encoding: .utf8) == "keep")
    }

    @Test func wrongOwnerThrowsAndLaunchesNothing() {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = FakeClock()
        let launcher = FakeLauncher { _, _ in FakeProcess(clock: clock, runsFor: 1) }
        let p = InspectPresenter(dialogPath: "/d", consoleUID: 501, runDirectory: dir.appendingPathComponent("run"),
                                 commandFile: dir.appendingPathComponent("dialog.log"), launcher: launcher,
                                 clock: clock, requiredOwnerUID: 0)   // tests don't run as root
        #expect(throws: (any Error).self) { try p.showBlur(items: [item("a")], global: global()) }
        #expect(launcher.launches.isEmpty)
    }

    // MARK: - The real watchdog script, with a stand-in for swiftDialog

    private func runWatchdog(dialogBody: String, timeout: String, dir: URL) throws -> Process {
        let fake = dir.appendingPathComponent("fake-dialog")
        try "#!/bin/sh\n\(dialogBody)\n".write(to: fake, atomically: true, encoding: .utf8)
        chmod(fake.path, 0o755)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", InspectPresenter.watchdogScript, "threshold-dialog", fake.path,
                       dir.appendingPathComponent("inspect.json").path, timeout, "\u{E000}"]
        try p.run()
        return p
    }

    private func waitForExit(_ p: Process, within seconds: Double) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while p.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.05) }
        return !p.isRunning
    }

    @Test func watchdogPassesArgumentsAndExitsWithTheDialog() throws {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("args").path
        let p = try runWatchdog(dialogBody: "printf '%s\\n' \"$@\" > '\(out)'; exit 3", timeout: "30", dir: dir)
        #expect(waitForExit(p, within: 5))
        #expect(p.terminationStatus == 3)
        let args = try String(contentsOfFile: out, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(args == ["--inspect-mode", "--inspect-config", dir.appendingPathComponent("inspect.json").path,
                         "--blurscreen", "--ontop", "--quitkey", "\u{E000}"])
    }

    @Test func watchdogClosesTheDialogOnSigterm() throws {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = try runWatchdog(dialogBody: "sleep 60", timeout: "60", dir: dir)
        Thread.sleep(forTimeInterval: 0.5)
        p.terminate()
        #expect(waitForExit(p, within: 5))
    }

    @Test func watchdogClosesTheDialogAtTheTimeoutOnItsOwn() throws {
        // The daemon may be dead: nothing else will close the blur.
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = try runWatchdog(dialogBody: "sleep 60", timeout: "1", dir: dir)
        #expect(waitForExit(p, within: 6))
    }
}
