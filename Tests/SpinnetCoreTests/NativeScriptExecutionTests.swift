import XCTest
import SpinnetCore
@testable import SpinnetReviewedTools
import Foundation

final class NativeScriptExecutionTests: XCTestCase {
    func testGeneratedPublisherTemplateTreatsConfiguredPathsAsDataRatherThanShellSource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try NativeFileQuarantine.makePrivateDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("injected")
        let path = directory.path + "/Apps'; /usr/bin/touch '" + marker.path + "'; '"
        let generated = try HomebrewNativeGeneratedScript.render(template: "#!/bin/sh\nprintf '%s\\n' '/__SPINNET_GENERATED_APPDIR__'\n", home: directory, prefix: URL(fileURLWithPath: "/opt/homebrew"), appDirectory: URL(fileURLWithPath: path), payload: directory)
        let script = directory.appendingPathComponent("generated.sh")
        try Data(generated.content.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        var environment = generated.environment; environment["PATH"] = "/usr/bin:/bin"
        let done = expectation(description: "trusted generated template exits")
        let process = HomebrewTaskProcess(executable: script, arguments: [], environment: environment)
        var output = Data()
        try process.start(output: { output.append($0) }, finished: { result in
            XCTAssertEqual(result.outcome, "completed"); done.fulfill()
        })
        wait(for: [done], timeout: 5)
        XCTAssertEqual(String(data: output, encoding: .utf8), path + "\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testNativeTaskReceivesExactBoundedInputAndEOFWithoutAddingNewlines() throws {
        let expected = Data([121, 101, 115, 10, 110, 101, 120, 116, 0])
        let done = expectation(description: "fixed native tee exits on frozen input EOF")
        let process = HomebrewTaskProcess(executable: URL(fileURLWithPath: "/usr/bin/tee"), arguments: [], environment: ["PATH": "/usr/bin:/bin"], standardInput: expected)
        var output = Data()
        try process.start(output: { output.append($0) }, finished: { result in
            XCTAssertEqual(result.outcome, "completed"); XCTAssertEqual(output, expected); done.fulfill()
        })
        wait(for: [done], timeout: 5)
    }

    func testStopBeforeLaunchNeverStartsTheNativeExecutable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try NativeFileQuarantine.makePrivateDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("must-not-exist")
        let process = HomebrewTaskProcess(executable: URL(fileURLWithPath: "/usr/bin/touch"), arguments: [marker.path], environment: ["PATH": "/usr/bin:/bin"])
        process.stop()
        XCTAssertThrowsError(try process.start(output: { _ in }, finished: { _ in }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testFixedNativeManifestInputPolicyIsSeparateFromVendorInputBound() throws {
        let bytes = Data(repeating: 97, count: 300 * 1024)
        let vendor = HomebrewTaskProcess(executable: URL(fileURLWithPath: "/usr/bin/tee"), arguments: [], environment: [:], standardInput: bytes)
        XCTAssertThrowsError(try vendor.start(output: { _ in }, finished: { _ in }))
        let done = expectation(description: "bounded native manifest receives exact bytes")
        let worker = HomebrewTaskProcess(executable: URL(fileURLWithPath: "/usr/bin/tee"), arguments: [], environment: [:], standardInput: bytes, inputPolicy: .nativeManifest)
        var output = Data()
        try worker.start(output: { output.append($0) }, finished: { result in XCTAssertEqual(result.outcome, "completed"); XCTAssertEqual(output, bytes); done.fulfill() })
        wait(for: [done], timeout: 5)
    }

}
