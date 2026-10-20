import XCTest
@testable import SpinnetCore

final class HomebrewSystemAuthenticationTests: XCTestCase {
    func testNativeEnvironmentDoesNotOverrideSystemAuthenticationOrAcceptCredentials() {
        let environment = HomebrewSystemAuthentication.taskEnvironment
        XCTAssertNil(environment["SUDO_ASKPASS"], "Homebrew must not add -A, which disables macOS system authentication UI")
        XCTAssertNil(environment["HOMEBREW_SPINNET_ASKPASS_SOCKET"])
        XCTAssertNil(environment["NONINTERACTIVE"])
        XCTAssertNil(environment["HOMEBREW_NO_SUDO"])
        XCTAssertNil(environment["SSH_AUTH_SOCK"])
        XCTAssertNil(environment["PASSWORD"])
        XCTAssertEqual(environment["HOMEBREW_NO_AUTO_UPDATE"], "1")
        XCTAssertEqual(environment["HOMEBREW_NO_INSTALL_CLEANUP"], "1")
        XCTAssertEqual(environment["HOMEBREW_NO_INSTALL_UPGRADE"], "1")
        XCTAssertEqual(HomebrewReadProfile.environment["HOMEBREW_NO_SUDO"], "1", "Read-only calls must retain their independent no-sudo policy")
    }

    func testNativeHomebrewBuildsSudoCommandWithoutAskpassOrExecutingIt() throws {
        let executable: URL
        do { executable = try HomebrewReadProfile.discover() }
        catch { throw XCTSkip("Requires installed Homebrew for the read-only command-construction probe") }
        let ended = expectation(description: "native command preview reaped")
        let lock = NSLock()
        var output = Data()
        let code = "require 'system_command'; require 'json'; puts JSON.generate(SystemCommand.new('/usr/bin/true', sudo: true).command)"
        let process = HomebrewTaskProcess(executable: executable, arguments: ["ruby", "-e", code],
            environment: HomebrewSystemAuthentication.taskEnvironment, outputPolicy: .terminal)
        try process.start(output: { data in lock.lock(); output.append(data); lock.unlock() }, finished: { result in
            XCTAssertEqual(result.outcome, "completed"); ended.fulfill()
        })
        wait(for: [ended], timeout: 15)
        lock.lock(); defer { lock.unlock() }
        let data = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8)!
        let arguments = try JSONDecoder().decode([String].self, from: data)
        XCTAssertEqual(arguments.first, "/usr/bin/sudo")
        XCTAssertTrue(arguments.contains("/usr/bin/true"))
        XCTAssertFalse(arguments.contains("-A"))
        XCTAssertFalse(arguments.contains("--askpass"))
    }

    func testAdoptionIsStillATypedNativeInstallOption() throws {
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("install"), "kind": .string("cask"), "name": .string("example")]))
        XCTAssertEqual(input.nativeArguments(adopt: true), ["install", "--cask", "--adopt", "--", "example"])
        XCTAssertEqual(input.nativeArguments(adopt: false), input.arguments)
    }

    func testPackagedRunnerRefusesUnsignedHostAndDoesNotShipAPasswordCollector() throws {
        guard let runner = ProcessInfo.processInfo.environment["SPINNET_NATIVE_AUTH_RUNNER"] else {
            throw XCTSkip("Set SPINNET_NATIVE_AUTH_RUNNER to a stably signed packaged runner")
        }
        let helper = URL(fileURLWithPath: runner).deletingLastPathComponent().appendingPathComponent("SpinnetHomebrewAskpass")
        XCTAssertFalse(FileManager.default.fileExists(atPath: helper.path))
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: runner)
        process.arguments = ["--verify-host-environment"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = output
        try process.run(); process.waitUntilExit()
        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertTrue(output.fileHandleForReading.readDataToEndOfFile().isEmpty)
    }
}
