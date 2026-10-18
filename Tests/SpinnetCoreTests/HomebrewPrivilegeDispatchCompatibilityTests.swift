import Foundation
import XCTest

/// Executes real upstream dispatch/Installer methods with inert artifact leaves
/// and the production bridge prepend. This does not admit a source digest,
/// start Homebrew, run a native client, or claim administrator acceptance.
final class HomebrewPrivilegeDispatchCompatibilityTests: XCTestCase {
    private static let previous = "19fe946b9a257cb41ebb5cef5c592ba7923d1f3b"
    private static let current = "3073d6a8c34f71da054b000cfdbb62594a07c969"
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private func run(_ executable: URL, _ arguments: [String]) throws -> (Int32, Data, String) {
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let error = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data, String(decoding: error, as: UTF8.self))
    }

    private func proof(_ mode: String, at revision: String) throws -> Any {
        let ruby = URL(fileURLWithPath: "/opt/homebrew/Library/Homebrew/vendor/portable-ruby/current/bin/ruby")
        guard FileManager.default.isExecutableFile(atPath: ruby.path) else {
            throw XCTSkip("Homebrew's modern portable Ruby is unavailable for isolated source proof")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for path in ["cask/artifact/abstract_uninstall.rb", "cask/artifact/uninstall.rb", "cask/artifact/zap.rb", "cask/installer.rb"] {
            let (status, bytes, _) = try run(URL(fileURLWithPath: "/usr/bin/git"),
                ["-C", "/opt/homebrew", "show", "\(revision):Library/Homebrew/\(path)"])
            guard status == 0 else { throw XCTSkip("Exact upstream source \(revision) is unavailable") }
            let destination = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: destination)
        }
        let (status, data, error) = try run(ruby, [
            root.appendingPathComponent("Tests/Fixtures/HomebrewPrivilegeDispatch/dispatch.rb").path,
            directory.path,
            root.appendingPathComponent("Sources/SpinnetToolTaskRunner/Resources/HomebrewPrivilegeBridge.rb").path,
            mode
        ])
        XCTAssertEqual(status, 0, error)
        return try JSONSerialization.jsonObject(with: data)
    }

    func testOrdinaryUpgradeAndReinstallHonorSignalOptInQuitAndDeferredDirectoryOrder() throws {
        for revision in [Self.previous, Self.current] {
            let cases = try XCTUnwrap(try proof("ordinary", at: revision) as? [String: [String]])
            XCTAssertEqual(cases.count, 12)
            for operation in ["upgrade", "reinstall"] {
                for variant in ["default", "symbol", "array"] {
                    for quit in [true, false] {
                        var expected = ["preflight", "uninstall:launchctl"]
                        if quit { expected.append("uninstall:quit") }
                        if variant != "default" { expected.append("uninstall:signal") }
                        expected += ["uninstall:pkgutil", "uninstall:delete", "uninstall:trash"]
                        // This is an observed upstream ordering change, not an
                        // assertion that old/new side effects are equivalent.
                        expected += revision == Self.current
                            ? ["removable", "postflight", "uninstall:rmdir"]
                            : ["uninstall:rmdir", "removable", "postflight"]
                        XCTAssertEqual(cases["\(operation):\(variant):\(quit)"], expected, revision)
                    }
                }
            }
        }
    }

    func testZapInterleavesEarlyDirectivesAndDefersItsDataRemovalUntilAfterArtifacts() throws {
        let previous = try XCTUnwrap(try proof("zap", at: Self.previous) as? [String])
        XCTAssertEqual(previous, [
            "preflight", "uninstall:launchctl", "uninstall:quit", "uninstall:signal",
            "uninstall:pkgutil", "uninstall:delete", "uninstall:trash", "uninstall:rmdir",
            "removable", "postflight", "zap:launchctl", "zap:quit", "zap:signal",
            "zap:pkgutil", "zap:delete", "zap:trash", "zap:rmdir", "purge"
        ])
        let current = try XCTUnwrap(try proof("zap", at: Self.current) as? [String])
        XCTAssertEqual(current, [
            "preflight", "uninstall:launchctl", "zap:launchctl", "uninstall:quit", "zap:quit",
            "uninstall:signal", "zap:signal", "uninstall:pkgutil", "uninstall:delete", "uninstall:trash",
            "removable", "postflight", "zap:pkgutil", "zap:delete", "zap:trash",
            "uninstall:rmdir", "zap:rmdir", "purge"
        ])
    }

    func testBothDispatchersRouteEveryElevatedLeafToExactGrantAndRefuseWrongMissingOwnerOrPhase() throws {
        for revision in [Self.previous, Self.current] {
            let result = try XCTUnwrap(try proof("bridge", at: revision) as? [String: Any])
            let accepted = try XCTUnwrap(result["accepted"] as? [Any]).map { value -> String in
                if let command = value as? [String] { return command.joined(separator: " ") }
                return try XCTUnwrap(value as? String)
            }
            let earlyUninstall = "--removal-code fixture 1 code-seal"
            let earlyZap = "--removal-code fixture 3 code-seal"
            let uninstallService = "--remove-launch-services fixture uninstall uninstall-service-seal"
            let zapService = "--remove-launch-services fixture zap zap-service-seal"
            let kext = "--remove-kernel-extensions fixture kext-seal"
            let receipt = "--remove-receipt fixture org.fixture.exact receipt-seal"
            let uninstallCode = "--removal-code fixture 0 code-seal"
            let zapCode = "--removal-code fixture 2 code-seal"
            let uninstallDelete = "--remove-paths fixture 0 uninstallDelete-path-seal"
            let uninstallRmdir = "--remove-paths fixture 1 uninstallRmdir-path-seal"
            let zapDelete = "--remove-paths fixture 2 zapDelete-path-seal"
            let zapRmdir = "--remove-paths fixture 3 zapRmdir-path-seal"
            let expected = revision == Self.current ? [
                "preflight", earlyUninstall, earlyZap, uninstallService, zapService,
                "uninstall:quit", "zap:quit", "uninstall:signal", "zap:signal", kext, kext,
                uninstallCode, zapCode, receipt, uninstallDelete, "uninstall:trash", "removable", "postflight",
                receipt, zapDelete, "zap:trash", uninstallRmdir, zapRmdir, "purge"
            ] : [
                "preflight", earlyUninstall, uninstallService, "uninstall:quit", "uninstall:signal", kext,
                uninstallCode, receipt, uninstallDelete, "uninstall:trash", uninstallRmdir, "removable", "postflight",
                earlyZap, zapService, "zap:quit", "zap:signal", kext, zapCode, receipt, zapDelete, "zap:trash", zapRmdir, "purge"
            ]
            XCTAssertEqual(accepted, expected, revision)
            // Receipt and kext grants intentionally have no phase field in the
            // existing bridge; both passes must still use the same exact seal.
            var expectedDenials = Set<String>()
            for phase in ["uninstall", "zap"] {
                for directive in ["launchctl", "pkgutil", "delete", "rmdir", "kext", "script", "early_script"] {
                    for failure in ["wrong", "missing", "owner"] {
                        expectedDenials.insert("\(phase):\(directive):\(failure)")
                    }
                }
                for directive in ["launchctl", "delete", "rmdir", "script", "early_script"] {
                    expectedDenials.insert("\(phase):\(directive):phase")
                }
            }
            let denied = try XCTUnwrap(result["denied"] as? [String])
            XCTAssertEqual(denied.count, 52)
            XCTAssertEqual(Set(denied), expectedDenials, revision)
        }
    }
}
