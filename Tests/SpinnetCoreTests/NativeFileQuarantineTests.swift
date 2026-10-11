import XCTest
import SpinnetCore

final class NativeFileQuarantineTests: XCTestCase {
    func testFrozenSymbolicLinkRemovalNeverChangesItsUnrelatedTarget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let target = root.appendingPathComponent("unrelated"), link = root.appendingPathComponent("link"), stage = root.appendingPathComponent("stage")
        try Data("unrelated user data".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let frozen = try NativeFileQuarantine.capture(link)
        try NativeFileQuarantine.makePrivateDirectory(stage)
        XCTAssertEqual(try NativeFileQuarantine.remove(link, expected: frozen, staging: stage), .removed)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "unrelated user data")
    }
    func testFrozenFileCanBeRemovedFromAnOrdinaryWritableContainerThroughPrivateQuarantine() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o775])
        let file = root.appendingPathComponent("owned-file"), stage = root.appendingPathComponent("private-stage")
        try Data("frozen installed bytes".utf8).write(to: file)
        let frozen = try NativeFileQuarantine.capture(file)
        try NativeFileQuarantine.makePrivateDirectory(stage)
        XCTAssertEqual(try NativeFileQuarantine.remove(file, expected: frozen, staging: stage), .removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: stage.path).isEmpty)
    }
    func testChangedFileBytesArePreservedEvenWhenTheSamePathAndInodeRemain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o775])
        let file = root.appendingPathComponent("owned-file"), stage = root.appendingPathComponent("private-stage")
        try Data("frozen installed bytes".utf8).write(to: file)
        let frozen = try NativeFileQuarantine.capture(file)
        try Data("edited installed bytes".utf8).write(to: file)
        let changed = try NativeFileQuarantine.capture(file)
        XCTAssertEqual(frozen.inode, changed.inode)
        XCTAssertNotEqual(frozen.sha256, changed.sha256)
        try NativeFileQuarantine.makePrivateDirectory(stage)
        XCTAssertThrowsError(try NativeFileQuarantine.remove(file, expected: frozen, staging: stage))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "edited installed bytes")
    }
    func testNonemptyDirectoryIsRestoredWithoutDeletingItsUnlistedContents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o775])
        let folder = root.appendingPathComponent("owned-folder"), stage = root.appendingPathComponent("private-stage")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("unlisted user data".utf8).write(to: folder.appendingPathComponent("keep"))
        let frozen = try NativeFileQuarantine.capture(folder)
        try NativeFileQuarantine.makePrivateDirectory(stage)
        XCTAssertEqual(try NativeFileQuarantine.remove(folder, expected: frozen, staging: stage), .keptNonemptyDirectory)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("keep"), encoding: .utf8), "unlisted user data")
    }
    func testRestoreCollisionRetainsQuarantinedBytesAndPreservesReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let file = root.appendingPathComponent("target"), stage = root.appendingPathComponent("stage")
        try Data("confirmed bytes".utf8).write(to: file)
        let frozen = try NativeFileQuarantine.capture(file)
        try NativeFileQuarantine.makePrivateDirectory(stage)
        do {
            _ = try NativeFileQuarantine.remove(file, expected: frozen, staging: stage, isCancelled: {
                if !FileManager.default.fileExists(atPath: file.path) { try? Data("replacement bytes".utf8).write(to: file); return true }
                return false
            })
            XCTFail("Cancellation with a replacement must retain the original")
        } catch NativeFileQuarantine.Failure.retained(let retained) {
            XCTAssertEqual(try String(contentsOf: retained, encoding: .utf8), "confirmed bytes")
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "replacement bytes")
        }
    }
    func testAcknowledgedStopAtMutationBoundaryRestoresOriginalWithoutDeletingIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let file = root.appendingPathComponent("target"), stage = root.appendingPathComponent("stage")
        try Data("confirmed bytes".utf8).write(to: file)
        let frozen = try NativeFileQuarantine.capture(file)
        try NativeFileQuarantine.makePrivateDirectory(stage)
        var mayMutate = true
        XCTAssertThrowsError(try NativeFileQuarantine.remove(file, expected: frozen, staging: stage, mutation: { action in
            guard mayMutate else { throw PluginHostServiceError.tool(.planChanged) }
            try action()
            mayMutate = false // The platform coordinator acknowledged Stop.
        }))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "confirmed bytes")
    }
    func testNoFollowPresenceDetectsDanglingReplacementLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let link = root.appendingPathComponent("replacement")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("missing"))
        XCTAssertTrue(try NativeFileQuarantine.existsWithoutFollowing(link))
        XCTAssertFalse(try NativeFileQuarantine.existsWithoutFollowing(root.appendingPathComponent("not-there")))
    }
    func testRemovingAnAccountedChildDoesNotInvalidateItsFrozenEmptyParentIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let folder = root.appendingPathComponent("owned"), stage = root.appendingPathComponent("stage")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let child = folder.appendingPathComponent("child")
        try Data("accounted".utf8).write(to: child)
        let frozenFolder = try NativeFileQuarantine.capture(folder), frozenChild = try NativeFileQuarantine.capture(child)
        try NativeFileQuarantine.makePrivateDirectory(stage)
        XCTAssertEqual(try NativeFileQuarantine.remove(child, expected: frozenChild, staging: stage), .removed)
        XCTAssertEqual(try NativeFileQuarantine.remove(folder, expected: frozenFolder, staging: stage), .removed)
    }
}
