import XCTest
import CryptoKit
import Darwin
import SpinnetCore
@testable import SpinnetReviewedTools

final class HomebrewNativeSourceStagingTests: XCTestCase {
    func testSignedMultiplePackageArtifactsCannotAliasOneRawInstallerForRepeatedExecution() throws {
        let evidence = try catalog(), configuration = try config(root: URL(fileURLWithPath: "/private/tmp/spinnet-package-artifacts"))
        let single = try HomebrewNativeSourceStaging.select(evidence: evidence, configuration: configuration, token: "zoom", purpose: .packageInstaller(path: "zoomusInstallerFull.pkg"))
        XCTAssertEqual(single.rawInstallerArtifact, "zoomusInstallerFull.pkg")
        for path in ["Install ChmodBPF.pkg", "Add Wireshark to the system path.pkg"] {
            let multiple = try HomebrewNativeSourceStaging.select(evidence: evidence, configuration: configuration, token: "wireshark-app", purpose: .packageInstaller(path: path))
            XCTAssertNil(multiple.rawInstallerArtifact)
        }
        let removal = try HomebrewNativeSourceStaging.select(evidence: evidence, configuration: configuration, token: "wireshark-app", purpose: .packageRemoval(path: "Remove Wireshark from the system path.pkg"))
        XCTAssertNil(removal.rawInstallerArtifact)
    }
    func testNoCheckRelativeVendorNeedsInstalledByteOriginEvenWithConfirmedFixtureSource() throws {
        let evidence = try catalog(), configuration = try config(root: URL(fileURLWithPath: "/private/tmp/spinnet-no-check-source-purpose"))
        let record = try evidence.catalog.project("disk-drill", configuration: configuration)
        guard case .string(let url)? = record["url"], case .string(let version)? = record["version"] else { return XCTFail("Signed URL/version missing") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let fields: [String: Any] = ["fileURL": "file:///private/tmp/spinnet-no-check-source-purpose/fixed-fixture", "sha256": hash(Data("owned fixture".utf8)), "sourceURL": url, "byteCount": 13,
            "sourceSHA256": evidence.catalog.envelopeSHA256, "projectionSHA256": try evidence.catalog.projectionDigest("disk-drill", configuration: configuration), "configurationSHA256": hash(try encoder.encode(configuration))]
        let confirmed = try JSONDecoder().decode(HomebrewNoCheckSnapshot.Result.self, from: JSONSerialization.data(withJSONObject: fields))
        XCTAssertThrowsError(try HomebrewNativeSourceStaging.select(evidence: evidence, configuration: configuration, token: "disk-drill", purpose: .relativeRemoval(recipeExecutable: configuration.prefix.path + "/Caskroom/disk-drill/" + version + "/Disk Drill.app/Contents/Resources/uninstall"), confirmedSnapshot: confirmed))
    }
    func testRealSignedPurposesRefuseUndeclaredAndUnmappedAbsoluteRemoval() throws {
        let evidence = try catalog()
        let configuration = try config(root: URL(fileURLWithPath: "/private/tmp/spinnet-source-purpose"))
        XCTAssertNoThrow(try HomebrewNativeSourceStaging.select(evidence: evidence, configuration: configuration, token: "zoom", purpose: .packageInstaller(path: "zoomusInstallerFull.pkg")))
        XCTAssertNoThrow(try HomebrewNativeSourceStaging.select(evidence: evidence, configuration: configuration, token: "adobe-connect", purpose: .manualInstaller(path: "AdobeConnectInstaller.app")))
        let executable = "Adobe AIR Installer.app/Contents/MacOS/Adobe AIR Installer"
        XCTAssertNoThrow(try HomebrewNativeSourceStaging.select(evidence: evidence, configuration: configuration, token: "adobe-air", purpose: .vendorInstaller(executable: executable)))
        XCTAssertNoThrow(try HomebrewNativeSourceStaging.select(evidence: evidence, configuration: configuration, token: "adobe-air", purpose: .relativeRemoval(recipeExecutable: executable)))
        XCTAssertNoThrow(try HomebrewNativeSourceStaging.select(evidence: evidence, configuration: configuration, token: "shadowsocksx-ng", purpose: .relativeRemoval(recipeExecutable: configuration.appDirectory.path + "/ShadowsocksX-NG.app/Contents/Resources/proxy_conf_helper")))
        XCTAssertNoThrow(try HomebrewNativeSourceStaging.select(evidence: evidence, configuration: configuration, token: "asix-ax88179", purpose: .packageRemoval(path: "AX88179_178A_Uninstall.pkg")))
        XCTAssertThrowsError(try HomebrewNativeSourceStaging.select(evidence: evidence, configuration: configuration, token: "asix-ax88179", purpose: .packageInstaller(path: "AX88179_178A_Uninstall.pkg")))
        XCTAssertThrowsError(try HomebrewNativeSourceStaging.select(evidence: evidence, configuration: configuration, token: "zoom", purpose: .packageInstaller(path: "Unselected.pkg")))
        XCTAssertThrowsError(try HomebrewNativeSourceStaging.select(evidence: evidence, configuration: configuration, token: "adobe-connect", purpose: .vendorInstaller(executable: "AdobeConnectInstaller.app")))
        XCTAssertThrowsError(try HomebrewNativeSourceStaging.select(evidence: evidence, configuration: configuration, token: "sound-siphon", purpose: .relativeRemoval(recipeExecutable: configuration.appDirectory.path + "/Sound Siphon.app/Contents/Resources/uninstall_soundsiphon")))
    }
    func testConfirmedFixturePackageStagesThroughActualWorkerWithoutInstalledProgramShortcut() throws {
        XCTAssertNotEqual(getuid(), 0, "Owned current-UID fixture; no Root production or publisher body claim")
        let root = URL(fileURLWithPath: "/private/tmp/spinnet-stage-only-" + UUID().uuidString)
        try NativeFileQuarantine.makePrivateDirectory(root)
        var retain = false; defer { if !retain { try? FileManager.default.removeItem(at: root) } }
        let evidence = try catalog(), configuration = try config(root: root)
        let token = "actual-odbc-pack", purpose = HomebrewNativeSourceStaging.Purpose.packageInstaller(path: "Actual ODBC Pack.pkg")
        let record = try evidence.catalog.project(token, configuration: configuration)
        XCTAssertEqual(record["sha256"], .string("no_check"))
        guard case .string(let urlText)? = record["url"] else { return XCTFail("Signed URL missing") }
        let original = root.appendingPathComponent("fixed-fixture.pkg")
        let bytes = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "vendor-origin-product", withExtension: "pkg", subdirectory: "ArchiveFixtures")))
        try bytes.write(to: original); XCTAssertEqual(chmod(original.path, 0o400), 0)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let projection = try evidence.catalog.projectionDigest(token, configuration: configuration)
        let fields: [String: Any] = ["fileURL": original.absoluteString, "sha256": hash(bytes), "sourceURL": urlText, "byteCount": bytes.count,
            "sourceSHA256": evidence.catalog.envelopeSHA256, "projectionSHA256": projection, "configurationSHA256": hash(try encoder.encode(configuration))]
        let confirmed = try JSONDecoder().decode(HomebrewNoCheckSnapshot.Result.self, from: JSONSerialization.data(withJSONObject: fields))
        XCTAssertThrowsError(try HomebrewNativeSourceStaging.select(evidence: evidence, configuration: configuration, token: token, purpose: purpose))
        let stage = root.appendingPathComponent("stage"); try NativeFileQuarantine.makePrivateDirectory(stage)
        let envelope = stage.appendingPathComponent("homebrew-source.jws.json"); try evidence.envelope.write(to: envelope); XCTAssertEqual(chmod(envelope.path, 0o600), 0)
        let request = HomebrewNativeVendorOriginWorker.Request(envelope: envelope, sourceSHA256: evidence.catalog.envelopeSHA256,
            projectionSHA256: projection, configuration: configuration, token: token, recipeExecutable: "", confirmedSnapshot: confirmed,
            originalDownload: original, staging: stage, ownerUID: getuid(), deadline: Date().addingTimeInterval(30), operation: .sourceTree(purpose))
        let response = try HomebrewNativeVendorOriginExecution.capture(request, toolsDirectory: Bundle(for: Self.self).bundleURL.deletingLastPathComponent())
        retain = response.state == .unknown || response.response?.recoveryDirectory != nil
        XCTAssertEqual(response.state, .completed); XCTAssertNil(response.response?.failure); XCTAssertNil(response.response?.proof)
        let proof = try XCTUnwrap(response.response?.sourceTreeProof)
        XCTAssertEqual(proof.kind, .confirmedHostSnapshot); XCTAssertEqual(proof.purpose, purpose); XCTAssertEqual(proof.container, .package)
        XCTAssertEqual(proof.installerFile, "original-installer.pkg")
        let preserved = try Data(contentsOf: stage.appendingPathComponent("original-installer.pkg"))
        XCTAssertEqual(preserved.prefix(4), Data("xar!".utf8)); XCTAssertEqual(hash(preserved), hash(bytes))
        XCTAssertGreaterThan(proof.expandedBytes, Int64(bytes.count))
        XCTAssertEqual(proof.resourceDirectory, "original"); XCTAssertGreaterThan(proof.expandedBytes, 0); XCTAssertGreaterThan(proof.expandedEntries, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.appendingPathComponent("original/vendor-origin-latest.pkg/Payload").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.appendingPathComponent("original-download").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: envelope.path))
        let tiny = root.appendingPathComponent("tiny-stage"); try NativeFileQuarantine.makePrivateDirectory(tiny)
        let tinyEnvelope = tiny.appendingPathComponent("homebrew-source.jws.json"); try evidence.envelope.write(to: tinyEnvelope)
        XCTAssertEqual(chmod(tinyEnvelope.path, 0o600), 0)
        let tinyRequest = HomebrewNativeVendorOriginWorker.Request(envelope: tinyEnvelope, sourceSHA256: evidence.catalog.envelopeSHA256,
            projectionSHA256: projection, configuration: configuration, token: token, recipeExecutable: "", confirmedSnapshot: confirmed,
            originalDownload: original, staging: tiny, ownerUID: getuid(), deadline: Date().addingTimeInterval(30), maximumBytes: Int64(bytes.count - 1), operation: .sourceTree(purpose))
        let refusal = try HomebrewNativeVendorOriginExecution.capture(tinyRequest, toolsDirectory: Bundle(for: Self.self).bundleURL.deletingLastPathComponent())
        XCTAssertEqual(refusal.state, .completed); XCTAssertEqual(refusal.response?.failure, .outputTooLarge)
        XCTAssertNil(refusal.response?.sourceTreeProof)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tiny.appendingPathComponent("original-installer.pkg").path))
    }
    private func catalog() throws -> HomebrewSignedCaskCatalog.Evidence {
        try HomebrewSignedCaskCatalog.load(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/Homebrew/api/internal/packages.arm64_golden_gate.jws.json"), deadline: Date().addingTimeInterval(10))
    }
    private func config(root: URL) throws -> HomebrewSignedCaskCatalog.Configuration {
        try .init(languages: [], home: URL(fileURLWithPath: NSHomeDirectory()), prefix: root.appendingPathComponent("prefix"), appDirectory: root.appendingPathComponent("apps"))
    }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
