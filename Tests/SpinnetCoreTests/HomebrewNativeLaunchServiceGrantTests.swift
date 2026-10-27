import XCTest
import Darwin
@testable import SpinnetCore
@testable import SpinnetReviewedTools

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
        var captures = 0
        XCTAssertTrue(try grant.revalidateEmptyRemoval(manifest) { captures += 1; return manifest })
        XCTAssertEqual(captures, 1, "Even an empty phase requires a fresh read before skipping authorization")
        XCTAssertThrowsError(try grant.revalidateEmptyRemoval(manifest) { throw PluginHostServiceError.tool(.timedOut) })
        var changed = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any])
        var coverage = try XCTUnwrap(changed["coverage"] as? [[String: Any]])
        coverage[0]["fileCount"] = (coverage[0]["fileCount"] as? Int ?? 0) + 1
        changed["coverage"] = coverage
        let drift = try JSONDecoder().decode(HomebrewNativeLaunchServices.Manifest.self, from: JSONSerialization.data(withJSONObject: changed))
        XCTAssertThrowsError(try grant.revalidateEmptyRemoval(manifest) { drift }, "A changed inventory cannot become a no-op or gain removal authority")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(grant)) as? [String: Any])
        object["bytesSHA256"] = String(repeating: "a", count: 64)
        let substituted = try JSONDecoder().decode(HomebrewNativeLaunchServiceGrant.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try substituted.load(owner: getuid(), deadline: Date().addingTimeInterval(2)))
    }
}
