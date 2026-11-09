import Foundation

public struct FailureRecord: Codable, Equatable {
    public var targetVersion: String
    public var count: Int

    public init(targetVersion: String, count: Int) {
        self.targetVersion = targetVersion
        self.count = count
    }
}

public struct PersistentState: Codable, Equatable {
    public var lastHandledBootSession: String?
    public var failures: [String: FailureRecord]

    public init() {
        lastHandledBootSession = nil
        failures = [:]
    }

    public func isQuarantined(_ item: Item, max: Int) -> Bool {
        guard let record = failures[item.id] else { return false }
        return record.targetVersion == item.targetVersion.raw && record.count >= max
    }

    public mutating func recordFailure(_ item: Item) {
        if var record = failures[item.id], record.targetVersion == item.targetVersion.raw {
            record.count = record.count == Int.max ? Int.max : record.count + 1
            failures[item.id] = record
        } else {
            failures[item.id] = FailureRecord(targetVersion: item.targetVersion.raw, count: 1)
        }
    }

    public mutating func recordSuccess(_ item: Item) {
        failures[item.id] = nil
    }
}

public struct StateStore {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func load() -> PersistentState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(PersistentState.self, from: data)
        else { return PersistentState() }
        return state
    }

    public func save(_ s: PersistentState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(s)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    }
}
