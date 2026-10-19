import Foundation
import XCTest
import SpinnetCore

final class HomebrewPrivilegeCompatibilityTests: XCTestCase {
    func testHostAndRunnerRequireTheSameReviewedHomebrewSources() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/SpinnetToolTaskRunner/Resources/HomebrewPrivilegeBridge.rb"))
        let pattern = try NSRegularExpression(pattern: #""([^"]+\.rb)" => "([a-f0-9]{64})""#)
        let legacy = text.components(separatedBy: "REVIEWED_SOURCE_UPDATES =")[0]
        let pairs = pattern.matches(in: legacy, range: NSRange(legacy.startIndex..., in: legacy)).map { match -> (String, String) in
            let path = Range(match.range(at: 1), in: legacy)!, digest = Range(match.range(at: 2), in: legacy)!
            return (String(legacy[path]), String(legacy[digest]))
        }
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: pairs), HomebrewPrivilegeReview.reviewedSourceDigests)
        let sections = try XCTUnwrap(text.components(separatedBy: "REVIEWED_SOURCE_UPDATES =").last)
        let updates = sections.components(separatedBy: "REVIEWED_SOURCE_CLEANUP_UPDATES =")[0]
        let changes = pattern.matches(in: updates, range: NSRange(updates.startIndex..., in: updates)).map { match -> (String, String) in
            (String(updates[Range(match.range(at: 1), in: updates)!]), String(updates[Range(match.range(at: 2), in: updates)!]))
        }
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: changes), HomebrewPrivilegeReview.reviewedSourceUpdates)
        let cleanup = try XCTUnwrap(sections.components(separatedBy: "REVIEWED_SOURCE_CLEANUP_UPDATES =").last)
        let cleanupChanges = pattern.matches(in: cleanup, range: NSRange(cleanup.startIndex..., in: cleanup)).map { match -> (String, String) in
            (String(cleanup[Range(match.range(at: 1), in: cleanup)!]), String(cleanup[Range(match.range(at: 2), in: cleanup)!]))
        }
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: cleanupChanges), HomebrewPrivilegeReview.reviewedSourceCleanupUpdates)
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
    func testBothCompleteReviewedCohortsPassWhileHybridAndUnknownSourcesFail() throws {
        let repository = URL(fileURLWithPath: "/opt/homebrew")
        guard FileManager.default.fileExists(atPath: repository.appendingPathComponent(".git").path) else { throw XCTSkip("Exact upstream Git source fixtures unavailable") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func source(_ revision: String, _ path: String) throws -> Data {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", repository.path, "show", revision + ":Library/Homebrew/" + path]
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw XCTSkip("Exact reviewed upstream Git objects unavailable") }
            return data
        }
        let old = "19fe946b9a257cb41ebb5cef5c592ba7923d1f3b", current = "3073d6a8c34f71da054b000cfdbb62594a07c969"
        for revision in [old, current, "8f10429b56be28a25032b87463fffc95e556b5bc"] {
            let library = root.appendingPathComponent(revision + "/Library/Homebrew")
            for path in HomebrewPrivilegeReview.reviewedSourceDigests.keys {
                let file = library.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try source(revision, path).write(to: file)
            }
            let executable = root.appendingPathComponent(revision + "/bin/brew")
            try HomebrewPrivilegeReview.checkCompatibility(executable: executable)
            let changedPath = "cask/artifact/zap.rb", target = library.appendingPathComponent(changedPath)
            let original = try Data(contentsOf: target)
            try source(revision == old ? current : old, changedPath).write(to: target)
            XCTAssertThrowsError(try HomebrewPrivilegeReview.checkCompatibility(executable: executable), "Mixed source cohort")
            try (original + Data("\n# unknown source\n".utf8)).write(to: target)
            XCTAssertThrowsError(try HomebrewPrivilegeReview.checkCompatibility(executable: executable), "Unknown source")
            try original.write(to: target)
            try HomebrewPrivilegeReview.checkCompatibility(executable: executable)
        }
    }

}
