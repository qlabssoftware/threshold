import Foundation
import Testing
@testable import ThresholdCore

struct PresenterTests {
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

    private let cmd = URL(fileURLWithPath: "/tmp/x/dialog.cmd")

    private func value(after flag: String, in args: [String]) -> String? {
        args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
    }

    @Test func blurArgs() {
        let items = [item("a", name: "Alpha"), item("b", icon: "/i.png"), item("c", app: false),
                     item("d", icon: "/d.png", app: false)]
        let args = SwiftDialogPresenter.blurArguments(items: items, global: global(icon: "/g.png"), commandFile: cmd)
        for f in ["--blurscreen", "--ontop", "--hidetimerbar", "--button1disabled"] { #expect(args.contains(f)) }
        #expect(value(after: "--commandfile", in: args) == "/tmp/x/dialog.cmd")
        #expect(value(after: "--timer", in: args) == "360")
        #expect(value(after: "--quitkey", in: args) == "\u{E000}")
        #expect(value(after: "--progress", in: args) == "4")
        #expect(value(after: "--title", in: args) == "T")
        #expect(value(after: "--message", in: args) == "M")
        #expect(value(after: "--icon", in: args) == "/g.png")
        var listItems: [String] = []
        for (i, a) in args.enumerated() where a == "--listitem" { listItems.append(args[i + 1]) }
        #expect(listItems == ["Alpha,icon=/Applications/a.app,status=pending",
                              "b,icon=/i.png,status=pending",
                              "c,status=pending",
                              "d,icon=/d.png,status=pending"])
        let noIcon = SwiftDialogPresenter.blurArguments(items: items, global: global(), commandFile: cmd)
        #expect(!noIcon.contains("--icon"))
    }

    @Test func commandMapping() {
        #expect(SwiftDialogPresenter.command(index: 0, state: .waiting, detail: "Waiting for network")
                == "listitem: index: 0, status: pending, statustext: Waiting for network")
        #expect(SwiftDialogPresenter.command(index: 0, state: .waiting, detail: nil)
                == "listitem: index: 0, status: pending, statustext: Waiting")
        #expect(SwiftDialogPresenter.command(index: 0, state: .installing, detail: nil)
                == "listitem: index: 0, status: wait, statustext: Installing")
        #expect(SwiftDialogPresenter.command(index: 1, state: .done, detail: nil)
                == "listitem: index: 1, status: success, statustext: Done")
        #expect(SwiftDialogPresenter.command(index: 1, state: .failed, detail: nil)
                == "listitem: index: 1, status: fail, statustext: Failed")
        #expect(SwiftDialogPresenter.command(index: 1, state: .failed, detail: "boom")
                == "listitem: index: 1, status: fail, statustext: boom")
        #expect(SwiftDialogPresenter.command(index: 2, state: .skipped, detail: nil)
                == "listitem: index: 2, status: error, statustext: Skipped")
        #expect(SwiftDialogPresenter.command(index: 2, state: .waiting, detail: nil)
                == "listitem: index: 2, status: pending, statustext: Waiting")
        #expect(SwiftDialogPresenter.command(index: 2, state: .stillRunning, detail: nil)
                == "listitem: index: 2, status: wait, statustext: Still installing")
    }

    private func makeDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("thr-\(UUID().uuidString)")
    }

    @Test func lifecycle() throws {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("dialog.cmd")
        let clock = FakeClock()
        let launcher = FakeLauncher { _, _ in FakeProcess(clock: clock, runsFor: 1000) }
        let p = SwiftDialogPresenter(dialogPath: "/usr/local/bin/dialog", consoleUID: 501, commandFile: file,
                                     launcher: launcher, clock: clock, requiredOwnerUID: nil)
        let items = [item("a", name: "Alpha"), item("b")]
        try p.showBlur(items: items, global: global())
        #expect(launcher.launches.count == 1)
        #expect(launcher.launches[0].executable == "/bin/launchctl")
        #expect(Array(launcher.launches[0].arguments.prefix(3)) == ["asuser", "501", "/usr/local/bin/dialog"])
        #expect(Array(launcher.launches[0].arguments.dropFirst(3))
                == SwiftDialogPresenter.blurArguments(items: items, global: global(), commandFile: file))

        p.update(index: 0, state: .installing, detail: nil)
        p.update(index: 0, state: .done, detail: nil)
        var lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.contains("listitem: index: 0, status: wait, statustext: Installing"))
        #expect(lines.contains("listitem: index: 0, status: success, statustext: Done"))
        #expect(lines.contains("progress: 1"))
        #expect(lines.contains("progresstext: Alpha — done"))

        let before = clock.now()
        p.finish(success: false, global: global())
        #expect(clock.now().timeIntervalSince(before) == 3)
        lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.suffix(5) == ["progress: complete", "message: \(global().supportText)",
                                    "button1text: OK", "button1: enable", "quit:"])

        p.showStillRunning(displayName: "Alpha")
        let still = launcher.launches[1].arguments
        #expect(value(after: "--title", in: still) == "Alpha is still updating")
        #expect(still.contains("--mini"))
        #expect(value(after: "--timer", in: still) == "1800")
        #expect(value(after: "--commandfile", in: still) == dir.appendingPathComponent("still.cmd").path)
        p.closeStillRunning()
        let stillText = try String(contentsOf: dir.appendingPathComponent("still.cmd"), encoding: .utf8)
        #expect(stillText == "quit:\n")
    }

    @Test func showBlurThrowsWhenLaunchFails() {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = FakeClock()
        let launcher = FakeLauncher { _, _ in FakeProcess(clock: clock, runsFor: 1) }
        launcher.failingExecutables = ["/bin/launchctl"]
        let p = SwiftDialogPresenter(dialogPath: "/d", consoleUID: 501,
                                     commandFile: dir.appendingPathComponent("dialog.cmd"),
                                     launcher: launcher, clock: clock, requiredOwnerUID: nil)
        #expect(throws: FakeLaunchError.self) { try p.showBlur(items: [], global: global()) }
    }

    @Test func showBlurThrowsWhenDialogExitsImmediately() throws {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = FakeClock()
        // `launchctl asuser` execs dialog, so the launched process IS dialog; here it dies at 0.5 s.
        let launcher = FakeLauncher { _, _ in
            FakeProcess(clock: clock, runsFor: 0.5, exitCode: 1, output: "Could not find user session")
        }
        let p = SwiftDialogPresenter(dialogPath: "/d", consoleUID: 501,
                                     commandFile: dir.appendingPathComponent("dialog.cmd"),
                                     launcher: launcher, clock: clock, requiredOwnerUID: nil)
        let start = clock.now()
        let error = #expect(throws: SwiftDialogPresenter.LaunchError.self) {
            try p.showBlur(items: [self.item("a")], global: self.global())
        }
        #expect(error?.output == "Could not find user session")
        #expect(error?.exitCode == 1)
        #expect(error.map { "\($0)" }?.contains("Could not find user session") == true)
        #expect(clock.now().timeIntervalSince(start) < 2)   // noticed promptly, not after the full window
    }

    @Test func showBlurWaitsTwoSecondsForDialogToStayUp() throws {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = FakeClock()
        let launcher = FakeLauncher { _, _ in FakeProcess(clock: clock, runsFor: 1000) }
        let p = SwiftDialogPresenter(dialogPath: "/d", consoleUID: 501,
                                     commandFile: dir.appendingPathComponent("dialog.cmd"),
                                     launcher: launcher, clock: clock, requiredOwnerUID: nil)
        let start = clock.now()
        try p.showBlur(items: [item("a")], global: global())
        let waited = clock.now().timeIntervalSince(start)
        #expect(waited >= 2 && waited < 2.5)
    }

    @Test func dialogDyingAtLaunchInstallsNothing() throws {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = FakeClock()
        let launcher = FakeLauncher { exe, _ in
            FakeProcess(clock: clock, runsFor: exe == "/bin/launchctl" ? 0.5 : 10)
        }
        let p = SwiftDialogPresenter(dialogPath: "/d", consoleUID: 501,
                                     commandFile: dir.appendingPathComponent("dialog.cmd"),
                                     launcher: launcher, clock: clock, requiredOwnerUID: nil)
        let config = try Config.parse(["items": [[
            "id": "a", "appPath": "/Applications/a.app", "targetVersion": "2.0", "source": "cachedPackage",
            "packagePath": "/pkg/a.pkg", "sha256": String(repeating: "a", count: 64), "teamID": "TEAM123456"]]])
        let runner = Runner(config: config, launcher: launcher, clock: clock, versions: NeverRead(), dialog: p,
                            trustedHookPath: { $0 })
        let out = runner.run(config.items.map { PlannedItem(item: $0, installed: Version("1.0")!) },
                             safety: SafetyResult(globalBlock: nil, jamfBlock: nil))
        #expect(out.results.map(\.state) == [.skipped])
        #expect(out.results.first?.reason == "swiftDialog failed to launch")
        #expect(launcher.launches.map(\.executable) == ["/bin/launchctl"])
    }

    @Test func versionParsing() {
        let clock = FakeClock()
        let ok = FakeLauncher { _, _ in FakeProcess(clock: clock, runsFor: 0, output: "2.5.2.4777\n") }
        #expect(swiftDialogVersion(path: "/d", launcher: ok, clock: clock) == .success(Version("2.5.2.4777")!))
        #expect(ok.launches.map(\.arguments) == [["--version"]])
        let bad = FakeLauncher { _, _ in FakeProcess(clock: clock, runsFor: 0, exitCode: 1, output: "2.5") }
        #expect(swiftDialogVersion(path: "/d", launcher: bad, clock: clock) == .failure(.exited(code: 1, output: "2.5")))
        #expect(bad.launches.count == 2)   // a failed run is retried once
        let junk = FakeLauncher { _, _ in FakeProcess(clock: clock, runsFor: 0, output: "hello\n") }
        #expect(swiftDialogVersion(path: "/d", launcher: junk, clock: clock) == .failure(.unreadable(output: "hello")))
        #expect(junk.launches.count == 1)  // a clean exit with junk output isn't retried
    }

    @Test func slowSwiftDialogAtLoginStillGetsAVersion() {
        // Seen on a busy Mac right after login: `dialog --version` took > 10 s.
        let clock = FakeClock()
        let slow = FakeLauncher { _, _ in FakeProcess(clock: clock, runsFor: 25, output: "3.0.1.4955\n") }
        #expect(swiftDialogVersion(path: "/d", launcher: slow, clock: clock) == .success(Version("3.0.1.4955")!))
        #expect(slow.launches.count == 1)
    }

    @Test func hungFirstVersionCheckIsRetried() {
        let clock = FakeClock()
        var calls = 0
        let flaky = FakeLauncher { _, _ in
            calls += 1
            return FakeProcess(clock: clock, runsFor: calls == 1 ? 1_000 : 0, output: "3.0.1.4955\n")
        }
        #expect(swiftDialogVersion(path: "/d", launcher: flaky, clock: clock) == .success(Version("3.0.1.4955")!))
        #expect(flaky.launches.count == 2)
    }

    @Test func versionCheckGivesUpAfterTwoTimeouts() {
        let clock = FakeClock()
        let start = clock.now()
        let hung = FakeLauncher { _, _ in FakeProcess(clock: clock, runsFor: 1_000) }
        #expect(swiftDialogVersion(path: "/d", launcher: hung, clock: clock) == .failure(.timedOut(seconds: 60)))
        #expect(hung.launches.count == 2)
        #expect(clock.now().timeIntervalSince(start) < 130)
    }

    @Test func versionCheckLaunchFailure() {
        let clock = FakeClock()
        let launcher = FakeLauncher { _, _ in FakeProcess(clock: clock, runsFor: 0) }
        launcher.failingExecutables = ["/d"]
        guard case .failure(.launchFailed) = swiftDialogVersion(path: "/d", launcher: launcher, clock: clock) else {
            Issue.record("expected launchFailed"); return
        }
    }

    @Test func wrongOwnerThrowsAndLaunchesNothing() {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = FakeClock()
        let launcher = FakeLauncher { _, _ in FakeProcess(clock: clock, runsFor: 1) }
        let p = SwiftDialogPresenter(dialogPath: "/d", consoleUID: 501,
                                     commandFile: dir.appendingPathComponent("dialog.cmd"),
                                     launcher: launcher, clock: clock, requiredOwnerUID: getuid() + 1)
        #expect(throws: (any Error).self) { try p.showBlur(items: [], global: global()) }
        #expect(launcher.launches.isEmpty)
    }

    @Test func symlinkedCommandFileIsReplaced() throws {
        let dir = makeDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("victim")
        try "keep".write(to: target, atomically: true, encoding: .utf8)
        let file = dir.appendingPathComponent("dialog.cmd")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        let clock = FakeClock()
        let launcher = FakeLauncher { _, _ in FakeProcess(clock: clock, runsFor: 1000) }
        let p = SwiftDialogPresenter(dialogPath: "/d", consoleUID: 501, commandFile: file,
                                     launcher: launcher, clock: clock, requiredOwnerUID: nil)
        try p.showBlur(items: [], global: global())
        p.update(index: 0, state: .done, detail: nil)
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect(attrs[.type] as? FileAttributeType == .typeRegular)
        #expect(try String(contentsOf: target, encoding: .utf8) == "keep")
    }

    @Test func injectionIsSanitized() throws {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("dialog.cmd")
        let clock = FakeClock()
        let launcher = FakeLauncher { _, _ in FakeProcess(clock: clock, runsFor: 1000) }
        let p = SwiftDialogPresenter(dialogPath: "/d", consoleUID: 501, commandFile: file,
                                     launcher: launcher, clock: clock, requiredOwnerUID: nil)
        let evil = item("a", name: "A,b\nquit:")
        try p.showBlur(items: [evil], global: global())
        let listItem = launcher.launches[0].arguments.first { $0.hasPrefix("A") && $0.hasSuffix("status=pending") }
        #expect(listItem == "A b quit:,status=pending" || listItem == "A b quit:,icon=/Applications/a.app,status=pending")
        p.update(index: 0, state: .failed, detail: "x,y\nquit:")
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.allSatisfy { !$0.hasPrefix("quit:") })
        #expect(lines[0] == "listitem: index: 0, status: fail, statustext: x y quit:")
    }
}

private struct NeverRead: VersionReading {
    func read(_ probe: VersionProbe) -> InstalledVersion { .unreadable("not expected") }
}

extension PresenterTests {
    @Test func classicBlurOffDropsBlurAndOnTop() {
        var g = try! Config.parse([:]).global
        g.blurScreen = false
        let args = SwiftDialogPresenter.blurArguments(items: [], global: g, commandFile: URL(fileURLWithPath: "/c"))
        #expect(!args.contains("--blurscreen") && !args.contains("--ontop"))
        #expect(args.contains("--quitkey"))   // still can't be quit
    }

    @Test func classicInstallingShowsTheStatusLine() {
        #expect(SwiftDialogPresenter.command(index: 1, state: .installing, detail: "Downloading 3,1 MB")
                == "listitem: index: 1, status: wait, statustext: Downloading 3 1 MB")
        #expect(SwiftDialogPresenter.command(index: 1, state: .installing, detail: nil)
                == "listitem: index: 1, status: wait, statustext: Installing")
    }
}
