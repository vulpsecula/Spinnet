import XCTest
@testable import SpinnetCore

final class HomebrewSystemAuthenticationTests: XCTestCase {
    func testCaskChangesPreferSystemAuthenticationWhileCatalogAndFormulaTasksDoNot() throws {
        for operation in ["install", "upgrade", "uninstall", "changeLanguage"] {
            var fields: [String: JSONValue] = ["tool": .string("homebrew"), "operation": .string(operation), "kind": .string("cask"), "name": .string("example")]
            if operation == "changeLanguage" { fields["language"] = .string("en") }
            XCTAssertTrue(HomebrewSystemAuthentication.applies(to: try .init(.object(fields))))
        }
        for input: JSONValue in [
            .object(["tool": .string("homebrew"), "operation": .string("refreshCatalog")]),
            .object(["tool": .string("homebrew"), "operation": .string("cleanup")]),
            .object(["tool": .string("homebrew"), "operation": .string("install"), "kind": .string("formula"), "name": .string("example")]),
            .object(["tool": .string("homebrew"), "operation": .string("serviceStart"), "name": .string("example")])
        ] { XCTAssertFalse(HomebrewSystemAuthentication.applies(to: try .init(input))) }
        let batch = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("upgradeSelected"), "kind": .string("cask"), "names": .array([.string("example")])]))
        XCTAssertTrue(HomebrewSystemAuthentication.applies(to: batch))
    }

    func testSystemAuthenticationDoesNotEnableAskpassOrObtainCredentials() {
        let normal = HomebrewAskpass.taskEnvironment(askpass: URL(fileURLWithPath: "/signed/helper"), socket: "/private/tmp/context")
        let system = HomebrewSystemAuthentication.environment(normal)
        XCTAssertNil(system["SUDO_ASKPASS"])
        XCTAssertNil(system[HomebrewAskpass.socketEnvironment])
        XCTAssertNil(system["NONINTERACTIVE"])
        XCTAssertNil(system["HOMEBREW_NO_SUDO"])
        XCTAssertEqual(normal["SUDO_ASKPASS"], "/signed/helper", "The actual brew command must retain password fallback")
    }

    /// The runner descends from launchd and owns no controlling terminal, so
    /// sudo can never read a password from /dev/tty. When Touch ID cannot
    /// answer (lid closed, cancelled), real Homebrew sudo must reach askpass.
    func testHomebrewSudoWithoutAControllingTerminalFallsBackToAskpass() throws {
        guard !HomebrewSystemAuthentication.isAvailable else {
            throw XCTSkip("Touch ID would answer sudo before the askpass fallback")
        }
        let brew = try HomebrewReadProfile.discover()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("asked"), askpass = root.appendingPathComponent("askpass")
        // Cancels like a dismissed password window; no credential exists.
        try "#!/bin/sh\n: > '\(marker.path)'\nexit 1\n".write(to: askpass, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: askpass.path)
        let environment = HomebrewAskpass.taskEnvironment(askpass: askpass, socket: root.appendingPathComponent("unused").path)
        let process = HomebrewTaskProcess(executable: brew,
            arguments: ["ruby", "-e", "exit(SystemCommand.run('/usr/bin/true', sudo: true).success? ? 0 : 1)"],
            environment: environment, outputPolicy: .terminal)
        let lock = NSLock(), ended = expectation(description: "brew ended")
        var output = Data()
        try process.start(output: { lock.lock(); output.append($0); lock.unlock() }, finished: { _ in ended.fulfill() })
        wait(for: [ended], timeout: 60)
        lock.lock(); let text = String(decoding: output, as: UTF8.self); lock.unlock()
        XCTAssertFalse(text.contains("a terminal is required"), text)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "sudo never asked the askpass fallback: \(text)")
    }

    func testPAMDetectionUsesActiveAuthIncludesAndIgnoresCommentsOtherServicesAndCycles() {
        let configuration = ["sudo": "auth include sudo_local\n", "sudo_local": "#auth sufficient pam_tid.so\nauth sufficient pam_smartcard.so"]
        XCTAssertFalse(HomebrewSystemAuthentication.pamEnablesTouchID { configuration[$0] ?? "" })
        XCTAssertTrue(HomebrewSystemAuthentication.pamEnablesTouchID { $0 == "sudo" ? "auth include sudo_local" : "auth sufficient pam_tid.so # enabled" })
        XCTAssertFalse(HomebrewSystemAuthentication.pamEnablesTouchID { _ in "auth include sudo\naccount required pam_tid.so" })
        XCTAssertFalse(HomebrewSystemAuthentication.pamEnablesTouchID { _ in "auth include ../../tmp/overridden" })
        XCTAssertFalse(HomebrewSystemAuthentication.pamEnablesTouchID { _ in "auth include missing" })
    }

    func testAdoptionIsStillATypedNativeInstallOption() throws {
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("install"), "kind": .string("cask"), "name": .string("example")]))
        XCTAssertEqual(input.nativeArguments(adopt: true), ["install", "--cask", "--adopt", "--", "example"])
        XCTAssertEqual(input.nativeArguments(adopt: false), input.arguments)
    }

    func testNativeWorkerRefusesAnUnsignedParentBeforeAuthenticationOrExecution() throws {
        guard let runner = ProcessInfo.processInfo.environment["SPINNET_SUDO_ASKPASS_RUNNER"] else {
            throw XCTSkip("Requires a stably signed packaged runner")
        }
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: runner)
        process.arguments = ["--native-command", "/opt/homebrew/bin/brew", "{}", "normal", "/private/tmp"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = output
        try process.run(); process.waitUntilExit()
        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertTrue(output.fileHandleForReading.readDataToEndOfFile().isEmpty)
    }
}
