import XCTest
@testable import SpinnetCore
import Foundation
import Darwin

final class HomebrewRetainedPublisherEvidenceTests: XCTestCase {
    func testRetainedSignedSourceRefusesForgedGeneratedCodeAndPreservesManualOutcome() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().appendingPathComponent("native-admission-" + UUID().uuidString)
        try NativeFileQuarantine.makePrivateDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = try HomebrewSignedCatalogFixture.snapshot("libreoffice-language-pack", languages: ["zh-CN"])
        let evidence = try XCTUnwrap(snapshot.officialEvidence), configuration = try XCTUnwrap(snapshot.configuration)
        guard case .string(let version)? = snapshot.metadata["version"],
              case .string(let checksum)? = snapshot.metadata["sha256"],
              case .string(let downloadURL)? = snapshot.metadata["url"] else { return XCTFail("Missing signed artifact identity") }
        let selected = try HomebrewNativeArtifacts.select(snapshot.metadata, prefix: "/opt/homebrew", token: "libreoffice-language-pack", version: version)
        let source = try snapshot.persistOfficialEvidence(in: directory)
        let proof = HomebrewPrivilegePlan.SourceProof(envelope: source, envelopeSHA256: evidence.catalog.envelopeSHA256,
            projectionSHA256: try evidence.catalog.projectionDigest("libreoffice-language-pack", configuration: configuration), configuration: configuration)
        let binding = HomebrewPrivilegePlan.Cask(name: "libreoffice-language-pack", version: version, sha256: checksum,
            packages: selected.packages.map(\.path), packageInstallers: selected.packages,
            nativeScripts: selected.scripts, generatedResources: selected.generatedResources, sourceProof: proof,
            manualInstallers: selected.manualInstallers, downloadURL: downloadURL)
        let script = try XCTUnwrap(binding.nativeScripts?.first)
        XCTAssertEqual(script.executable, "SilentInstall.sh")
        XCTAssertFalse(try XCTUnwrap(script.generatedContent).isEmpty)
        XCTAssertNotNil(binding.sourceProof)
        XCTAssertTrue(HomebrewNativeCompletionPolicy.hasManualOutcome(binding))
        XCTAssertFalse(HomebrewNativeCompletionPolicy.hasManualOutcome(.init(name: "ordinary", version: "1", sha256: String(repeating: "a", count: 64), packages: ["ordinary.pkg"])))
        let heldSource = try HomebrewSignedCaskCatalog.load(proof.envelope, deadline: Date().addingTimeInterval(5))
        let catalog = heldSource.catalog
        _ = try binding.validatePublisherSource(prefix: "/opt/homebrew", owner: getuid(), deadline: Date().addingTimeInterval(5), evidence: heldSource)
        var forged = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(binding)) as? [String: Any])
        var files = try XCTUnwrap(forged["generatedResources"] as? [[String: Any]])
        files[0]["content"] = "#!/bin/sh\n/usr/bin/touch /unreviewed\n"
        forged["generatedResources"] = files
        let forgedBinding = try JSONDecoder().decode(HomebrewPrivilegePlan.Cask.self, from: JSONSerialization.data(withJSONObject: forged))
        XCTAssertThrowsError(try forgedBinding.validatePublisherSource(prefix: "/opt/homebrew", owner: getuid(), deadline: Date().addingTimeInterval(5), evidence: heldSource))
        let neutral = try HomebrewNativeGeneratedScript.neutralConfiguration(languages: proof.configuration.languages)
        let projected = try catalog.project("libreoffice-language-pack", configuration: neutral)
        let selection = try HomebrewNativeArtifacts.select(projected, prefix: neutral.prefix.path, token: "libreoffice-language-pack", version: binding.version)
        let body = try XCTUnwrap(selection.scripts.first?.generatedContent)
        let adapted = try XCTUnwrap(HomebrewNativeCompletionPolicy.adapt(body, token: "libreoffice-language-pack", version: binding.version))
        XCTAssertEqual(adapted.components(separatedBy: "exit 78").count - 1, 2)
        XCTAssertNil(HomebrewNativeCompletionPolicy.adapt(body + "# changed publisher behavior\n", token: "libreoffice-language-pack", version: binding.version))
        let rendered = try HomebrewNativeGeneratedScript.render(template: adapted, home: directory, prefix: URL(fileURLWithPath: "/opt/homebrew"), appDirectory: directory.appendingPathComponent("missing-apps"), payload: directory, stagedRelativePrefix: "/Caskroom/libreoffice-language-pack/" + binding.version + "/")
        let ownedScript = directory.appendingPathComponent("manual-outcome.sh")
        try Data(rendered.content.utf8).write(to: ownedScript)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ownedScript.path)
        var env = rendered.environment; env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        let done = expectation(description: "missing prerequisite is manual incomplete")
        let process = HomebrewTaskProcess(executable: ownedScript, arguments: [], environment: env)
        try process.start(output: { _ in }, finished: { result in XCTAssertEqual(result.exitStatus, 78); XCTAssertEqual(result.outcome, "failed"); done.fulfill() })
        wait(for: [done], timeout: 5)
    }
    func testSignedUserOnlyVendorInstallerCreatesNoPrivilegedArtifact() throws {
        let snapshot = try HomebrewSignedCatalogFixture.snapshot("amazon-music")
        guard case .string(let version)? = snapshot.metadata["version"] else { return XCTFail("Missing signed version") }
        let selected = try HomebrewNativeArtifacts.select(snapshot.metadata, prefix: "/opt/homebrew", token: "amazon-music", version: version)
        XCTAssertTrue(selected.packages.isEmpty)
        XCTAssertTrue(selected.scripts.isEmpty)
        XCTAssertTrue(selected.manualInstallers.isEmpty)
    }
}
