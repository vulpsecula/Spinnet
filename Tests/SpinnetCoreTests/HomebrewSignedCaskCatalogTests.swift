import XCTest
import SpinnetCore

final class HomebrewSignedCaskCatalogTests: XCTestCase {
    func testRootCanVerifyOfficialGeneratedCodeAndLanguageWithoutTrustingTheRubyProcess() throws {
        let bytes = try snapshot()
        let catalog = try HomebrewSignedCaskCatalog.verify(bytes)
        let cask = try catalog.project("libreoffice-language-pack", configuration: .init(languages: ["zh-CN"], home: URL(fileURLWithPath: NSHomeDirectory()), prefix: URL(fileURLWithPath: "/opt/homebrew"), appDirectory: URL(fileURLWithPath: "/Applications")))
        XCTAssertEqual(cask["language"], .string("zh-CN"))
        XCTAssertEqual(cask["sha256"], .string("bed798290092207dd40afe7976cbb4bae936fb20c26a5a3c263dcef34f678577"))
        guard case .array(let artifacts)? = cask["artifacts"] else { return XCTFail("Missing signed artifacts") }
        XCTAssertTrue(artifacts.contains { if case .object(let value) = $0 { return value["generated_script"] != nil }; return false })
    }
    func testChangedSignedEnvelopeAndForgedGeneratedBodyOrVendorArtifactHaveNoRootAuthority() throws {
        let bytes = try snapshot()
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        envelope["payload"] = (envelope["payload"] as? String)?.replacingOccurrences(of: "SilentInstall.sh", with: "TamperedInstall.sh")
        XCTAssertThrowsError(try HomebrewSignedCaskCatalog.verify(JSONSerialization.data(withJSONObject: envelope))) {
            XCTAssertEqual($0 as? PluginHostServiceError, .tool(.sourceNotAllowed))
        }
        let catalog = try HomebrewSignedCaskCatalog.verify(bytes)
        let configuration = try HomebrewSignedCaskCatalog.Configuration(languages: ["zh-CN"], home: URL(fileURLWithPath: NSHomeDirectory()), prefix: URL(fileURLWithPath: "/opt/homebrew"), appDirectory: URL(fileURLWithPath: "/Applications"))
        var generated = try catalog.project("libreoffice-language-pack", configuration: configuration)
        generated["artifacts"] = .array([.object(["generated_script": .array([.string("SilentInstall.sh"), .object(["content": .string("altered unprivileged process body")])])])])
        XCTAssertThrowsError(try catalog.validate(generated, token: "libreoffice-language-pack", configuration: configuration))
        var vendor = try catalog.project("adobe-air", configuration: configuration)
        vendor["artifacts"] = .array([.object(["installer": .array([.object(["script": .object(["executable": .string("different-vendor.app/Contents/MacOS/tool"), "sudo": .bool(true)])])])])])
        XCTAssertThrowsError(try catalog.validate(vendor, token: "adobe-air", configuration: configuration))
    }
    func testCopiedPreconfirmationEvidenceCanBeReverifiedAndChangedBytesAreRefused() throws {
        let snapshot = try HomebrewPrivilegeMetadata.readEvidence("libreoffice-language-pack", language: "zh-CN", deadline: Date().addingTimeInterval(15))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let source = try snapshot.persistOfficialEvidence(in: root)
        let verified = try HomebrewSignedCaskCatalog.read(source)
        XCTAssertEqual(verified.envelopeSHA256, snapshot.officialEvidence?.catalog.envelopeSHA256)
        try verified.validate(snapshot.metadata, token: "libreoffice-language-pack", configuration: XCTUnwrap(snapshot.configuration))
        try Data("changed source evidence".utf8).write(to: source)
        XCTAssertThrowsError(try HomebrewSignedCaskCatalog.read(source))
    }
    private func snapshot() throws -> Data {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/Homebrew/api/internal/packages.arm64_golden_gate.jws.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Native signed Homebrew snapshot missing") }
        return try Data(contentsOf: url)
    }
}
