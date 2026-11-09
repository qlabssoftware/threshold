import Foundation

/// A dotted version such as "126.0", "5.1.2.42" or "1.2.3-beta".
/// Numeric components compare zero-padded; a trailing suffix compares after them.
public struct Version: Comparable, Hashable, Codable, CustomStringConvertible, Sendable {
    public let raw: String
    private let components: [Int]
    private let suffix: String

    public init?(_ string: String) {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = s.unicodeScalars.first, ("0"..."9").contains(first) else { return nil }
        let numericEnd = s.firstIndex { !($0.isASCII && ($0.isNumber || $0 == ".")) } ?? s.endIndex
        var parts: [Int] = []
        for piece in s[..<numericEnd].split(separator: ".", omittingEmptySubsequences: false) {
            if piece.isEmpty { parts.append(0); continue }
            guard let n = Int(piece) else { return nil }
            parts.append(n)
        }
        while parts.count > 1, parts.last == 0 { parts.removeLast() }
        self.raw = s
        self.components = parts
        self.suffix = String(s[numericEnd...])
    }

    public var description: String { raw }

    private static let preReleasePrefixes = ["-", "a", "b", "rc", "beta", "alpha"]

    private static func isPreRelease(_ suffix: String) -> Bool {
        let lower = suffix.lowercased()
        return preReleasePrefixes.contains { lower.hasPrefix($0) }
    }

    /// Rank first (pre-release 0, empty 1, other 2), lexical only within a rank.
    /// This keeps the ordering a strict weak order (transitive).
    private static func rank(_ suffix: String) -> Int {
        if suffix.isEmpty { return 1 }
        return isPreRelease(suffix) ? 0 : 2
    }

    private static func compareSuffix(_ a: String, _ b: String) -> Int {
        if a == b { return 0 }
        let ra = rank(a), rb = rank(b)
        if ra != rb { return ra < rb ? -1 : 1 }
        return a < b ? -1 : 1
    }

    private static func compare(_ l: Version, _ r: Version) -> Int {
        let n = max(l.components.count, r.components.count)
        for i in 0..<n {
            let a = i < l.components.count ? l.components[i] : 0
            let b = i < r.components.count ? r.components[i] : 0
            if a != b { return a < b ? -1 : 1 }
        }
        return compareSuffix(l.suffix, r.suffix)
    }

    public static func == (l: Version, r: Version) -> Bool { compare(l, r) == 0 }
    public static func < (l: Version, r: Version) -> Bool { compare(l, r) < 0 }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(components)
        hasher.combine(suffix)
    }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let v = Version(s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Malformed version: \(s)"))
        }
        self = v
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }
}
