import XCTest
import SpinnetCore

final class HomebrewNativeManualOutcomeTests: XCTestCase {
    func testManualResultNeedsThisExactConfirmedArtifactRatherThanAnotherToolsExit78() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let cask = HomebrewPrivilegePlan.Cask(name: "example", version: "1", sha256: String(repeating: "a", count: 64), packages: [], manualInstallers: ["Installer.app"])
        let plan = try HomebrewPrivilegePlan(taskID: "activity_manual", prefix: "/opt/homebrew", casks: [cask])
        XCTAssertFalse(HomebrewNativeManualOutcome.confirmed(in: directory, plan: plan))
        let file = directory.appendingPathComponent("manual-outcome.json")
        func write(_ name: String, path: String = "Installer.app") throws {
            let bytes = try JSONSerialization.data(withJSONObject: ["taskID": plan.taskID, "package": name, "version": "1", "sha256": cask.sha256, "path": path])
            try bytes.write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        try write("example"); XCTAssertTrue(HomebrewNativeManualOutcome.confirmed(in: directory, plan: plan))
        try write("other"); XCTAssertFalse(HomebrewNativeManualOutcome.confirmed(in: directory, plan: plan))
        try write("example", path: "Other.app"); XCTAssertFalse(HomebrewNativeManualOutcome.confirmed(in: directory, plan: plan))
        try write("example"); try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: file.path)
        XCTAssertFalse(HomebrewNativeManualOutcome.confirmed(in: directory, plan: plan))
        XCTAssertThrowsError(try HomebrewNativeInstallerContinuation.parse(Data("SpinnetManualInstallation\n".utf8), exitStatus: 0))
    }
}
