import Foundation

/// Drives swiftDialog (run as the console user via `launchctl asuser`) through a command file it tails.
public final class SwiftDialogPresenter: DialogPresenting {
    private let dialogPath: String
    private let consoleUID: uid_t
    private let commandFile: URL
    private let stillFile: URL
    private let launcher: ProcessLauncher
    private let clock: Clock
    private let requiredOwnerUID: uid_t?
    private let lock = NSLock()
    private var items: [Item] = []
    private var finished: Set<Int> = []
    private var capSeconds = 300

    /// Root-owned, so a local user cannot pre-create or redirect the command files.
    public static let defaultCommandFile =
        URL(fileURLWithPath: "/Library/Application Support/Threshold/run/dialog.cmd")

    /// Newlines would start a new dialog command; commas split list-item fields.
    static func sanitize(_ s: String, commas: Bool = false) -> String {
        var out = s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        if commas { out = out.replacingOccurrences(of: ",", with: " ") }
        return out
    }

    public init(dialogPath: String, consoleUID: uid_t, commandFile: URL, launcher: ProcessLauncher,
                clock: Clock = SystemClock(),
                requiredOwnerUID: uid_t? = 0) {
        self.requiredOwnerUID = requiredOwnerUID
        self.dialogPath = dialogPath
        self.consoleUID = consoleUID
        self.commandFile = commandFile
        self.stillFile = commandFile.deletingLastPathComponent().appendingPathComponent("still.cmd")
        self.launcher = launcher
        self.clock = clock
    }

    // MARK: - Pure builders

    public static func blurArguments(items: [Item], global: GlobalConfig, commandFile: URL) -> [String] {
        var args = ["--title", sanitize(global.title), "--message", sanitize(global.message)]
        if let icon = global.icon { args += ["--icon", icon] }
        args += ["--blurscreen", "--ontop",
                 "--commandfile", commandFile.path,
                 "--timer", String(global.capSeconds + 60),
                 "--hidetimerbar", "--button1disabled",
                 // swiftDialog quits on Cmd+<quitkey>. U+E000 is a private-use character that no keyboard
                 // layout produces (unlike "§" on ISO keyboards, or U+F8FF, Option-Shift-K on US layouts),
                 // so the user can't dismiss the blur from the keyboard.
                 "--quitkey", "\u{E000}",
                 "--progress", String(items.count)]
        for item in items {
            var value = sanitize(item.displayName, commas: true)
            let icon: String?
            switch item.probe {
            case let .bundle(appPath, _): icon = item.icon ?? appPath
            case .command: icon = item.icon
            }
            if let icon { value += ",icon=\(icon)" }
            value += ",status=pending"
            args += ["--listitem", value]
        }
        return args
    }

    public static func command(index: Int, state: ItemState, detail: String?) -> String {
        let mapping: String
        switch state {
        case .pending: mapping = "status: pending, statustext: Pending"
        case .waiting: mapping = "status: pending, statustext: \(sanitize(detail ?? "Waiting", commas: true))"
        case .installing: mapping = "status: wait, statustext: Installing"
        case .verifying: mapping = "status: wait, statustext: Verifying"
        case .healthCheck: mapping = "status: wait, statustext: Checking"
        case .done: mapping = "status: success, statustext: Done"
        case .failed: mapping = "status: fail, statustext: \(sanitize(detail ?? "Failed", commas: true))"
        case .skipped: mapping = "status: error, statustext: \(sanitize(detail ?? "Skipped", commas: true))"
        case .stillRunning: mapping = "status: wait, statustext: Still installing"
        }
        return "listitem: index: \(index), " + mapping
    }

    // MARK: - DialogPresenting

    /// swiftDialog exited right after launch, so the blur never (or only briefly) appeared.
    public struct LaunchError: Error, CustomStringConvertible {
        public var exitCode: Int32?
        public var output: String
        public var description: String {
            "swiftDialog exited at launch (exit \(exitCode.map(String.init) ?? "n/a")): \(output)"
        }
    }

    /// How long a freshly launched blur must stay up before installs may start.
    static let startupWindow: TimeInterval = 2

    public func showBlur(items: [Item], global: GlobalConfig) throws {
        lock.lock(); defer { lock.unlock() }
        self.items = items
        self.capSeconds = global.capSeconds
        finished = []
        try prepare(commandFile)
        let args = Self.blurArguments(items: items, global: global, commandFile: commandFile)
        let process = try launcher.launch("/bin/launchctl", ["asuser", String(consoleUID), dialogPath] + args)
        try confirmStaysUp(process)
    }

