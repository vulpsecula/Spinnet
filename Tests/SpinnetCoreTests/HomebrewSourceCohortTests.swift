import Foundation
import XCTest
import SpinnetCore

/// Native read boundary: reviewed source snapshots may start the fixed,
/// read-only bootstrap command; an unreviewed combination must not start it.
final class HomebrewSourceCohortTests: XCTestCase {
    private static let previous = "19fe946b9a257cb41ebb5cef5c592ba7923d1f3b"
    private static let current = "3073d6a8c34f71da054b000cfdbb62594a07c969"
    private static let repository = "/opt/homebrew"

    private func bytes(_ path: String, at revision: String) throws -> Data {
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", Self.repository, "show", "\(revision):\(path)"]
        process.standardOutput = output; process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XCTSkip("Exact upstream Homebrew source snapshot \(revision) is unavailable")
        }
        return data
    }

    private func stage(_ revision: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SpinnetCore/Resources/HomebrewReadSources.json")
        let document = try JSONSerialization.jsonObject(with: Data(contentsOf: source))
        let paths: [String]
        if let original = document as? [String: String] { paths = original.keys.sorted() }
        else {
            let cohorts = try XCTUnwrap(document as? [[String: String]])
            paths = try XCTUnwrap(cohorts.first).keys.sorted()
        }
        for path in paths {
            let target = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes(path, at: revision).write(to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
        }
        return root.appendingPathComponent("bin/brew")
    }

    private func readCaskroom(_ executable: URL) throws -> String {
        let result = try HomebrewReadProfile.execute(executable, ["--caskroom"], HomebrewReadProfile.environment, Date().addingTimeInterval(15))
        XCTAssertEqual(result.status, 0, String(decoding: result.stderr, as: UTF8.self))
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testCurrentReviewedSourceSnapshotStartsTheReadOnlyBootstrap() throws {
        let executable = try stage(Self.current)
        let result = URL(fileURLWithPath: try readCaskroom(executable))
        XCTAssertEqual(result.lastPathComponent, "Caskroom")
        XCTAssertEqual(result.deletingLastPathComponent().lastPathComponent,
            executable.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent)
    }
    func testEarlierReviewedSourceSnapshotStillStartsTheReadOnlyBootstrap() throws {
        let executable = try stage(Self.previous)
        let result = URL(fileURLWithPath: try readCaskroom(executable))
        XCTAssertEqual(result.lastPathComponent, "Caskroom")
        XCTAssertEqual(result.deletingLastPathComponent().lastPathComponent,
            executable.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent)
    }

    func testMixingAnyChangedFileAcrossReviewedSnapshotsIsRefused() throws {
        for (revision, other) in [(Self.previous, Self.current), (Self.current, Self.previous)] {
            let executable = try stage(revision)
            let root = executable.deletingLastPathComponent().deletingLastPathComponent()
            for path in ["Library/Homebrew/brew.sh", "Library/Homebrew/global.rb",
                         "Library/Homebrew/formulary.rb", "Library/Homebrew/cleanup.rb"] {
                let original = try bytes(path, at: revision), replacement = try bytes(path, at: other)
                XCTAssertNotEqual(original, replacement, "The mixed fixture must actually differ")
                let target = root.appendingPathComponent(path)
                try replacement.write(to: target)
                XCTAssertThrowsError(try readCaskroom(executable), path) {
                    XCTAssertTrue($0.localizedDescription.contains("source revision needs review"))
                }
                try original.write(to: target)
            }
            XCTAssertFalse(try readCaskroom(executable).isEmpty)
        }
    }

    func testUnknownSourceBytesAreRefusedEvenWithAReviewedCohortOtherwiseIntact() throws {
        let executable = try stage(Self.current)
        let target = executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Library/Homebrew/formulary.rb")
        try (Data(contentsOf: target) + Data("\n# unreviewed source change\n".utf8)).write(to: target)
        XCTAssertThrowsError(try readCaskroom(executable)) {
            XCTAssertTrue($0.localizedDescription.contains("source revision needs review"))
        }
    }

}
