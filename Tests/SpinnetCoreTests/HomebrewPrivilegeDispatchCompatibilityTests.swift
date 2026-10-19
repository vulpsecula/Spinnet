import Foundation
import XCTest

/// Executes real upstream dispatch/Installer methods with inert artifact leaves
/// and the production bridge prepend. This does not admit a source digest,
/// execute a Homebrew mutation, run a native client, or claim administrator acceptance.
final class HomebrewPrivilegeDispatchCompatibilityTests: XCTestCase {
    private static let previous = "19fe946b9a257cb41ebb5cef5c592ba7923d1f3b"
    private static let current = "3073d6a8c34f71da054b000cfdbb62594a07c969"
    private static let cleanup = "8f10429b56be28a25032b87463fffc95e556b5bc"
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private func run(_ executable: URL, _ arguments: [String], environment: [String: String] = [:]) throws -> (Int32, Data, String) {
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"].merging(environment) { _, value in value }
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let error = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data, String(decoding: error, as: UTF8.self))
    }

    private func commandProof(_ operation: String, mode: String = "record") throws -> (Int32, Data, String) {
        let brew = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        guard FileManager.default.isExecutableFile(atPath: brew.path) else {
            throw XCTSkip("Homebrew is unavailable for the read-only command dispatcher proof")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = directory.appendingPathComponent("context.json")
        try JSONSerialization.data(withJSONObject: ["arguments": [operation, "--cask", "--", "fixture"],
            "casks": [], "client": "/usr/bin/false"]).write(to: context)
        return try run(brew, ["ruby", root.appendingPathComponent("Tests/Fixtures/HomebrewPrivilegeDispatch/command.rb").path,
            root.appendingPathComponent("Sources/SpinnetToolTaskRunner/Resources/HomebrewPrivilegeBridge.rb").path, context.path, mode],
            environment: ["HOME": NSHomeDirectory(), "USER": NSUserName(), "HOMEBREW_NO_AUTO_UPDATE": "1",
                "HOMEBREW_NO_ANALYTICS": "1", "HOMEBREW_NO_ENV_HINTS": "1", "HOMEBREW_DEVELOPER": "1"])
    }

    func testCompleteBridgeResolvesAllReviewedOperationsThroughTheActualCommandRegistry() throws {
        for operation in ["upgrade", "install", "reinstall", "uninstall"] {
            let (status, bytes, error) = try commandProof(operation)
            XCTAssertEqual(status, 0, error)
            guard status == 0 else { continue }
            let output = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            XCTAssertEqual(output["command"] as? String, operation)
            XCTAssertEqual(output["arguments"] as? [String], ["--cask", "--", "fixture"])
            XCTAssertEqual(output["running_command"] as? String, "brew \(operation) --cask -- fixture")
            XCTAssertEqual(output["cask"] as? Bool, true)
            XCTAssertEqual(output["packages"] as? [String], ["fixture"])
            XCTAssertEqual(output["uid"] as? UInt32, getuid(), "The bridge remains the logged-in user")
        }
    }

    func testMissingRegisteredImplementationAndUnreviewedOperationsFailBeforeCommandExecution() throws {
        let missing = try commandProof("upgrade", mode: "missing")
        XCTAssertNotEqual(missing.0, 0)
        XCTAssertTrue(missing.1.isEmpty)
        XCTAssertTrue(missing.2.contains("Unsupported reviewed Homebrew command implementation"), missing.2)
        let unsupported = try commandProof("update")
        XCTAssertNotEqual(unsupported.0, 0)
        XCTAssertTrue(unsupported.1.isEmpty)
        XCTAssertTrue(unsupported.2.contains("Unsupported privileged Homebrew operation"), unsupported.2)
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
        for revision in [Self.previous, Self.current, Self.cleanup] {
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
                        expected += revision != Self.previous
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
        XCTAssertEqual(try proof("zap", at: Self.cleanup) as? [String], current + ["cleanup-temp:false"])
    }

    func testBothDispatchersRouteEveryElevatedLeafToExactGrantAndRefuseWrongMissingOwnerOrPhase() throws {
        for revision in [Self.previous, Self.current, Self.cleanup] {
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
            var expected = revision != Self.previous ? [
                "preflight", earlyUninstall, earlyZap, uninstallService, zapService,
                "uninstall:quit", "zap:quit", "uninstall:signal", "zap:signal", kext, kext,
                uninstallCode, zapCode, receipt, uninstallDelete, "uninstall:trash", "removable", "postflight",
                receipt, zapDelete, "zap:trash", uninstallRmdir, zapRmdir, "purge"
            ] : [
                "preflight", earlyUninstall, uninstallService, "uninstall:quit", "uninstall:signal", kext,
                uninstallCode, receipt, uninstallDelete, "uninstall:trash", uninstallRmdir, "removable", "postflight",
                earlyZap, zapService, "zap:quit", "zap:signal", kext, zapCode, receipt, zapDelete, "zap:trash", zapRmdir, "purge"
            ]
            if revision == Self.cleanup { expected.append("cleanup-temp:false") }
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
