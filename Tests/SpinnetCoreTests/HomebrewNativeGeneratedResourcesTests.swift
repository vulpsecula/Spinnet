import XCTest
import SpinnetCore
@testable import SpinnetReviewedTools
import Foundation

final class HomebrewNativeGeneratedResourcesTests: XCTestCase {
    func testGeneratedResourcesCreatePrivateParentsAndReplaceOnlySealedRegularFiles() throws {
        let tree = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try NativeFileQuarantine.makePrivateDirectory(tree)
        defer { try? FileManager.default.removeItem(at: tree) }
        let old = tree.appendingPathComponent("existing.sh")
        try Data("old".utf8).write(to: old)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: old.path)
        try HomebrewNativeGeneratedResources.stage([.init(path: "existing.sh", content: "new"), .init(path: "scripts/nested/generated.sh", content: "#!/bin/sh\nexit 0\n")], into: tree, deadline: Date().addingTimeInterval(5))
        XCTAssertEqual(try String(contentsOf: old, encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: tree.appendingPathComponent("scripts/nested/generated.sh"), encoding: .utf8), "#!/bin/sh\nexit 0\n")
        let outside = tree.appendingPathComponent("protected")
        try Data("preserved".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(atPath: tree.appendingPathComponent("unsafe.sh").path, withDestinationPath: "protected")
        XCTAssertThrowsError(try HomebrewNativeGeneratedResources.stage([.init(path: "unsafe.sh", content: "overwritten")], into: tree, deadline: Date().addingTimeInterval(5)))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "preserved")
    }
}
