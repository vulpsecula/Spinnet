import XCTest
import Darwin
import SpinnetCore

final class HomebrewNativeLaunchServiceGrantTests: XCTestCase {
    func testHeldParentChecksAllowKnownSiblingRemovalsButRefuseNamespaceSubstitution() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try NativeFileQuarantine.makePrivateDirectory(root); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), stage = root.appendingPathComponent("stage")
        try NativeFileQuarantine.makePrivateDirectory(source); try NativeFileQuarantine.makePrivateDirectory(stage)
        let descriptor = open(source.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0); defer { close(descriptor) }
        let parent = try NativePathParentSnapshot.captureDirectoryDescriptor(descriptor, deadline: Date().addingTimeInterval(5))
        for name in ["first.plist", "second.plist"] {
            let file = source.appendingPathComponent(name); try Data(name.utf8).write(to: file)
            let frozen = try NativeFileQuarantine.capture(file)
            XCTAssertEqual(try NativeFileQuarantine.remove(file, expected: frozen, staging: stage, expectedParent: parent), .removed)
        }
        let file = source.appendingPathComponent("third.plist"); try Data("owned".utf8).write(to: file)
        let frozen = try NativeFileQuarantine.capture(file), moved = root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: source, to: moved); try NativeFileQuarantine.makePrivateDirectory(source)
        try FileManager.default.moveItem(at: moved.appendingPathComponent("third.plist"), to: file)
        XCTAssertThrowsError(try NativeFileQuarantine.remove(file, expected: frozen, staging: stage, expectedParent: parent))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
    func testNativeGrantHoldsCompletePrivateBytesAndRefusesDigestOrPhaseSubstitution() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try NativeFileQuarantine.makePrivateDirectory(root); defer { try? FileManager.default.removeItem(at: root) }
        let context = try HomebrewNativeLaunchServices.Context(uid: getuid(), home: URL(fileURLWithPath: NSHomeDirectory()))
        let declarations = try [HomebrewNativeLaunchServices.Declaration("org.spinnet.disposable.missing")]
        let tools = try NativeSignedToolStaging.capture(["SpinnetLaunchServiceInventory"], deadline: Date().addingTimeInterval(10)); defer { tools.remove() }
        let outcome = try HomebrewNativeLaunchServiceExecution.capture(.init(context: context, declarations: declarations, deadline: Date().addingTimeInterval(10)), toolsDirectory: tools.directory)
        let manifest = try XCTUnwrap(outcome.response?.manifest)
        let grant = try HomebrewNativeLaunchServiceGrant.persist(manifest, phase: .uninstall, in: root)
        XCTAssertEqual(try grant.load(owner: getuid(), deadline: Date().addingTimeInterval(2)), manifest)
        XCTAssertTrue(grant.valid); XCTAssertEqual(grant.phase, .uninstall)
        XCTAssertEqual(grant.entryCount, 0); XCTAssertEqual(grant.unmatchedCount, 1)
        let cask = HomebrewPrivilegePlan.Cask(name: "example", version: "2", sha256: String(repeating: "a", count: 64), packages: [], launchServiceRemovals: [grant])
        let host = HostReviewedToolTasks(activities: .init(), journal: root.appendingPathComponent("tasks"), runnerURL: URL(fileURLWithPath: "/missing"),
            executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, preflight: { _ in
                .object(["name": .string("example"), "kind": .string("cask"), "tap": .string("homebrew/cask"),
                    "installed_version": .string("1"), "version": .string("2"), "needs_privileges": .bool(true)])
            }, trustedTaps: { [] }, privilegeReview: { _, _, _ in [cask] })
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("upgrade"), "kind": .string("cask"), "name": .string("example")]))
        let plan = try host.prepare(input, owner: .init("confirmation"), pluginName: "Homebrew")
        let details = try XCTUnwrap(plan.confirmation.details)
        XCTAssertEqual(details.actionRows.map(\.title), ["Upgrade example"], "Absent services must not appear as extra changes")
        XCTAssertEqual(details.verificationRows.count, 1, "Installed history stays available in verification details")
        XCTAssertFalse(details.rows.contains { $0.id.contains("/unmatched/") })
        XCTAssertEqual(plan.privilegedCasks.first?.launchServiceRemovals, [grant], "Presentation must not change the execution grant")
        host.decline(plan)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(grant)) as? [String: Any])
        object["bytesSHA256"] = String(repeating: "a", count: 64)
        let substituted = try JSONDecoder().decode(HomebrewNativeLaunchServiceGrant.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try substituted.load(owner: getuid(), deadline: Date().addingTimeInterval(2)))
    }
}
