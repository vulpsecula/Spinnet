import XCTest
import SpinnetCore
import Darwin

final class HomebrewNativeSourceRetentionTests: XCTestCase {
    func testLocalIndexOnlyLocatesActualSignatureAndAliasesCannotChangeVersionAuthority() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spinnet-retained-source-" + UUID().uuidString)
        try NativeFileQuarantine.makePrivateDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let envelope = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/Homebrew/api/internal/packages.arm64_golden_gate.jws.json")
        let evidence = try HomebrewSignedCaskCatalog.load(envelope, deadline: Date().addingTimeInterval(10))
        let configuration = try HomebrewSignedCaskCatalog.Configuration(languages: [], home: URL(fileURLWithPath: NSHomeDirectory()),
            prefix: URL(fileURLWithPath: "/opt/homebrew"), appDirectory: URL(fileURLWithPath: "/Applications"))
        let selected = try evidence.catalog.project("adobe-air", configuration: configuration)
        guard case .string(let version)? = selected["version"] else { return XCTFail("Actual source version missing") }
        let retained = root.appendingPathComponent(evidence.catalog.envelopeSHA256)
        try NativeFileQuarantine.makePrivateDirectory(retained)
        let held = retained.appendingPathComponent("homebrew-source.jws.json")
        try evidence.envelope.write(to: held)
        let proof = HomebrewPrivilegePlan.SourceProof(envelope: held, envelopeSHA256: evidence.catalog.envelopeSHA256,
            projectionSHA256: try evidence.catalog.projectionDigest("adobe-air", configuration: configuration), configuration: configuration)
        try HomebrewNativeSourceRetention.retain(proof, name: "homebrew/cask/adobe-air", version: version, in: root)
        XCTAssertEqual(try HomebrewNativeSourceRetention.lookup(name: "adobe-air", version: version, configuration: configuration,
            in: root, deadline: Date().addingTimeInterval(10)), proof)
        XCTAssertThrowsError(try HomebrewNativeSourceRetention.lookup(name: "adobe-air", version: "unrelated-version", configuration: configuration,
            in: root, deadline: Date().addingTimeInterval(10)))
        let index = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("retained-source-") })
        try FileManager.default.removeItem(at: index)
        XCTAssertEqual(symlink(held.path, index.path), 0)
        XCTAssertThrowsError(try HomebrewNativeSourceRetention.lookup(name: "adobe-air", version: version, configuration: configuration,
            in: root, deadline: Date().addingTimeInterval(10))) { error in
            XCTAssertEqual(error as? PluginHostServiceError, .tool(.planChanged), "A linked index is changed evidence, never a missing-signature fallback")
        }
    }
}
