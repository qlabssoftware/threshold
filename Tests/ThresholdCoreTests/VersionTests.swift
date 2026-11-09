import Foundation
import Testing
@testable import ThresholdCore

@Test func numericOrdering() {
    #expect(Version("5.1.10")! > Version("5.1.9")!)
    #expect(Version("126.0")! == Version("126")!)        // trailing zeros equal
    #expect(Version("4.9")! < Version("4.10.1")!)
}

@Test func suffixComparedAfterNumbers() {
    #expect(Version("5.1.2.42")! > Version("5.1.2")!)
    #expect(Version("1.2.3-beta")! < Version("1.2.4")!)
    #expect(Version("1.2.3b")! != Version("1.2.3")!)     // suffix makes it differ
}

@Test func malformedIsNil() {
    #expect(Version("") == nil)
    #expect(Version("abc") == nil)                     // must start with a digit
    #expect(Version(" ") == nil)
}

@Test func preReleaseBelowReleaseOtherSuffixAbove() {
    #expect(Version("1.2.3-beta")! < Version("1.2.3")!)
    #expect(Version("1.2.3rc1")! < Version("1.2.3")!)
    #expect(Version("1.2.3p1")! > Version("1.2.3")!)
}

@Test func rawPreservedAndCodable() throws {
    let v = Version("  126.0 ")!
    #expect(v.raw == "126.0")
    #expect(Version("126.0")!.raw != Version("126")!.raw)
    let data = try JSONEncoder().encode([v])
    #expect(String(decoding: data, as: UTF8.self) == "[\"126.0\"]")
    #expect(try JSONDecoder().decode([Version].self, from: data) == [v])
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode([Version].self, from: Data("[\"abc\"]".utf8))
    }
}

@Test func mixedSuffixOrderingIsTransitive() {
    let beta = Version("1.0-beta")!, plain = Version("1.0")!, build = Version("1.0+build")!
    #expect(beta < plain)
    #expect(plain < build)
    #expect(beta < build)
    let inputs = ["1.0+build", "1.0", "1.0-beta"]
    let expected = ["1.0-beta", "1.0", "1.0+build"]
    for perm in [[0,1,2],[0,2,1],[1,0,2],[1,2,0],[2,0,1],[2,1,0]] {
        let sorted = perm.map { Version(inputs[$0])! }.sorted().map(\.raw)
        #expect(sorted == expected)
    }
}

@Test func equalVersionsCollapseInSet() {
    #expect(Set([Version("126.0")!, Version("126")!]).count == 1)
}
