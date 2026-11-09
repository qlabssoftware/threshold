import Testing
import Foundation
@testable import ThresholdCore

private let managed: [String: Any] = ["source": "managed"]
private let fileDict: [String: Any] = ["source": "file"]

private func resolve(exists: Set<String>, untrusted: Set<String> = [], plist: [String: Any]? = fileDict) -> ConfigSource {
    ConfigSource.resolve(fileExists: { exists.contains($0) }, isTrusted: { !untrusted.contains($0) },
                         readPlist: { _ in plist }, managed: { managed })
}

private let both: Set<String> = [ConfigSource.testModeMarker, ConfigSource.testConfigPath]

@Test func noMarkerUsesManagedPrefs() {
    let s = resolve(exists: [ConfigSource.testConfigPath])
    #expect(s.prefs["source"] as? String == "managed")
    #expect(!s.testMode && s.error == nil && s.warning == nil)
}

@Test func trustedMarkerAndFileUsesFile() {
    let s = resolve(exists: both)
    #expect(s.prefs["source"] as? String == "file")
    #expect(s.testMode && s.error == nil)
}

@Test func trustedMarkerWithMissingFileIsError() {
    let s = resolve(exists: [ConfigSource.testModeMarker])
    #expect(s.testMode)
    #expect(s.error == "test mode: test-config.plist missing or untrusted")
    #expect(s.prefs.isEmpty)
}

@Test func trustedMarkerWithUntrustedFileIsError() {
    let s = resolve(exists: both, untrusted: [ConfigSource.testConfigPath])
    #expect(s.testMode && s.error != nil && s.prefs.isEmpty)
}

@Test func trustedMarkerWithNonDictFileIsError() {
    let s = resolve(exists: both, plist: nil)
    #expect(s.testMode && s.error != nil && s.prefs.isEmpty)
}

@Test func untrustedMarkerIgnoredWithWarning() {
    let s = resolve(exists: both, untrusted: [ConfigSource.testModeMarker])
    #expect(s.prefs["source"] as? String == "managed")
    #expect(!s.testMode && s.error == nil)
    #expect(s.warning?.contains("untrusted") == true)
}
