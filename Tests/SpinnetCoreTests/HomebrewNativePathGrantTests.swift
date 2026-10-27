import XCTest
import SpinnetCore
@testable import SpinnetReviewedTools
import Darwin

final class HomebrewNativePathGrantTests: XCTestCase {
    func testPrivateManifestGrantBindsHeldBytesContextDirectivesAndPayloadFingerprint() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try NativeFileQuarantine.makePrivateDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in ["home/Vendor", "prefix", "apps", "evidence"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        try Data("frozen payload".utf8).write(to: root.appendingPathComponent("home/Vendor/selected"))
        let context = try HomebrewPathManifest.Context(home: root.appendingPathComponent("home"), prefix: URL(fileURLWithPath: "/opt/homebrew"), appDirectory: root.appendingPathComponent("apps"))
        let worker = try HomebrewPathManifest.WorkerConfiguration(executable: Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("SpinnetPathInventory"))
        let directive = try HomebrewPathManifest.Directive(kind: .delete, patterns: ["~/Vendor"])
        let manifest = try HomebrewPathManifest.capture([directive], context: context, worker: worker, deadline: Date().addingTimeInterval(5))
        let grant = try HomebrewNativePathGrant.persist(manifest, in: root.appendingPathComponent("evidence"))
        XCTAssertEqual(try grant.load(owner: getuid(), deadline: Date().addingTimeInterval(5)), manifest)
        XCTAssertEqual(grant.concreteCount, 2)
        XCTAssertEqual(grant.context, context)
        XCTAssertEqual(grant.directives, [directive])
        XCTAssertLessThan(try JSONEncoder().encode(grant).count, 4096)
        let action = HomebrewNativePathAction(phase: .uninstallDelete, grant: grant)
        let cask = HomebrewPrivilegePlan.Cask(name: "vendor", version: "1", sha256: "", packages: [], pathRemovals: [action])
        // Prefix is fixed by the Host plan; an unrelated context cannot cross.
        XCTAssertThrowsError(try HomebrewPrivilegePlan(taskID: "activity_path", prefix: "/usr/local", casks: [cask], operation: "uninstall"))
        let plan = try HomebrewPrivilegePlan(taskID: "activity_path", prefix: "/opt/homebrew", casks: [cask], operation: "uninstall")
        XCTAssertNoThrow(try plan.validate(.init(taskID: "activity_path", package: "vendor", operation: .removePaths, source: "0", sha256: grant.manifestSHA256)))
        XCTAssertThrowsError(try plan.validate(.init(taskID: "activity_path", package: "vendor", operation: .removePaths, source: "00", sha256: grant.manifestSHA256)))
        XCTAssertThrowsError(try plan.validate(.init(taskID: "activity_path", package: "vendor", operation: .removePaths, source: "0", sha256: String(repeating: "a", count: 64))))
        let original = try Data(contentsOf: grant.manifestURL)
        XCTAssertEqual(chmod(grant.manifestURL.path, 0o600), 0)
        try Data("{}".utf8).write(to: grant.manifestURL)
        XCTAssertThrowsError(try grant.load(owner: getuid(), deadline: Date().addingTimeInterval(5)))
        try original.write(to: grant.manifestURL)
        XCTAssertEqual(chmod(grant.manifestURL.path, 0o400), 0)
        XCTAssertEqual(link(grant.manifestURL.path, root.appendingPathComponent("alias").path), 0)
        XCTAssertThrowsError(try grant.load(owner: getuid(), deadline: Date().addingTimeInterval(5)))
    }
}
