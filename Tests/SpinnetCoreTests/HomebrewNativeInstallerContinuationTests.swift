import XCTest
import SpinnetCore
@testable import SpinnetReviewedTools
import Darwin

final class HomebrewNativeInstallerContinuationTests: XCTestCase {
    func testActualReadOnlyAppleInstallerMetadataOnOwnedPackages() throws {
        XCTAssertNotEqual(getuid(), 0, "Disposable packages, no Root install or user continuation")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spinnet-installer-query-" + UUID().uuidString).resolvingSymlinksInPath()
        try NativeFileQuarantine.makePrivateDirectory(root); defer { try? FileManager.default.removeItem(at: root) }
        let component = root.appendingPathComponent("component.pkg")
        _ = try run("/usr/bin/pkgbuild", ["--nopayload", "--identifier", "com.spinnet.disposable.metadata", "--version", "1", component.path])
        for action in ["None", "RequireRestart", "RequireLogout", "RequireShutdown"] {
            let distribution = root.appendingPathComponent(action + ".xml"), product = root.appendingPathComponent(action + ".pkg")
            let xml = "<?xml version=\"1.0\"?><installer-gui-script minSpecVersion=\"1\"><title>Disposable metadata only</title><options customize=\"never\"/><choices-outline><line choice=\"main\"/></choices-outline><choice id=\"main\" visible=\"false\"><pkg-ref id=\"com.spinnet.disposable.metadata\"/></choice><pkg-ref id=\"com.spinnet.disposable.metadata\" version=\"1\" onConclusion=\"\(action)\">component.pkg</pkg-ref></installer-gui-script>"
            try Data(xml.utf8).write(to: distribution)
            _ = try run("/usr/bin/productbuild", ["--distribution", distribution.path, "--package-path", root.path, product.path])
            let result = try run("/usr/sbin/installer", ["-query", "RestartAction", "-pkg", product.path])
            XCTAssertEqual(try HomebrewNativeInstallerContinuation.parse(result.output, exitStatus: result.status).rawValue, action)
        }
    }
    private func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: Data) {
        let process = HomebrewTaskProcess(executable: URL(fileURLWithPath: executable), arguments: arguments,
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"])
        let outcome = try HomebrewNativeCommandExecution.execute(process, timeout: 15, maximumOutputBytes: 64 * 1024)
        let result = try XCTUnwrap(outcome.result); XCTAssertEqual(outcome.state, .completed); XCTAssertEqual(result.exitStatus, 0, String(data: outcome.output, encoding: .utf8) ?? "nonUTF8")
        return (result.exitStatus, outcome.output)
    }
    func testFixedInstallerMetadataNeedsPreciseUserContinuation() throws {
        for (text, reason, stage) in [("None", nil, nil), ("RecommendRestart", nil, nil),
            ("RequireRestart", "restart_required", "awaiting restart"),
            ("RequireLogout", "logout_required", "awaiting logout"),
            ("RequireShutdown", "shutdown_required", "awaiting shutdown")] as [(String, String?, String?)] {
            let parsed = try HomebrewNativeInstallerContinuation.parse(Data((text + "\n").utf8), exitStatus: 0)
            XCTAssertEqual(parsed.reason, reason); XCTAssertEqual(parsed.stage, stage)
        }
        for text in ["", "None\nRequireRestart", "Warning: RequireRestart", "RequireRestart\0", "SpinnetManualInstallation\n", String(repeating: "x", count: 65_537)] {
            XCTAssertThrowsError(try HomebrewNativeInstallerContinuation.parse(Data(text.utf8), exitStatus: 0))
        }
        XCTAssertThrowsError(try HomebrewNativeInstallerContinuation.parse(Data("None".utf8), exitStatus: 1))
        XCTAssertThrowsError(try HomebrewNativeInstallerContinuation.parse(Data([255]), exitStatus: 0))
    }
}
