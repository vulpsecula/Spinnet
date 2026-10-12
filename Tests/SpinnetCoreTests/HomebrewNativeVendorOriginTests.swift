import XCTest
import CryptoKit
import Darwin
import SpinnetCore

final class HomebrewNativeVendorOriginTests: XCTestCase {
    func testActualAppleLatestPBZXFixtureDecodesOriginalPayloadAndResourceBytesUnprivileged() throws {
        let bytes = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "vendor-origin-latest", withExtension: "pkg", subdirectory: "ArchiveFixtures")))
        try fixture(bytes) { archive, root, checksum in
            let package = try HomebrewArchiveStaging.extractVerified(archive, checksum: checksum, into: root.appendingPathComponent("package"), selected: ".", decoder: decoder())
            let raw = try Data(contentsOf: package.selectedURL.appendingPathComponent("Payload"))
            XCTAssertEqual(Array(raw.prefix(4)), Array("pbzx".utf8), "Actual pkgbuild --compression latest fixture")
            let payload = try HomebrewNativeVendorOrigin.extractPackagePayload(package, into: root.appendingPathComponent("payload"), decoder: decoder(), deadline: Date().addingTimeInterval(10))
            XCTAssertEqual(payload.installLocation, "/")
            let installed = root.appendingPathComponent("owned-installed")
            try Data("vendor executable".utf8).write(to: installed); XCTAssertEqual(chmod(installed.path, 0o700), 0)
            let match = try HomebrewNativeVendorOrigin.compareMember(payload.tree, member: "Library/Application Support/Vendor/uninstall", installed: installed, deadline: Date().addingTimeInterval(5))
            XCTAssertEqual(match.executableSHA256, "57fa54816d203f24ce26ae4734a7eba5c220408c6fccbba218ab2cd957655961")
            XCTAssertEqual(try Data(contentsOf: payload.tree.selectedURL.appendingPathComponent("Library/Application Support/Vendor/resource")), Data(String(repeating: "original resource", count: 10000).utf8))
        }
    }
    func testOwnedZipMemberByteMatchFreezesResourcesWithoutClaimingFixturePublisherSignature() throws {
        let bytes = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "vendor", withExtension: "zip", subdirectory: "ArchiveFixtures")))
        try fixture(bytes) { archive, root, checksum in
            let tree = try HomebrewArchiveStaging.extractVerified(archive, checksum: checksum, into: root.appendingPathComponent("original"), selected: ".", decoder: decoder())
            let installed = root.appendingPathComponent("installed")
            try Data("vendor executable".utf8).write(to: installed)
            XCTAssertEqual(chmod(installed.path, 0o700), 0)
            let match = try HomebrewNativeVendorOrigin.compareMember(tree, member: "Vendor.pkg/Contents/install", installed: installed, deadline: Date().addingTimeInterval(10))
            XCTAssertEqual(match.executableSHA256, "57fa54816d203f24ce26ae4734a7eba5c220408c6fccbba218ab2cd957655961")
            XCTAssertEqual(match.resourceTreeSHA256, tree.sha256)
            XCTAssertEqual(match.installed.inode, try NativeFileQuarantine.capture(installed).inode)
            XCTAssertEqual(match.member, "Vendor.pkg/Contents/install")
        }
    }
    func testOwnedFlatPackagePayloadBindsItsInstallLocationAndOriginalResources() throws {
        let bytes = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "vendor-origin", withExtension: "pkg", subdirectory: "ArchiveFixtures")))
        try fixture(bytes) { archive, root, checksum in
            let package = try HomebrewArchiveStaging.extractVerified(archive, checksum: checksum, into: root.appendingPathComponent("package"), selected: ".", decoder: decoder())
            let payload = try HomebrewNativeVendorOrigin.extractPackagePayload(package, into: root.appendingPathComponent("payload"), decoder: decoder(), deadline: Date().addingTimeInterval(10))
            XCTAssertEqual(payload.installLocation, "/")
            let installed = root.appendingPathComponent("installed")
            try Data("vendor executable".utf8).write(to: installed); XCTAssertEqual(chmod(installed.path, 0o700), 0)
            let match = try HomebrewNativeVendorOrigin.compareMember(payload.tree, member: "Library/Application Support/Vendor/uninstall", installed: installed, deadline: Date().addingTimeInterval(10))
            XCTAssertEqual(match.executableSHA256, "57fa54816d203f24ce26ae4734a7eba5c220408c6fccbba218ab2cd957655961")
            XCTAssertEqual(try String(contentsOf: payload.tree.selectedURL.appendingPathComponent("Library/Application Support/Vendor/resources/config")), "original resource")
        }
    }
    func testInstalledByteMismatchDotAliasAndResourceDriftNeverBecomeOriginalAuthority() throws {
        let bytes = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "vendor", withExtension: "zip", subdirectory: "ArchiveFixtures")))
        try fixture(bytes) { archive, root, checksum in
            let tree = try HomebrewArchiveStaging.extractVerified(archive, checksum: checksum, into: root.appendingPathComponent("original"), selected: ".", decoder: decoder())
            let installed = root.appendingPathComponent("installed")
            try Data("vendor executable".utf8).write(to: installed); XCTAssertEqual(chmod(installed.path, 0o700), 0)
            let alias = root.appendingPathComponent("unselected/../installed")
            XCTAssertThrowsError(try HomebrewNativeVendorOrigin.compareMember(tree, member: "Vendor.pkg/Contents/install", installed: alias, deadline: Date().addingTimeInterval(10)))
            try Data("modified installed executable".utf8).write(to: installed)
            XCTAssertThrowsError(try HomebrewNativeVendorOrigin.compareMember(tree, member: "Vendor.pkg/Contents/install", installed: installed, deadline: Date().addingTimeInterval(10)))
            try Data("vendor executable".utf8).write(to: installed)
            try Data("new unreviewed resource".utf8).write(to: tree.selectedURL.appendingPathComponent("resource"))
            XCTAssertThrowsError(try HomebrewNativeVendorOrigin.compareMember(tree, member: "Vendor.pkg/Contents/install", installed: installed, deadline: Date().addingTimeInterval(10)))
        }
    }
    func testActualSignedAppMappingAndWrongOriginalArchiveChecksumRefuseLocalHashAuthority() throws {
        let snapshot = try HomebrewPrivilegeMetadata.readEvidence("shadowsocksx-ng", deadline: Date().addingTimeInterval(15))
        let selection = try HomebrewNativeVendorOrigin.select(snapshot: snapshot, recipeExecutable: "/Applications/ShadowsocksX-NG.app/Contents/Resources/proxy_conf_helper")
        XCTAssertEqual(selection.kind, .publisherChecksum)
        XCTAssertEqual(selection.member, "ShadowsocksX-NG.app/Contents/Resources/proxy_conf_helper")
        XCTAssertEqual(selection.downloadSHA256, "a0bc48af636c796471b1156eae0b6ca7340fe51deffec384c409dac785f04c60")
        XCTAssertThrowsError(try HomebrewNativeVendorOrigin.select(snapshot: snapshot, recipeExecutable: "/Applications/Unselected.app/Contents/Resources/proxy_conf_helper"))
        let fixtureBytes = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "vendor", withExtension: "zip", subdirectory: "ArchiveFixtures")))
        try fixture(fixtureBytes) { archive, root, _ in
            XCTAssertThrowsError(try HomebrewNativeVendorOrigin.capture(selection, originalDownload: archive, into: root, decoder: decoder(), deadline: Date().addingTimeInterval(10))) {
                XCTAssertEqual($0 as? PluginHostServiceError, .tool(.planChanged))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("original").path))
        }
    }
    func testOriginalInternalExecutableLinkResolvesOnlyInsideItsFrozenResourceTree() throws {
        let bytes = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "vendor", withExtension: "zip", subdirectory: "ArchiveFixtures")))
        try fixture(bytes) { archive, root, checksum in
            let tree = try HomebrewArchiveStaging.extractVerified(archive, checksum: checksum, into: root.appendingPathComponent("original"), selected: ".", decoder: decoder())
            let installed = root.appendingPathComponent("installed")
            try Data("vendor executable".utf8).write(to: installed); XCTAssertEqual(chmod(installed.path, 0o700), 0)
            let match = try HomebrewNativeVendorOrigin.compareMember(tree, member: "Vendor.pkg/Contents/current", installed: installed, deadline: Date().addingTimeInterval(10))
            XCTAssertEqual(match.member, "Vendor.pkg/Contents/current")
            XCTAssertEqual(match.resolvedMember, "Vendor.pkg/Contents/install")
            XCTAssertEqual(match.executableSHA256, "57fa54816d203f24ce26ae4734a7eba5c220408c6fccbba218ab2cd957655961")
        }
    }
    func testActualSignedNoCheckSourceRequiresConfirmedHostSnapshotAndLabelsItWithoutHistoricalClaim() throws {
        let snapshot = try HomebrewPrivilegeMetadata.readEvidence("sound-siphon", deadline: Date().addingTimeInterval(15))
        let executable = "/Applications/Sound Siphon.app/Contents/Resources/uninstall_soundsiphon"
        XCTAssertThrowsError(try HomebrewNativeVendorOrigin.select(snapshot: snapshot, recipeExecutable: executable))
        let bytes = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "vendor", withExtension: "zip", subdirectory: "ArchiveFixtures")))
        try fixture(bytes) { _, root, _ in
            var fetches = 0
            // Real signature/config/source selection; fixed fixture fetch ONLY.
            // No actual current app download or historical-origin claim.
            let frozen = try HomebrewNoCheckSnapshot.capture(snapshot: snapshot, into: root, deadline: Date().addingTimeInterval(10), fetch: { _, fd, _, _, _ in
                fetches += 1
                try bytes.withUnsafeBytes { raw in XCTAssertEqual(Darwin.write(fd, raw.baseAddress, raw.count), raw.count) }
            })
            let selected = try HomebrewNativeVendorOrigin.select(snapshot: snapshot, recipeExecutable: executable, confirmedSnapshot: frozen)
            XCTAssertEqual(selected.kind, .confirmedHostSnapshotMatch)
            XCTAssertEqual(selected.downloadSHA256, frozen.sha256)
            XCTAssertEqual(fetches, 1)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(frozen)) as? [String: Any])
            object["sourceURL"] = "https://example.invalid/unreviewed"
            let forged = try JSONDecoder().decode(HomebrewNoCheckSnapshot.Result.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertThrowsError(try HomebrewNativeVendorOrigin.select(snapshot: snapshot, recipeExecutable: executable, confirmedSnapshot: forged))
        }
    }
    private func decoder() -> HomebrewArchiveStaging.DecoderConfiguration {
        let bootstrap = Bundle(for: HomebrewNativeVendorOriginTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("SpinnetArchiveBootstrap")
        return .init(bootstrap: bootstrap, uid: getuid(), gid: getgid())
    }
    private func fixture(_ bytes: Data, _ action: (URL, URL, String) throws -> Void) throws {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let root = raw.resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("download")
        try bytes.write(to: archive); XCTAssertEqual(chmod(archive.path, 0o600), 0)
        try action(archive, root, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }
}
