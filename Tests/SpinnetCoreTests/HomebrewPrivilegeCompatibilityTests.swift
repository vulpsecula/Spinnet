import Foundation
import XCTest
import SpinnetCore

final class HomebrewPrivilegeCompatibilityTests: XCTestCase {
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
    func testCompleteReviewedCohortsPassWhileHybridAndUnknownSourcesFail() throws {
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
        let cleanup = "8f10429b56be28a25032b87463fffc95e556b5bc"
        let checksum = "d78c1943dc2b77930691102481df0d9e9bf7e257"
        for revision in [old, current, cleanup, checksum] {
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
            if revision == checksum {
                for path in ["cask/installer.rb", "cmd/install.rb", "cmd/upgrade.rb", "cmd/reinstall.rb"] {
                    let file = library.appendingPathComponent(path), reviewed = try Data(contentsOf: file)
                    try source(cleanup, path).write(to: file)
                    XCTAssertThrowsError(try HomebrewPrivilegeReview.checkCompatibility(executable: executable), "Mixed checksum policy: \(path)")
                    try reviewed.write(to: file)
                }
                try HomebrewPrivilegeReview.checkCompatibility(executable: executable)
            }
        }
    }

}
