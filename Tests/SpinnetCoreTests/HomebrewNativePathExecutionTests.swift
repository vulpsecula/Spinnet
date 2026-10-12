import XCTest
import SpinnetCore
import Darwin

final class HomebrewNativePathExecutionTests: XCTestCase {
    func testFixedNativeSupervisorBindsARealWorkerToTheFrozenManifestAndReapsIt() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try NativeFileQuarantine.makePrivateDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in ["home/Vendor", "prefix", "apps", "quarantine"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        let selected = root.appendingPathComponent("home/Vendor/selected")
        try Data("frozen original".utf8).write(to: selected)
        let context = try HomebrewPathManifest.Context(home: root.appendingPathComponent("home"), prefix: root.appendingPathComponent("prefix"), appDirectory: root.appendingPathComponent("apps"))
        let inventory = try HomebrewPathManifest.WorkerConfiguration(executable: Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("SpinnetPathInventory"))
        let directive = try HomebrewPathManifest.Directive(kind: .delete, patterns: ["~/Vendor/selected"])
        let manifest = try HomebrewPathManifest.capture([directive], context: context, worker: inventory, deadline: Date().addingTimeInterval(5))
        var launched: Int32 = 0, reaped = false
        let outcome = try HomebrewNativePathExecution.execute(manifest, staging: root.appendingPathComponent("quarantine"), deadline: Date().addingTimeInterval(5), willStart: { _ in return true }, didReap: { process in launched = process.processIdentifier; reaped = true })
        XCTAssertEqual(outcome.state, .completed)
        XCTAssertEqual(outcome.response?.result?.removed, [selected.path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: selected.path))
        XCTAssertTrue(reaped)
        XCTAssertGreaterThan(launched, 0)
        XCTAssertNil(HomebrewTaskProcess.startIdentity(launched))
        try Data("not launched".utf8).write(to: selected)
        let notLaunched = try HomebrewPathManifest.capture([directive], context: context, worker: inventory, deadline: Date().addingTimeInterval(5))
        var cancelledReaped = false
        XCTAssertThrowsError(try HomebrewNativePathExecution.execute(notLaunched, staging: root.appendingPathComponent("quarantine"), deadline: Date().addingTimeInterval(5), willStart: { process in process.stop(); return true }, didReap: { _ in cancelledReaped = true }))
        XCTAssertTrue(cancelledReaped)
        XCTAssertEqual(try Data(contentsOf: selected), Data("not launched".utf8))
    }
}
