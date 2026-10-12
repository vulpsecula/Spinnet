import XCTest
import CryptoKit
import Darwin
import SpinnetCore

final class HomebrewPBZXBoundsTests: XCTestCase {
    func testPublicPBZXRawBlocksCrossChunkBoundariesAndPreserveProgramBytes() throws {
        let plain = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "vendor-origin-latest", withExtension: "cpio", subdirectory: "ArchiveFixtures")))
        var stream = Data("pbzx".utf8); stream.append(big(4096))
        for offset in stride(from: 0, to: plain.count, by: 4096) {
            let block = plain.subdata(in: offset..<min(plain.count, offset + 4096))
            stream.append(big(UInt64(block.count))); stream.append(big(UInt64(block.count))); stream.append(block)
        }
        try fixture(stream) { archive, root, checksum, decoder in
            let tree = try HomebrewArchiveStaging.extractVerified(archive, checksum: checksum, into: root.appendingPathComponent("output"), selected: ".", decoder: decoder)
            XCTAssertEqual(try String(contentsOf: tree.selectedURL.appendingPathComponent("Library/Application Support/Vendor/uninstall")), "vendor executable")
        }
    }
    func testMalformedHeaderSizeTruncationAndTrailingFramingAllRefuseWithoutFinalTree() throws {
        // Actual publicly documented PBZX body from Apple's owned pkgbuild.
        let packageBytes = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "vendor-origin-latest", withExtension: "pkg", subdirectory: "ArchiveFixtures")))
        try fixture(packageBytes) { file, root, checksum, decoder in
            let package = try HomebrewArchiveStaging.extractVerified(file, checksum: checksum, into: root.appendingPathComponent("package"), selected: ".", decoder: decoder)
            let original = try Data(contentsOf: package.selectedURL.appendingPathComponent("Payload"))
            var huge = original, falseOutput = original, hugeCompressed = original, trailing = original
            huge.replaceSubrange(4..<12, with: big(1 << 40))
            falseOutput.replaceSubrange(12..<20, with: big(172545))
            hugeCompressed.replaceSubrange(20..<28, with: big(UInt64.max))
            trailing.append(65)
            for (index, bytes) in [huge, falseOutput, hugeCompressed, trailing, Data(original.dropLast())].enumerated() {
                let bad = root.appendingPathComponent("bad-\(index)")
                try bytes.write(to: bad); XCTAssertEqual(chmod(bad.path, 0o600), 0)
                let output = root.appendingPathComponent("output-\(index)")
                XCTAssertThrowsError(try HomebrewArchiveStaging.extractVerified(bad, checksum: hash(bytes), into: output, selected: ".", decoder: decoder))
                XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            }
        }
    }
    func testPBZXExpandedPayloadBoundRemainsRootFrameValidated() throws {
        let bytes = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "vendor-origin-latest", withExtension: "pkg", subdirectory: "ArchiveFixtures")))
        try fixture(bytes) { archive, root, checksum, decoder in
            let package = try HomebrewArchiveStaging.extractVerified(archive, checksum: checksum, into: root.appendingPathComponent("package"), selected: ".", decoder: decoder)
            let payload = package.selectedURL.appendingPathComponent("Payload")
            let checksum = hash(try Data(contentsOf: payload)), output = root.appendingPathComponent("limited")
            XCTAssertThrowsError(try HomebrewArchiveStaging.extractVerified(payload, checksum: checksum, into: output, selected: ".", decoder: decoder, maximumBytes: 32 * 1024)) {
                XCTAssertEqual($0 as? PluginHostServiceError, .tool(.outputTooLarge))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }
    private func big(_ value: UInt64) -> Data { var value = value.bigEndian; return withUnsafeBytes(of: &value) { Data($0) } }
    private func hash(_ value: Data) -> String { SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined() }
    private func fixture(_ bytes: Data, _ action: (URL, URL, String, HomebrewArchiveStaging.DecoderConfiguration) throws -> Void) throws {
        XCTAssertNotEqual(getuid(), 0, "Current-UID owned parser fixtures, no Root acceptance")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try NativeFileQuarantine.makePrivateDirectory(root); defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("download")
        try bytes.write(to: archive); XCTAssertEqual(chmod(archive.path, 0o600), 0)
        let decoder = HomebrewArchiveStaging.DecoderConfiguration(bootstrap: Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("SpinnetArchiveBootstrap"), uid: getuid(), gid: getgid())
        try action(archive, root, hash(bytes), decoder)
    }
}