    /// `launchctl asuser <uid> <cmd>` execs `<cmd>` in the user's bootstrap (same pid), so `process` is
    /// swiftDialog itself. The blur only exits on `quit:` or its timer, so an exit within the startup
    /// window means it failed (no GUI session, bad argument, crash): throw, so nothing installs silently.
    private func confirmStaysUp(_ process: ManagedProcess) throws {
        let start = clock.now()
        while true {
            if !process.isRunning {
                let error = LaunchError(exitCode: process.exitCode,
                                        output: process.output.trimmingCharacters(in: .whitespacesAndNewlines))
                Log.shared.error("\(error)")
                throw error
            }
            if clock.now().timeIntervalSince(start) >= Self.startupWindow { return }
            clock.sleep(0.25)
        }
    }

    public func update(index: Int, state: ItemState, detail: String?) {
        lock.lock(); defer { lock.unlock() }
        append(Self.command(index: index, state: state, detail: detail), to: commandFile)
        switch state {
        case .done, .failed, .skipped: finished.insert(index)
        default: break
        }
        append("progress: \(finished.count)", to: commandFile)
        if items.indices.contains(index) {
            append("progresstext: \(Self.sanitize(items[index].displayName)) — \(state.rawValue)", to: commandFile)
        }
    }

    public func finish(success: Bool, global: GlobalConfig) {
        lock.lock()
        append("progress: complete", to: commandFile)
        append("message: " + (success ? "All updates are installed. Thank you." : Self.sanitize(global.supportText)), to: commandFile)
        append("button1text: OK", to: commandFile)
        append("button1: enable", to: commandFile)
        lock.unlock()
        clock.sleep(3)
        lock.lock(); defer { lock.unlock() }
        append("quit:", to: commandFile)
    }

    public func showStillRunning(displayName: String) {
        lock.lock(); defer { lock.unlock() }
        do {
            try prepare(stillFile)
            let args = ["--mini", "--title", "\(Self.sanitize(displayName)) is still updating",
                        "--message", "Don't restart your Mac until it finishes.",
                        "--icon", "caution",
                        "--timer", String(capSeconds * 6),
                        "--hidetimerbar",
                        "--commandfile", stillFile.path]
            _ = try launcher.launch("/bin/launchctl", ["asuser", String(consoleUID), dialogPath] + args)
        } catch {
            Log.shared.error("could not show still-running dialog: \(error)")
        }
    }

    public func closeStillRunning() {
        lock.lock(); defer { lock.unlock() }
        append("quit:", to: stillFile)
    }

    // MARK: - Command files

    private func prepare(_ file: URL) throws {
        let fm = FileManager.default
        let dir = file.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o755])
        var st = stat()
        guard lstat(dir.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR,
              st.st_mode & 0o022 == 0,
              requiredOwnerUID.map({ st.st_uid == $0 }) ?? true else {
            throw CocoaError(.fileWriteNoPermission)
        }
        var fst = stat()
        if lstat(file.path, &fst) == 0, (fst.st_mode & S_IFMT) != S_IFREG {
            try fm.removeItem(at: file)
        }
        let fd = open(file.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o644)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        fchmod(fd, 0o644)
    }

    private func append(_ line: String, to file: URL) {
        guard let data = (line + "\n").data(using: .utf8),
              let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}

/// Why `<dialog> --version` gave no usable version.
public enum SwiftDialogVersionProblem: Error, Equatable, CustomStringConvertible {
    case timedOut(seconds: Int)
    case launchFailed(String)
    case exited(code: Int32, output: String)
    case unreadable(output: String)

    public var description: String {
        switch self {
        case .timedOut(let seconds): return "timed out after \(seconds)s"
        case .launchFailed(let detail): return detail
        case .exited(let code, let output): return "exited \(code)" + (output.isEmpty ? "" : ": \(output)")
        case .unreadable(let output): return "unreadable output: \(output.isEmpty ? "(none)" : output)"
        }
    }
}

/// Runs `<dialog> --version` and parses the leading version, e.g. "2.5.2.4777".
/// Right after login a Mac can be too busy for swiftDialog to answer quickly (seen: > 10 s with
/// swiftDialog 3.0.1), so each attempt gets `timeout` seconds and a failed attempt is retried once.
public func swiftDialogVersion(path: String, launcher: ProcessLauncher, clock: Clock,
                               timeout: TimeInterval = 60, attempts: Int = 2)
    -> Result<Version, SwiftDialogVersionProblem> {
    var problem = SwiftDialogVersionProblem.unreadable(output: "")
    for attempt in 1...max(1, attempts) {
        if attempt > 1 { clock.sleep(2) }
        let result = runToCompletion(launcher, clock, path, ["--version"], timeout: timeout)
        let output = String(result.output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        if result.timedOut {
            problem = .timedOut(seconds: Int(timeout))
        } else if let code = result.exitCode, code != 0 {
            problem = .exited(code: code, output: output)
        } else if result.exitCode == nil {
            problem = .launchFailed(output)
        } else {
            let firstLine = result.output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let token = firstLine.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            if let version = Version(token) { return .success(version) }
            // A clean exit with output we can't parse won't change on retry.
            return .failure(.unreadable(output: output))
        }
    }
    return .failure(problem)
}
