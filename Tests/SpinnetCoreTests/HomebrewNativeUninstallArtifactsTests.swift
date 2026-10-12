import XCTest
import SpinnetCore

final class HomebrewNativeUninstallArtifactsTests: XCTestCase {
    func testActualSignedAdobeUninstallerSelectsImmutableDownloadMemberAndFrozenArguments() throws {
        let envelope = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/Homebrew/api/internal/packages.arm64_golden_gate.jws.json")
        let source = try HomebrewSignedCaskCatalog.load(envelope, deadline: Date().addingTimeInterval(5))
        let config = try HomebrewSignedCaskCatalog.Configuration(languages: [], home: URL(fileURLWithPath: NSHomeDirectory()), prefix: URL(fileURLWithPath: "/opt/homebrew"), appDirectory: URL(fileURLWithPath: "/Applications"))
        let metadata = try source.catalog.project("adobe-air", configuration: config)
        guard case .string(let version)? = metadata["version"] else { return XCTFail("missing actual source version") }
        let actions = try HomebrewNativeUninstallArtifacts.select(metadata, includeZap: false, prefix: "/opt/homebrew", token: "adobe-air", version: version, appDirectory: "/Applications")
        let action = try XCTUnwrap(actions.first)
        XCTAssertEqual(action.script.phase, .uninstall)
        XCTAssertEqual(action.script.executable, "Adobe AIR Installer.app/Contents/MacOS/Adobe AIR Installer")
        XCTAssertEqual(action.script.arguments, ["-uninstall"])
        XCTAssertTrue(action.script.mustSucceed)
    }
    func testArbitraryAbsoluteInstalledCodeCannotAcquireAnArchiveOrigin() throws {
        let metadata: [String: JSONValue] = ["artifacts": .array([.object(["uninstall": .array([.object(["script": .object(["executable": .string("/Library/Application Support/Vendor/uninstall.sh"), "sudo": .bool(true)])])])])])]
        XCTAssertThrowsError(try HomebrewNativeUninstallArtifacts.select(metadata, includeZap: false, prefix: "/opt/homebrew", token: "vendor", version: "1", appDirectory: "/Applications"))
    }
}
