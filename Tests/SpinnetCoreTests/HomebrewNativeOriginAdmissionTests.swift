import XCTest
import SpinnetCore
@testable import SpinnetReviewedTools
import Darwin

final class HomebrewNativeOriginAdmissionTests: XCTestCase {
    func testActualSignedNoCheckSelectionMatchesOnlyOwnedFixtureBytesAndFreezesAnExecutableGrant() throws {
        XCTAssertNotEqual(getuid(), 0, "Current-UID fixture, not production Root authorization")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spinnet-origin-admission-" + UUID().uuidString)
        try NativeFileQuarantine.makePrivateDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let cached = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/Homebrew/api/internal/packages.arm64_golden_gate.jws.json")
        let evidence = try HomebrewSignedCaskCatalog.load(cached, deadline: Date().addingTimeInterval(10))
        let configuration = try HomebrewSignedCaskCatalog.Configuration(languages: [], home: URL(fileURLWithPath: NSHomeDirectory()),
            prefix: root.appendingPathComponent("prefix"), appDirectory: root.appendingPathComponent("apps"))
        let metadata = try evidence.catalog.project("sound-siphon", configuration: configuration)
        guard case .string(let version)? = metadata["version"], metadata["sha256"] == .string("no_check") else { return XCTFail("Actual signed fixture source changed") }
        let member = "Sound Siphon.app/Contents/Resources/uninstall_soundsiphon"
        let installed = configuration.appDirectory.appendingPathComponent(member)
        let sourceDirectory = root.appendingPathComponent("source")
        let original = sourceDirectory.appendingPathComponent(member)
        try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fixtureBytes = Data("#!/bin/sh\nexit 0\n".utf8)
        try fixtureBytes.write(to: original); try fixtureBytes.write(to: installed)
        XCTAssertEqual(chmod(original.path, 0o700), 0); XCTAssertEqual(chmod(installed.path, 0o700), 0)
        try Data("full original resource tree".utf8).write(to: original.deletingLastPathComponent().appendingPathComponent("resources"))
        let image = root.appendingPathComponent("fixture.dmg")
        let create = Process(), created = DispatchSemaphore(value: 0)
        create.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        create.arguments = ["create", "-srcfolder", sourceDirectory.path, "-format", "UDRO", "-volname", "SpinnetOwnedAdmissionFixture", image.path]
        create.standardOutput = FileHandle.nullDevice; create.standardError = FileHandle.nullDevice
        create.terminationHandler = { _ in created.signal() }
        try create.run()
        guard created.wait(timeout: .now() + 30) == .success else { create.terminate(); throw PluginHostServiceError.tool(.timedOut) }
        XCTAssertEqual(create.terminationStatus, 0)
        let envelope = root.appendingPathComponent("homebrew-source.jws.json")
        try evidence.envelope.write(to: envelope)
        let proof = HomebrewPrivilegePlan.SourceProof(envelope: envelope, envelopeSHA256: evidence.catalog.envelopeSHA256,
            projectionSHA256: try evidence.catalog.projectionDigest("sound-siphon", configuration: configuration), configuration: configuration)
        XCTAssertTrue(proof.valid, "Owned source proof path must be canonical: \(envelope.path)")
        XCTAssertEqual(configuration.home.path, String(cString: try XCTUnwrap(getpwuid(getuid())).pointee.pw_dir))
        let downloaded = try HomebrewNoCheckSnapshot.capturePinnedSource(proof: proof, name: "sound-siphon", into: root,
            deadline: Date().addingTimeInterval(15), allowConfirmedSourceMatch: true, fetch: { _, fd, _, _, _ in
                let bytes = try Data(contentsOf: image)
                try bytes.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < bytes.count {
                        let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset)
                        XCTAssertGreaterThan(count, 0); offset += count
                    }
                }
            })
        // The source signature is actual. The image and installed program are
        // disposable fixture bytes, with no historical publisher-body claim.
        let capture = try HomebrewNativeOriginAdmission.capture(source: proof, name: "sound-siphon", evidence: evidence,
            download: downloaded, recipeExecutable: installed.path, owner: getuid(), deadline: Date().addingTimeInterval(30))
        defer { try? FileManager.default.removeItem(at: capture.directory) }
        XCTAssertEqual(capture.proof.kind, .confirmedHostSnapshotMatch)
        XCTAssertEqual(capture.proof.match.installed.inode, try NativeFileQuarantine.capture(installed).inode)
        let selection = try HomebrewNativeRemovalCode.selectSource(proof: proof, name: "sound-siphon", installedVersion: version,
            includeZap: false, deadline: Date().addingTimeInterval(10), evidence: evidence, origins: [capture.proof], confirmedSnapshot: downloaded)
        let grant = try HomebrewNativeRemovalCode.freeze(selection, download: downloaded)
        XCTAssertEqual(grant.origins?.first, capture.proof)
        XCTAssertEqual(grant.actions.first?.script.executable, member)
        XCTAssertEqual(try String(contentsOf: capture.directory.appendingPathComponent("original/Sound Siphon.app/Contents/Resources/resources")), "full original resource tree")
        try Data("changed installed bytes".utf8).write(to: installed)
        XCTAssertThrowsError(try HomebrewNativeOriginAdmission.capture(source: proof, name: "sound-siphon", evidence: evidence,
            download: downloaded, recipeExecutable: installed.path, owner: getuid(), deadline: Date().addingTimeInterval(30)))
    }
}
