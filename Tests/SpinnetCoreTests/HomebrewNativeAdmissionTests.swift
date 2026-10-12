import XCTest
import SpinnetCore
import Foundation
import Darwin

final class HomebrewNativeAdmissionTests: XCTestCase {
    func testActualSignedLanguageSourceAdmitsGeneratedInstallerBeforeConfirmation() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().appendingPathComponent("native-admission-" + UUID().uuidString)
        try NativeFileQuarantine.makePrivateDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("changeLanguage"), "kind": .string("cask"), "name": .string("libreoffice-language-pack"), "language": .string("zh-CN")]))
        let package: JSONValue = .object(["name": .string("libreoffice-language-pack"), "needs_privileges": .bool(true)])
        let bindings = try HomebrewPrivilegeReview.casks(input: input, package: package, executable: URL(fileURLWithPath: "/opt/homebrew/bin/brew"), evidenceDirectory: directory)
        let binding = try XCTUnwrap(bindings.first)
        XCTAssertEqual(binding.sha256, "bed798290092207dd40afe7976cbb4bae936fb20c26a5a3c263dcef34f678577")
        let script = try XCTUnwrap(binding.nativeScripts?.first)
        XCTAssertEqual(script.executable, "SilentInstall.sh")
        XCTAssertFalse(try XCTUnwrap(script.generatedContent).isEmpty)
        XCTAssertNotNil(binding.sourceProof)
        XCTAssertTrue(HomebrewNativeCompletionPolicy.hasManualOutcome(binding))
        XCTAssertFalse(HomebrewNativeCompletionPolicy.hasManualOutcome(.init(name: "ordinary", version: "1", sha256: String(repeating: "a", count: 64), packages: ["ordinary.pkg"])))
        let proof = try XCTUnwrap(binding.sourceProof)
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
    func testActualUserOnlyVendorInstallerNeverRequestsRootOrPreconfirmationDownload() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().appendingPathComponent("user-vendor-admission-" + UUID().uuidString)
        try NativeFileQuarantine.makePrivateDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("install"), "kind": .string("cask"), "name": .string("amazon-music")]))
        let package: JSONValue = .object(["name": .string("amazon-music"), "needs_privileges": .bool(true)])
        let bindings = try HomebrewPrivilegeReview.casks(input: input, package: package, executable: URL(fileURLWithPath: "/opt/homebrew/bin/brew"), evidenceDirectory: directory,
            fetchSnapshot: { _, _, _, _, _ in XCTFail("User-only vendor code must not enter Root byte freezing"); throw PluginHostServiceError.tool(.failed) })
        XCTAssertTrue(bindings.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

}

extension HomebrewNativeAdmissionTests {
    func testCancelledNativePreparationDoesNotReadSourceOrDownloadBeforeInitialConfirmation() throws {
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("install"), "kind": .string("cask"), "name": .string("example")]))
        let cancellation = HostFetchedSections.Cancellation(); cancellation.cancel()
        let began = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try HomebrewPrivilegeReview.casks(input: input, package: .object(["name": .string("example"), "needs_privileges": .bool(true)]),
            executable: URL(fileURLWithPath: "/no-source-can-be-read/bin/brew"), evidenceDirectory: URL(fileURLWithPath: "/no-evidence-can-be-written"), cancellation: cancellation)) {
                XCTAssertEqual($0 as? PluginHostServiceError, .tool(.planChanged))
            }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 0.1)
    }
}
