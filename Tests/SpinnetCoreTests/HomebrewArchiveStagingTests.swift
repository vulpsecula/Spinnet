import XCTest
import CryptoKit
import Darwin
import SpinnetCore
@testable import SpinnetReviewedTools

final class HomebrewArchiveStagingTests: XCTestCase {
    func testRemainingExpansionLimitsCountImplicitParentsAndSeparateCompressedInputBytes() throws {
        try withArchive(tar([("deep/parent/file", "safe", 0o600, "0", "")])) { archive, root, checksum in
            let refused = root.appendingPathComponent("refused")
            XCTAssertThrowsError(try HomebrewArchiveStaging.extractVerified(archive, checksum: checksum, into: refused, selected: ".", decoder: decoder(), maximumBytes: 4, maximumEntries: 2))
            XCTAssertFalse(FileManager.default.fileExists(atPath: refused.path))
            let exact = try HomebrewArchiveStaging.extractVerified(archive, checksum: checksum, into: root.appendingPathComponent("exact"), selected: ".", decoder: decoder(), maximumBytes: 4, maximumEntries: 3)
            XCTAssertEqual(try String(contentsOf: exact.selectedURL.appendingPathComponent("deep/parent/file")), "safe")
        }
    }
    func testOrdinaryTarDotRootHeadersNormalizeBeforePrivateTreeValidation() throws {
        try withArchive(tar([("./", "", 0o755, "5", ""), ("./Vendor.pkg/file", "safe", 0o600, "0", ""), ("./Vendor.pkg/link", "", 0o600, "1", "./Vendor.pkg/file")])) { archive, root, checksum in
            let result = try HomebrewArchiveStaging.extractVerified(archive, checksum: checksum, into: root.appendingPathComponent("stage"), selected: "Vendor.pkg", decoder: decoder())
            XCTAssertEqual(try String(contentsOf: result.selectedURL.appendingPathComponent("link")), "safe")
        }
    }

