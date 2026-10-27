import Foundation
import XCTest
@testable import SpinnetCore
@testable import SpinnetReviewedTools

final class HomebrewNativeLinkPlanTests: XCTestCase {
    func testNativePreviewKeepsRawOutputAndCannotWriteOrInventAnExactFileGrant() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("bin/brew")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        #!/bin/sh
        case "$1" in
        --version) printf 'Homebrew 8.1.0\\n' ;;
        info) printf '%s\\n' '{"formulae":[{"name":"example","tap":"homebrew/core","versions":{"stable":"1"},"installed":[{"version":"1"}],"keg_only":false}],"casks":[]}' ;;
        link|unlink)
          [ "$2" = '--dry-run' ] || exit 64
          /usr/bin/touch "$0.mutated" 2>/dev/null && exit 65
          printf 'Would change links:\\n%s/example\\n' "${0%/brew}"
          ;;
        *) exit 64 ;;
        esac
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let profile = HomebrewReadProfile(executable: { executable })
        for operation in ["previewLink", "previewUnlink"] {
            let value = try profile.read(.object(["tool": .string("homebrew"), "operation": .string(operation),
                "kind": .string("formula"), "names": .array([.string("example")])]), owner: .init("native-link"), timeout: 15)
            XCTAssertEqual(value.value(atPointer: "/succeeded"), .bool(true))
            XCTAssertEqual(value.value(atPointer: "/no_op"), .bool(false))
            XCTAssertEqual(value.value(atPointer: "/paths/0"), .string(root.appendingPathComponent("bin/example").path))
            XCTAssertEqual(value.value(atPointer: "/changes"), .array([]), "CLI text cannot become an exact native action grant")
            XCTAssertFalse(FileManager.default.fileExists(atPath: executable.appendingPathExtension("mutated").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("bin/example").path))
        }
    }
}
