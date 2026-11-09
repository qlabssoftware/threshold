import Darwin
import Foundation

public final class SystemProcessLauncher: ProcessLauncher {
    public init() {}
    public func launch(_ executable: String, _ arguments: [String]) throws -> ManagedProcess {
        try SystemProcess(executable, arguments)
    }
}

final class SystemProcess: ManagedProcess {
    private let process = Process()
    private let lock = NSLock()
    private var buffer = Data()
    private var finished = false
    private let eof = DispatchGroup()

    init(_ executable: String, _ arguments: [String]) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        eof.enter()
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
                self?.eof.leave()
            } else {
                self?.lock.lock(); self?.buffer.append(data); self?.lock.unlock()
            }
        }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            // Let the pipe drain so output is complete; a lingering grandchild
            // holding the pipe open must not block us forever.
            _ = self.eof.wait(timeout: .now() + 1)
            self.lock.lock(); self.finished = true; self.lock.unlock()
        }
        do { try process.run() } catch {
            handle.readabilityHandler = nil
            throw error
        }
        try? pipe.fileHandleForWriting.close()
    }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return !finished }

    var exitCode: Int32? {
        lock.lock(); defer { lock.unlock() }
        return finished ? process.terminationStatus : nil
    }

    var output: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: buffer, as: UTF8.self)
    }

    func terminate() {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate() // SIGTERM
        // Strong capture of the Process: escalation must happen even if the caller drops us.
        let proc = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if proc.isRunning { kill(pid, SIGKILL) }
        }
    }

    func hasDescendant(otherThan benign: Set<String>) -> Bool? {
        guard isRunning, process.isRunning else { return nil }
        let result = SystemProcess.tree(of: process.processIdentifier, hasNameOutside: benign)
        // If the root exited mid-walk the listing can't be trusted.
        guard process.isRunning else { return nil }
        return result
    }

    private static func children(of pid: pid_t) -> [pid_t]? {
        var capacity = 64
        while true {
            var pids = [pid_t](repeating: 0, count: capacity)
            // Returns the number of pids written (not bytes), despite the header's wording.
            let written = proc_listchildpids(pid, &pids, Int32(capacity * MemoryLayout<pid_t>.size))
            if written < 0 { return nil }
            let count = Int(written)
            if count < capacity { return Array(pids.prefix(count)) }
            capacity *= 2
        }
    }

    private static func tree(of pid: pid_t, hasNameOutside benign: Set<String>) -> Bool? {
        guard let kids = children(of: pid) else { return nil }
        for kid in kids {
            var buf = [CChar](repeating: 0, count: 256)
            let len = proc_name(kid, &buf, UInt32(buf.count))
            if len > 0 {
                if !benign.contains(String(cString: buf)) { return true }
            } else if errno != ESRCH {
                return nil
            } // else the child exited meanwhile; skip it
            switch tree(of: kid, hasNameOutside: benign) {
            case true?: return true
            case nil: return nil
            case false?: continue
            }
        }
        return false
    }
}
