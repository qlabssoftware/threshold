import Darwin
import Foundation

/// The "modern" window: swiftDialog Inspect Mode with the cards layout (swiftDialog 3.0.1+).
///
/// Inspect Mode differs from the classic window in ways that matter here (verified on swiftDialog 3.1.1):
/// - It reads commands only from `/var/tmp/dialog.log` and ignores `--commandfile`. Threshold recreates that
///   file root-owned before launch (in sticky `/var/tmp`, nobody else can then replace it) and removes it after.
/// - An item counts as complete only once one of its `paths` exists, so Threshold creates a per-item marker in
///   a root-owned directory after the version is verified.
/// - It ignores `--timer` and `quit:`. A small `/bin/sh` watchdog runs swiftDialog, kills it after
///   capSeconds + 60 even if the daemon has died, and kills it on SIGTERM, which is how Threshold closes it.
/// - Its second button quits the dialog, and it is visible by default, so the config hides it.
public final class InspectPresenter: DialogPresenting {
    public static let defaultRunDirectory = URL(fileURLWithPath: "/Library/Application Support/Threshold/run")
    /// Fixed by swiftDialog (`InspectConstants.commandFilePath`).
    public static let sharedCommandFile = URL(fileURLWithPath: "/var/tmp/dialog.log")
    static let defaultIcon = "sf=arrow.down.app.fill"

    /// Runs swiftDialog and outlives the daemon: `$1` dialog, `$2` config, `$3` seconds until forced close,
    /// `$4` quit key, `$5` 1 = blur the screen and stay on top. Exits with swiftDialog, so a launch failure is
    /// still seen by `confirmStaysUp`.
    static let watchdogScript = """
        if [ "$5" = 1 ]; then
            "$1" --inspect-mode --inspect-config "$2" --blurscreen --ontop --quitkey "$4" &
        else
            "$1" --inspect-mode --inspect-config "$2" --quitkey "$4" &
        fi
        d=$!
        trap 'kill "$d" 2>/dev/null' TERM HUP INT
        ( sleep "$3"; kill "$d" 2>/dev/null ) &
        w=$!
        wait "$d"; rc=$?
        while kill -0 "$d" 2>/dev/null; do wait "$d"; rc=$?; done
        kill "$w" 2>/dev/null
        exit "$rc"
        """

    private let dialogPath: String
    private let consoleUID: uid_t
    private let runDirectory: URL
    private let commandFile: URL
    private let launcher: ProcessLauncher
    private let clock: Clock
    private let requiredOwnerUID: uid_t?
    /// Shows the small "still updating" window, which stays a classic swiftDialog window.
    private let stillRunning: SwiftDialogPresenter
    private let lock = NSLock()
    private var process: ManagedProcess?
    private var itemCount = 0

    var configFile: URL { runDirectory.appendingPathComponent("inspect.json") }
    var markerDirectory: URL { runDirectory.appendingPathComponent("done") }

    public init(dialogPath: String, consoleUID: uid_t, runDirectory: URL = InspectPresenter.defaultRunDirectory,
                commandFile: URL = InspectPresenter.sharedCommandFile, launcher: ProcessLauncher,
                clock: Clock = SystemClock(), requiredOwnerUID: uid_t? = 0) {
        self.dialogPath = dialogPath
        self.consoleUID = consoleUID
        self.runDirectory = runDirectory
        self.commandFile = commandFile
        self.launcher = launcher
        self.clock = clock
        self.requiredOwnerUID = requiredOwnerUID
        self.stillRunning = SwiftDialogPresenter(dialogPath: dialogPath, consoleUID: consoleUID,
                                                 commandFile: runDirectory.appendingPathComponent("dialog.cmd"),
                                                 launcher: launcher, clock: clock, requiredOwnerUID: requiredOwnerUID)
    }

    // MARK: - Pure builders

    static func itemID(_ index: Int) -> String { "item\(index)" }

    /// The Inspect Mode configuration. Appearance is left to swiftDialog, so it follows light/dark mode.
    public static func config(items: [Item], global: GlobalConfig, markerDirectory: URL) -> [String: Any] {
        let entries: [[String: Any]] = items.enumerated().map { index, item in
            var entry: [String: Any] = [
                "id": itemID(index),
                "displayName": SwiftDialogPresenter.sanitize(item.displayName),
                "guiIndex": index,
                "paths": [markerDirectory.appendingPathComponent(itemID(index)).path],
            ]
            switch item.probe {
            case let .bundle(appPath, _): entry["icon"] = item.icon ?? appPath
            case .command: if let icon = item.icon { entry["icon"] = icon }
            }
            return entry
        }
        return [
            "preset": "preset2",
            "title": SwiftDialogPresenter.sanitize(global.title),
            "message": SwiftDialogPresenter.sanitize(global.message),
            "icon": global.icon ?? defaultIcon,
            "size": "standard",
            "options": ["moveable": !global.blurScreen, "windowbuttons": ""],
            "scanInterval": 1,
            "button1text": "Please wait...",
            "button1disabled": true,
            "autoEnableButton": false,
            "button2visible": false,
            "items": entries,
        ]
    }

