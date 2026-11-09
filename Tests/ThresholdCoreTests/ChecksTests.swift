import Testing
import Foundation
import CryptoKit
@testable import ThresholdCore

func makeTempApp(named name: String, version: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let contents = dir.appendingPathComponent(name).appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleShortVersionString": version]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: contents.appendingPathComponent("Info.plist"))
    return dir.appendingPathComponent(name)
}

func tempFile(contents: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("file.pkg")
    try Data(contents.utf8).write(to: url)
    return url
}

private func sha256Hex(_ s: String) -> String {
    SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func reader() -> VersionReader { VersionReader(launcher: SystemProcessLauncher(), clock: SystemClock()) }

@Test func readsBundleVersionWithSpacesInPath() throws {
    let app = try makeTempApp(named: "My App.app", version: "5.1.10")
    #expect(reader().read(.bundle(appPath: app.path, key: "CFBundleShortVersionString")) == .version(Version("5.1.10")!))
}
@Test func missingAppIsNotInstalled() {
    #expect(reader().read(.bundle(appPath: "/nope/X.app", key: "CFBundleShortVersionString")) == .notInstalled)
}
@Test func garbageVersionIsUnreadable() throws {
    let app = try makeTempApp(named: "G.app", version: "n/a")
    if case .unreadable = reader().read(.bundle(appPath: app.path, key: "CFBundleShortVersionString")) {} else { Issue.record("expected unreadable") }
}
@Test func missingKeyAndMissingPlistAreUnreadable() throws {
    let app = try makeTempApp(named: "K.app", version: "1.0")
    if case .unreadable = reader().read(.bundle(appPath: app.path, key: "NoSuchKey")) {} else { Issue.record("expected unreadable for key") }
    let bare = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)/B.app")
    try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
    if case .unreadable = reader().read(.bundle(appPath: bare.path, key: "CFBundleShortVersionString")) {} else { Issue.record("expected unreadable for plist") }
}
@Test func commandProbe() {
    #expect(reader().read(.command("echo 7.3.1")) == .version(Version("7.3.1")!))
}
@Test func failingOrGarbageCommandIsUnreadable() {
    if case .unreadable = reader().read(.command("exit 3")) {} else { Issue.record("expected unreadable for failure") }
    if case .unreadable = reader().read(.command("echo hello")) {} else { Issue.record("expected unreadable for garbage") }
}
@Test func parsesTeamID() {
    let out = """
    Package "csc.pkg":
       Status: signed by a developer certificate issued by Apple for distribution
       Notarization: trusted by the Apple notary service
       Certificate Chain:
        1. Developer ID Installer: Cisco Systems, Inc. (DE8Y96K9QP)
           Expires: 2027-02-01 22:12:15 +0000
        2. Developer ID Certification Authority
    """
    #expect(teamID(fromPkgutilOutput: out) == "DE8Y96K9QP")
}
@Test func checksumMismatchAndMissing() throws {
    let f = try tempFile(contents: "hello")
    let v = PackageVerifier(launcher: SystemProcessLauncher(), clock: SystemClock(), pathTrusted: { _ in true })
    #expect(v.verify(path: f.path, sha256: String(repeating: "0", count: 64), teamID: "ABCDE12345") == .checksumMismatch)
    #expect(v.verify(path: "/nope.pkg", sha256: String(repeating: "0", count: 64), teamID: "ABCDE12345") == .missing)
}
@Test func unsignedMarkerSkipsSignatureCheck() throws {
    let f = try tempFile(contents: "hello")
    let marker = try tempFile(contents: "")
    let v = PackageVerifier(launcher: SystemProcessLauncher(), clock: SystemClock(), allowUnsignedMarker: marker, pathTrusted: { _ in true })
    #expect(v.verify(path: f.path, sha256: sha256Hex("hello"), teamID: "UNSIGNED00") == .ok)
}
@Test func noMarkerMeansSignatureInvalid() throws {
    let f = try tempFile(contents: "hello")
    let absent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let v = PackageVerifier(launcher: SystemProcessLauncher(), clock: SystemClock(), allowUnsignedMarker: absent, pathTrusted: { _ in true })
    if case .signatureInvalid = v.verify(path: f.path, sha256: sha256Hex("hello"), teamID: "UNSIGNED00") {} else { Issue.record("expected signatureInvalid") }
}
@Test func hookTrustRules() {
    #expect(HookTrust.isTrusted(ownerUID: 0, permissions: 0o755, isRegularFile: true))
    #expect(!HookTrust.isTrusted(ownerUID: 501, permissions: 0o755, isRegularFile: true))
    #expect(!HookTrust.isTrusted(ownerUID: 0, permissions: 0o775, isRegularFile: true))
    #expect(!HookTrust.isTrusted(ownerUID: 0, permissions: 0o757, isRegularFile: true))
    #expect(!HookTrust.isTrusted(ownerUID: 0, permissions: 0o755, isRegularFile: false))
    #expect(!HookTrust.isTrusted(path: "/nope"))
}

