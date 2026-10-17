import Foundation
import XCTest
import SpinnetCore

final class HomebrewPrivilegeCompatibilityTests: XCTestCase {
    func testHostAndRunnerRequireTheSameReviewedHomebrewSources() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/SpinnetToolTaskRunner/Resources/HomebrewPrivilegeBridge.rb"))
        let pattern = try NSRegularExpression(pattern: #""([^"]+\.rb)" => "([a-f0-9]{64})""#)
        let range = NSRange(text.startIndex..., in: text)
        let pairs = pattern.matches(in: text, range: range).map { match -> (String, String) in
            let path = Range(match.range(at: 1), in: text)!, digest = Range(match.range(at: 2), in: text)!
            return (String(text[path]), String(text[digest]))
        }
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: pairs), HomebrewPrivilegeReview.reviewedSourceDigests)
    }

    func testReviewedInstalledSourcesPassAndChangingEachFileRemainsRefused() throws {
        let installed: URL
        do { installed = try HomebrewReadProfile.discover() }
        catch { throw XCTSkip("Homebrew is unavailable for the read-only source compatibility probe") }
        XCTAssertNoThrow(try HomebrewPrivilegeReview.checkCompatibility(executable: installed))
        let installedLibrary = installed.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Library/Homebrew")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Library/Homebrew"), executable = root.appendingPathComponent("bin/brew")
        for path in HomebrewPrivilegeReview.reviewedSourceDigests.keys {
            let target = library.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: installedLibrary.appendingPathComponent(path), to: target)
        }
        try HomebrewPrivilegeReview.checkCompatibility(executable: executable)
        for path in HomebrewPrivilegeReview.reviewedSourceDigests.keys.sorted() {
            let target = library.appendingPathComponent(path), original = try Data(contentsOf: target)
            try (original + Data("\n# unreviewed change\n".utf8)).write(to: target)
            XCTAssertThrowsError(try HomebrewPrivilegeReview.checkCompatibility(executable: executable), path) {
                XCTAssertTrue($0.localizedDescription.contains("source revision needs review"))
            }
            try original.write(to: target)
        }
        try HomebrewPrivilegeReview.checkCompatibility(executable: executable)
    }
}