    /// One `item:` command. Inspect Mode knows pending, installing, success and failed; its parser splits on
    /// the first two colons, so the message may contain colons but no newlines.
    public static func command(index: Int, state: ItemState, detail: String?) -> String {
        let (status, message): (String, String)
        switch state {
        case .pending: (status, message) = ("pending", "Pending")
        case .waiting: (status, message) = ("pending", detail ?? "Waiting")
        case .installing: (status, message) = ("installing", detail ?? "Installing")
        case .verifying: (status, message) = ("installing", "Verifying")
        case .healthCheck: (status, message) = ("installing", "Checking")
        case .stillRunning: (status, message) = ("installing", "Still installing")
        case .done: (status, message) = ("success", "Done")
        case .failed: (status, message) = ("failed", detail ?? "Failed")
        case .skipped: (status, message) = ("failed", detail ?? "Skipped")
        }
        return "item:\(itemID(index)):\(status):\(SwiftDialogPresenter.sanitize(message))"
    }

    // MARK: - DialogPresenting

    public func showBlur(items: [Item], global: GlobalConfig) throws {
        lock.lock(); defer { lock.unlock() }
        itemCount = items.count
        try SwiftDialogPresenter.prepare(configFile, requiredOwnerUID: requiredOwnerUID)
        let json = try JSONSerialization.data(
            withJSONObject: Self.config(items: items, global: global, markerDirectory: markerDirectory),
            options: [.prettyPrinted, .sortedKeys])
        try json.write(to: configFile)
        try prepareMarkerDirectory()
        try Self.prepareSharedFile(commandFile)

        let quitKey = "\u{E000}"   // same as the classic window: no keyboard layout produces it
        let args = ["asuser", String(consoleUID), "/bin/sh", "-c", Self.watchdogScript, "threshold-dialog",
                    dialogPath, configFile.path, String(global.capSeconds + 60), quitKey,
                    global.blurScreen ? "1" : "0"]
        let process = try launcher.launch("/bin/launchctl", args)
        self.process = process
        try SwiftDialogPresenter.confirmStaysUp(process, clock: clock)
    }

    public func update(index: Int, state: ItemState, detail: String?) {
        lock.lock(); defer { lock.unlock() }
        guard index >= 0, index < itemCount else { return }
        if state == .done { createMarker(index) }
        SwiftDialogPresenter.append(Self.command(index: index, state: state, detail: detail), to: commandFile)
    }

    public func finish(success: Bool, global: GlobalConfig) {
        clock.sleep(3)   // let the user see the final state
        lock.lock(); defer { lock.unlock() }
        guard let process else { return }
        process.terminate()   // the watchdog's TERM trap kills swiftDialog
        var waited = 0.0
        while process.isRunning && waited < 6 { clock.sleep(0.25); waited += 0.25 }
        if process.isRunning {
            Log.shared.error("modern dialog did not close on SIGTERM; killing it")
            _ = runToCompletion(launcher, clock, "/usr/bin/pkill", ["-f", configFile.path], timeout: 10)
        }
        unlink(commandFile.path)   // don't leave a root-owned dialog.log for other swiftDialog scripts
        self.process = nil
    }

    public func showStillRunning(displayName: String) { stillRunning.showStillRunning(displayName: displayName) }
    public func closeStillRunning() { stillRunning.closeStillRunning() }

    // MARK: - Files

    /// Creates the marker directory (0755, root-owned, not writable by others) and empties it.
    private func prepareMarkerDirectory() throws {
        let fm = FileManager.default
        let dir = markerDirectory
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        var st = stat()
        guard lstat(dir.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_mode & 0o022 == 0,
              requiredOwnerUID.map({ st.st_uid == $0 }) ?? true else {
            throw CocoaError(.fileWriteNoPermission)
        }
        for name in try fm.contentsOfDirectory(atPath: dir.path) {
            try fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    private func createMarker(_ index: Int) {
        let path = markerDirectory.appendingPathComponent(Self.itemID(index)).path
        let fd = open(path, O_WRONLY | O_CREAT | O_NOFOLLOW, 0o644)
        if fd >= 0 { close(fd) } else { Log.shared.error("could not create marker \(path)") }
    }

    /// Replaces `file` with a new, empty 0644 file created by this process (O_EXCL), in a directory that may
    /// be world-writable but sticky, like /var/tmp: once we own it, only we (root) can replace it.
    static func prepareSharedFile(_ file: URL) throws {
        for _ in 0..<3 {
            if unlink(file.path) != 0 && errno != ENOENT { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
            if fd >= 0 {
                fchmod(fd, 0o644)
                close(fd)
                return
            }
            guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        throw POSIXError(.EEXIST)
    }
}