@Test func untrustedPackagePathIsRejected() throws {
    let f = try tempFile(contents: "hello")
    let v = PackageVerifier(launcher: SystemProcessLauncher(), clock: SystemClock(), pathTrusted: { _ in false })
    #expect(v.verify(path: f.path, sha256: sha256Hex("hello"), teamID: "ABCDE12345") == .untrustedLocation)
}
@Test func untrustedMarkerIsNotHonored() throws {
    let f = try tempFile(contents: "hello")
    let marker = try tempFile(contents: "")
    let v = PackageVerifier(launcher: SystemProcessLauncher(), clock: SystemClock(), allowUnsignedMarker: marker,
                            pathTrusted: { $0 != marker.path })
    if case .signatureInvalid = v.verify(path: f.path, sha256: sha256Hex("hello"), teamID: "UNSIGNED00") {} else { Issue.record("expected signatureInvalid") }
}

private let dirOK: (uid: uid_t, mode: mode_t) = (0, S_IFDIR | 0o755)
private let fileOK: (uid: uid_t, mode: mode_t) = (0, S_IFREG | 0o755)
private func table(_ overrides: [String: (uid: uid_t, mode: mode_t)] = [:], drop: Set<String> = []) -> (String) -> (uid: uid_t, mode: mode_t)? {
    var t: [String: (uid: uid_t, mode: mode_t)] = [
        "/": dirOK, "/Library": dirOK, "/Library/App": dirOK, "/Library/App/hook.sh": fileOK]
    for (k, v) in overrides { t[k] = v }
    for k in drop { t[k] = nil }
    return { t[$0] }
}
@Test func hookChainTrust() {
    let p = "/Library/App/hook.sh"
    #expect(HookTrust.isTrusted(path: p, stat: table()))
    #expect(!HookTrust.isTrusted(path: p, stat: table(["/Library/App": (501, S_IFDIR | 0o755)])))
    #expect(!HookTrust.isTrusted(path: p, stat: table(["/Library": (0, S_IFDIR | 0o775)])))
    #expect(!HookTrust.isTrusted(path: p, stat: table(["/Library": (0, S_IFLNK | 0o755)])))
    #expect(!HookTrust.isTrusted(path: p, stat: table(["/Library/App/hook.sh": (0, S_IFLNK | 0o755)])))
    #expect(!HookTrust.isTrusted(path: p, stat: table(drop: ["/Library/App/hook.sh"])))
    #expect(!HookTrust.isTrusted(path: p, stat: table(drop: ["/Library"])))
}

@Test func hookTrustRealFilesystem() throws {
    #expect(HookTrust.isTrusted(path: "/bin/sh"))
    #expect(HookTrust.isTrusted(path: "/etc/hosts"))
    #expect(HookTrust.isTrusted(path: "/private/etc/hosts"))
    #expect(!HookTrust.isTrusted(path: try tempFile(contents: "x").path))
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let link = dir.appendingPathComponent("sh")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/bin/sh")
    #expect(!HookTrust.isTrusted(path: link.path))
}