    func testWholeVerifiedPayloadRetainsAllGeneratedInstallerResources() throws {
        try withArchive(tar([("Vendor.app/Contents/install", "vendor executable", 0o755, "0", ""),
                             ("resources/payload", "required installation data", 0o600, "0", "")])) { archive, root, checksum in
            let result = try HomebrewArchiveStaging.extractVerified(archive, checksum: checksum, into: root.appendingPathComponent("stage"), selected: ".", decoder: decoder())
            XCTAssertEqual(try String(contentsOf: result.selectedURL.appendingPathComponent("resources/payload")), "required installation data")
            XCTAssertEqual(try String(contentsOf: result.selectedURL.appendingPathComponent("Vendor.app/Contents/install")), "vendor executable")
            XCTAssertEqual(try HomebrewArchiveStaging.fingerprint(result.selectedURL), result.sha256)
        }
    }
    func testVerifiedPackageDirectoryKeepsItsExecutableAndInternalFrameworkLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("payload.tar")
        try tar([("Vendor.pkg/Contents/install", "#!/bin/sh\nexit 0\n", 0o755, "0", ""),
                 ("Vendor.pkg/Contents/Current", "", 0o777, "2", "install")]).write(to: archive)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)
        let checksum = SHA256.hash(data: try Data(contentsOf: archive)).map { String(format: "%02x", $0) }.joined()
        let result = try HomebrewArchiveStaging.extractVerified(archive, checksum: checksum, into: root.appendingPathComponent("stage"), selected: "Vendor.pkg", decoder: decoder())
        XCTAssertEqual(try String(contentsOf: result.selectedURL.appendingPathComponent("Contents/Current")), "#!/bin/sh\nexit 0\n")
        var info = stat()
        XCTAssertEqual(lstat(result.selectedURL.appendingPathComponent("Contents/install").path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o7777, 0o700)
        XCTAssertEqual(try HomebrewArchiveStaging.fingerprint(result.selectedURL), result.sha256)
    }
    func testVerifiedZipVendorPackageKeepsItsInternalExecutableLink() throws {
        let bytes = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "vendor", withExtension: "zip", subdirectory: "ArchiveFixtures")))
        try withArchive(bytes) { archive, root, checksum in
            let result = try HomebrewArchiveStaging.extractVerified(archive, checksum: checksum, into: root.appendingPathComponent("stage"), selected: "Vendor.pkg", decoder: decoder())
            XCTAssertEqual(try String(contentsOf: result.selectedURL.appendingPathComponent("Contents/current")), "vendor executable")
            XCTAssertEqual(try HomebrewArchiveStaging.fingerprint(result.selectedURL), result.sha256)
        }
    }
    func testAnArchiveParentWithAnInheritedReadGrantIsNotPrivateNativeStaging() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("payload.tar")
        try tar([("Payload.pkg/file", "safe", 0o600, "0", "")]).write(to: archive)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY)
        defer { close(descriptor) }
        var acl: acl_t? = try XCTUnwrap(acl_init(1)); defer { acl_free(UnsafeMutableRawPointer(acl!)) }
        var entry: acl_entry_t?
        XCTAssertEqual(acl_create_entry_np(&acl, &entry, 0), 0)
        let actual = try XCTUnwrap(entry)
        XCTAssertEqual(acl_set_tag_type(actual, ACL_EXTENDED_ALLOW), 0)
        let qualifier: [UInt8] = [255,255,255,255,255,255,255,255,0,0,0,0,0,0,1,246]
        XCTAssertEqual(qualifier.withUnsafeBytes { acl_set_qualifier(actual, $0.baseAddress!) }, 0)
        var permissions: acl_permset_t?
        XCTAssertEqual(acl_get_permset(actual, &permissions), 0)
        XCTAssertEqual(acl_add_perm(try XCTUnwrap(permissions), ACL_READ_DATA), 0)
        var flags: acl_flagset_t?
        XCTAssertEqual(acl_get_flagset_np(UnsafeMutableRawPointer(actual), &flags), 0)
        XCTAssertEqual(acl_add_flag_np(try XCTUnwrap(flags), ACL_ENTRY_FILE_INHERIT), 0)
        XCTAssertEqual(acl_add_flag_np(try XCTUnwrap(flags), ACL_ENTRY_DIRECTORY_INHERIT), 0)
        XCTAssertEqual(acl_set_fd_np(descriptor, acl, ACL_TYPE_EXTENDED), 0)
        let checksum = SHA256.hash(data: try Data(contentsOf: archive)).map { String(format: "%02x", $0) }.joined()
        XCTAssertThrowsError(try HomebrewArchiveStaging.extractVerified(archive, checksum: checksum, into: root.appendingPathComponent("stage"), selected: "Payload.pkg", decoder: decoder()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("stage").path))
    }
    func testForwardHardlinksBecomePrivateCopiesAndTheWholePackageDigestChangesWithOtherFiles() throws {
        try withArchive(tar([("Payload.pkg/copy", "", 0o600, "1", "Payload.pkg/install"),
                             ("Payload.pkg/install", "vendor executable", 0o755, "0", ""),
                             ("Payload.pkg/config", "original", 0o600, "0", "")])) { archive, root, checksum in
            let result = try HomebrewArchiveStaging.extractVerified(archive, checksum: checksum, into: root.appendingPathComponent("stage"), selected: "Payload.pkg", decoder: decoder())
            let copy = result.selectedURL.appendingPathComponent("copy"), original = result.selectedURL.appendingPathComponent("install")
            var copied = stat(), source = stat()
            XCTAssertEqual(lstat(copy.path, &copied), 0); XCTAssertEqual(lstat(original.path, &source), 0)
            XCTAssertNotEqual(copied.st_ino, source.st_ino); XCTAssertEqual(copied.st_nlink, 1)
            XCTAssertEqual(copied.st_mode & 0o7777, 0o700)
            XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: original))
            try Data("changed non-executable package resource".utf8).write(to: result.selectedURL.appendingPathComponent("config"))
            XCTAssertNotEqual(try HomebrewArchiveStaging.fingerprint(result.selectedURL), result.sha256)
        }
    }
    func testTraversalsEscapingLinksCyclesAndFilesystemAliasesNeverCreateAnAcceptedTree() throws {
        let payloads = [
            tar([("../outside", "unsafe", 0o600, "0", "")]),
            tar([("Payload.pkg/link", "", 0o777, "2", "../../outside")]),
            tar([("Payload.pkg/a", "", 0o777, "2", "b"), ("Payload.pkg/b", "", 0o777, "2", "a")]),
            tar([("Payload.pkg/File", "one", 0o600, "0", ""), ("Payload.pkg/file", "two", 0o600, "0", "")]),
            tar([("Payload.pkg/a", "", 0o600, "1", "/private/etc/passwd")])
        ]
        for payload in payloads {
            try withArchive(payload) { archive, root, checksum in
                let output = root.appendingPathComponent("stage")
                XCTAssertThrowsError(try HomebrewArchiveStaging.extractVerified(archive, checksum: checksum, into: output, selected: "Payload.pkg", decoder: decoder()))
                XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            }
        }
    }
    func testCompressedPayloadCannotExceedItsHostExpandedByteBudget() throws {
        let large = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "large-payload.tar", withExtension: "gz", subdirectory: "ArchiveFixtures")))
        try withArchive(large) { archive, root, checksum in
            XCTAssertThrowsError(try HomebrewArchiveStaging.extractVerified(archive, checksum: checksum, into: root.appendingPathComponent("stage"), selected: "Payload.pkg", decoder: decoder(), maximumBytes: 1024 * 1024)) { XCTAssertEqual($0 as? PluginHostServiceError, .tool(.outputTooLarge)) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("stage").path))
        }
    }
    func testStopAndWallDeadlineBoundARealCompressedDecodeAndDiscardIncompleteOutput() throws {
        let large = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "large-payload.tar", withExtension: "gz", subdirectory: "ArchiveFixtures")))
        for stop in [false, true] {
            try withArchive(large) { archive, root, checksum in
                let start = ProcessInfo.processInfo.systemUptime
                let deadline = stop ? Date().addingTimeInterval(3) : Date().addingTimeInterval(0.025)
                XCTAssertThrowsError(try HomebrewArchiveStaging.extractVerified(archive, checksum: checksum, into: root.appendingPathComponent("stage"), selected: "Payload.pkg", decoder: decoder(), deadline: deadline, isCancelled: { stop && ProcessInfo.processInfo.systemUptime - start > 0.025 })) { XCTAssertEqual($0 as? PluginHostServiceError, .tool(stop ? .planChanged : .timedOut)) }
                XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("stage").path))
            }
        }
    }
    func testChangedSourceChecksumAndMalformedArchiveAreNeverAccepted() throws {
        try withArchive(tar([("Payload.pkg/file", "safe", 0o600, "0", "")])) { archive, root, _ in
            XCTAssertThrowsError(try HomebrewArchiveStaging.extractVerified(archive, checksum: String(repeating: "a", count: 64), into: root.appendingPathComponent("stage"), selected: "Payload.pkg", decoder: decoder()))
        }
        try withArchive(Data("not an archive".utf8)) { archive, root, checksum in
            XCTAssertThrowsError(try HomebrewArchiveStaging.extractVerified(archive, checksum: checksum, into: root.appendingPathComponent("stage"), selected: "Payload.pkg", decoder: decoder()))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("stage").path))
        }
    }
    private func withArchive(_ data: Data, action: (URL, URL, String) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("payload")
        try data.write(to: archive); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)
        let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try action(archive, root, checksum)
    }
    private func decoder() -> HomebrewArchiveStaging.DecoderConfiguration {
        let executable = Bundle(for: HomebrewArchiveStagingTests.self).bundleURL.deletingLastPathComponent()
        return .init(bootstrap: executable.appendingPathComponent("SpinnetArchiveBootstrap"), uid: getuid(), gid: getgid())
    }
    /// A literal ustar fixture builder, independent of the decoder/library.
    private func tar(_ entries: [(String, String, Int, String, String)]) -> Data {
        var result = Data()
        for (name, value, mode, kind, link) in entries {
            var header = [UInt8](repeating: 0, count: 512)
            func field(_ text: String, at offset: Int, width: Int) { for (index, byte) in text.utf8.prefix(width).enumerated() { header[offset + index] = byte } }
            field(name, at: 0, width: 100); field(String(format: "%07o", mode), at: 100, width: 8)
            field("0000000", at: 108, width: 8); field("0000000", at: 116, width: 8)
            field(String(format: "%011o", value.utf8.count), at: 124, width: 12); field("00000000000", at: 136, width: 12)
            for index in 148..<156 { header[index] = 32 }
            header[156] = kind.utf8.first!; field(link, at: 157, width: 100); field("ustar", at: 257, width: 6); field("00", at: 263, width: 2)
            field(String(format: "%06o", header.reduce(0) { $0 + Int($1) }), at: 148, width: 6); header[154] = 0; header[155] = 32
            result.append(contentsOf: header); result.append(contentsOf: value.utf8)
            if value.utf8.count % 512 != 0 { result.append(Data(repeating: 0, count: 512 - value.utf8.count % 512)) }
        }
        result.append(Data(repeating: 0, count: 1024)); return result
    }
}
