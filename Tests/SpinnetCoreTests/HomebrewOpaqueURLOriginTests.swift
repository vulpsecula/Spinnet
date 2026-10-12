import XCTest
import CryptoKit
import Darwin
import SpinnetCore

final class HomebrewOpaqueURLOriginTests: XCTestCase {
    func testRealSignedOpaqueURLAndOwnedConfirmedDMGProduceFullSupervisedMemberProof() throws {
        XCTAssertNotEqual(getuid(), 0, "Current-UID fixed Host-confirmation fixture; no real publisher download/historical claim")
        let root = URL(fileURLWithPath: "/private/tmp/spinnet-opaque-source-" + UUID().uuidString).resolvingSymlinksInPath()
        try NativeFileQuarantine.makePrivateDirectory(root)
        var retain = false
        defer { if !retain { try? FileManager.default.removeItem(at: root) } }
        let cached = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/Homebrew/api/internal/packages.arm64_golden_gate.jws.json")
        let evidence = try HomebrewSignedCaskCatalog.load(cached, deadline: Date().addingTimeInterval(10))
        let configuration = try HomebrewSignedCaskCatalog.Configuration(languages: [], home: URL(fileURLWithPath: NSHomeDirectory()),
            prefix: root.appendingPathComponent("prefix"), appDirectory: root.appendingPathComponent("apps"))
        let record = try evidence.catalog.project("sound-siphon", configuration: configuration)
        guard case .string(let sourceText)? = record["url"], let sourceURL = URL(string: sourceText), record["sha256"] == .string("no_check") else { return XCTFail("Actual signed fixture record changed") }
        XCTAssertTrue(sourceURL.pathExtension.isEmpty)
        let member = "Sound Siphon.app/Contents/Resources/uninstall_soundsiphon"
        let imageSource = root.appendingPathComponent("image-source"), installed = configuration.appDirectory.appendingPathComponent(member)
        for file in [imageSource.appendingPathComponent(member), installed] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file); XCTAssertEqual(chmod(file.path, 0o700), 0)
        }
        try Data("original fixture resources".utf8).write(to: imageSource.appendingPathComponent("Sound Siphon.app/Contents/Resources/data"))
        let image = root.appendingPathComponent("confirmed-source")
        let create = Process(), done = DispatchSemaphore(value: 0)
        create.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        create.arguments = ["create", "-srcfolder", imageSource.path, "-format", "UDRO", "-volname", "SpinnetOwnedOpaqueFixture", image.path]
        create.standardOutput = FileHandle.nullDevice; create.standardError = FileHandle.nullDevice
        create.terminationHandler = { _ in done.signal() }; try create.run()
        guard done.wait(timeout: .now() + 30) == .success else { retain = true; create.terminate(); throw PluginHostServiceError.tool(.timedOut) }
        XCTAssertEqual(create.terminationStatus, 0)
        // hdiutil may append .dmg; the source worker never relies on its name.
        let actualImage = FileManager.default.fileExists(atPath: image.path) ? image : image.appendingPathExtension("dmg")
        XCTAssertGreaterThan(try NativeFileQuarantine.capture(actualImage).size, 4096)
        XCTAssertEqual(chmod(actualImage.path, 0o400), 0)
        let bytes = try Data(contentsOf: actualImage), projection = try evidence.catalog.projectionDigest("sound-siphon", configuration: configuration)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let configSHA = hash(try encoder.encode(configuration))
        // Host fixture journal constructed before confirmation/capture. It is
        // data authority from fixed fixture bytes, not a publisher checksum.
        let fields: [String: Any] = ["fileURL": actualImage.absoluteString, "sha256": hash(bytes), "sourceURL": sourceURL.absoluteString,
            "byteCount": bytes.count, "sourceSHA256": evidence.catalog.envelopeSHA256, "projectionSHA256": projection, "configurationSHA256": configSHA]
        let confirmed = try JSONDecoder().decode(HomebrewNoCheckSnapshot.Result.self, from: JSONSerialization.data(withJSONObject: fields))
        let stage = root.appendingPathComponent("stage")
        try NativeFileQuarantine.makePrivateDirectory(stage)
        let envelope = stage.appendingPathComponent("homebrew-source.jws.json")
        try evidence.envelope.write(to: envelope); XCTAssertEqual(chmod(envelope.path, 0o600), 0)
        let request = HomebrewNativeVendorOriginWorker.Request(envelope: envelope, sourceSHA256: evidence.catalog.envelopeSHA256,
            projectionSHA256: projection, configuration: configuration, token: "sound-siphon", recipeExecutable: installed.path,
            confirmedSnapshot: confirmed, originalDownload: actualImage, staging: stage, ownerUID: getuid(), deadline: Date().addingTimeInterval(30), maximumBytes: 4096)
        let result = try HomebrewNativeVendorOriginExecution.capture(request, toolsDirectory: Bundle(for: Self.self).bundleURL.deletingLastPathComponent())
        retain = result.state == .unknown || result.response?.recoveryDirectory != nil
        XCTAssertEqual(result.state, .completed)
        XCTAssertNil(result.response?.failure); XCTAssertNil(result.response?.unavailable)
        let proof = try XCTUnwrap(result.response?.proof)
        XCTAssertEqual(proof.kind, .confirmedHostSnapshotMatch); XCTAssertEqual(proof.resourceDirectory, "original")
        XCTAssertEqual(proof.match.installed.inode, try NativeFileQuarantine.capture(installed).inode)
        XCTAssertEqual(proof.match.member, member)
        XCTAssertGreaterThan(proof.expandedBytes, 0); XCTAssertGreaterThan(proof.expandedEntries, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.appendingPathComponent("original-download").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: envelope.path))
        XCTAssertEqual(try String(contentsOf: stage.appendingPathComponent("original/Sound Siphon.app/Contents/Resources/data")), "original fixture resources")
    }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
