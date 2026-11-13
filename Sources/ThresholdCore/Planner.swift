import Foundation

public struct PlannedItem: Equatable {
    public var item: Item
    public var installed: Version
    /// Why the plan differs from the config (e.g. a fallback trigger replaced an unusable cached package).
    /// Becomes the result's reason when the item otherwise finishes without one.
    public var note: String?

    public init(item: Item, installed: Version, note: String? = nil) {
        self.item = item
        self.installed = installed
        self.note = note
    }
}

public struct SkippedItem: Equatable, Codable {
    public var id: String
    public var reason: String
    public var countsAsFailure: Bool

    public init(id: String, reason: String, countsAsFailure: Bool) {
        self.id = id
        self.reason = reason
        self.countsAsFailure = countsAsFailure
    }
}

public struct Plan: Equatable {
    public var work: [PlannedItem]
    public var skipped: [SkippedItem]
    public var upToDate: [String]

    public var hasWork: Bool { !work.isEmpty }

    public init(work: [PlannedItem], skipped: [SkippedItem], upToDate: [String]) {
        self.work = work
        self.skipped = skipped
        self.upToDate = upToDate
    }
}

public enum Planner {
    /// Decides, before any UI, which items need installing. Per item: quarantine check, then version read,
    /// then (only if work is needed) hook trust and, for a cached package, package verification.
    /// An item whose pre/post hook is untrusted is skipped here, so it never causes a blur.
    /// A cached package is verified, and planned, at its canonical path (`HookTrust.canonicalPath`), so the
    /// installer later runs exactly the file that was checked, not whatever a symlinked parent points to then.
    public static func plan(_ config: Config, state: PersistentState,
                            versions: VersionReading, packages: PackageVerifying,
                            hookTrusted: (String) -> Bool = HookTrust.isTrusted(path:)) -> Plan {
        var work: [PlannedItem] = []
        var upToDate: [String] = []
        var skipped = config.invalidItems.map {
            SkippedItem(id: $0.id, reason: "invalid config: \($0.reason)", countsAsFailure: false)
        }
        func skip(_ item: Item, _ reason: String) {
            skipped.append(SkippedItem(id: item.id, reason: reason, countsAsFailure: false))
        }

        for item in config.items {
            if state.isQuarantined(item, max: config.global.maxConsecutiveFailures) {
                skip(item, "quarantined")
                continue
            }
            let installed: Version
            switch versions.read(item.probe) {
            case .notInstalled:
                guard item.installIfMissing else { skip(item, notInstalledReason); continue }
                installed = Version("0")!   // new build: install it
            case let .unreadable(detail): skip(item, "version unreadable: \(detail)"); continue
            case let .version(version): installed = version
            }
            if installed >= item.targetVersion {
                upToDate.append(item.id)
                continue
            }
            let hooks = [item.preInstallScript, item.postInstallScript].compactMap { $0 }
            if hooks.contains(where: { !hookTrusted($0) }) {
                skip(item, "hook not trusted")
                continue
            }
            var planned = item
            if case let .cachedPackage(original, sha256, teamID) = item.source {
                // An unresolvable parent means the file can't exist either: verify reports it missing.
                let path = HookTrust.canonicalPath(original) ?? original
                planned.source = .cachedPackage(path: path, sha256: sha256, teamID: teamID)
                if let problem = packageProblem(packages.verify(path: path, sha256: sha256, teamID: teamID)) {
                    // The unusable package is never run; the Jamf policy is trusted to deliver the update.
                    guard let fallback = item.fallbackTrigger else { skip(item, problem); continue }
                    planned.source = .jamfTrigger(fallback)
                    work.append(PlannedItem(item: planned, installed: installed,
                                            note: "\(problem); used fallback trigger"))
                    continue
                }
            }
            work.append(PlannedItem(item: planned, installed: installed))
        }
        return Plan(work: work, skipped: skipped, upToDate: upToDate)
    }

    /// Why a cached package can't be used, or nil if it can.
    private static func packageProblem(_ check: PackageCheck) -> String? {
        switch check {
        case .ok: return nil
        case .missing: return "cached package missing"
        case .untrustedLocation: return "cached package in untrusted location"
        case .checksumMismatch: return "cached package checksum mismatch"
        case let .signatureInvalid(detail): return "cached package signature invalid: \(detail)"
        case let .teamMismatch(found): return "cached package team ID mismatch: \(found)"
        }
    }
}
