import Foundation
import XCTest
@testable import SpinnetCore

final class PluginRuntimeTests: XCTestCase {
    func testFixtureTextCommandRunsInTheJavaScriptCoreHelper() throws {
        let helperURL = try XCTUnwrap(helperURLIfBuilt(), "Build SpinnetPluginHelper before running integration tests")
        let package = try loadFixturePackage()
        let command = try XCTUnwrap(package.manifest.commands.first {
            $0.id == CommandID("fixture.transform_text")
        })
        let action = try ActionConfiguration(
            id: ActionID("fixture-transform-text"),
            pluginID: package.manifest.id,
            command: command,
            input: .string("Spinnet Plugin fixture")
        )

        let supervisor = PluginRuntimeSupervisor(helperURL: helperURL)
        let result = try supervisor.execute(action, in: package)

        XCTAssertEqual(
            result,
            .object([
                "checksum": .string("1559691768"),
                "output_bytes": .number(22)
            ])
        )
        XCTAssertEqual(supervisor.launchCount, 1)
    }

    func testHostActionRunnerReturnsTheFixtureTextResult() throws {
        let helperURL = try XCTUnwrap(helperURLIfBuilt(), "Build SpinnetPluginHelper before running integration tests")
        let package = try loadFixturePackage()
        let command = try XCTUnwrap(package.manifest.commands.first {
            $0.id == CommandID("fixture.transform_text")
        })
        let action = try ActionConfiguration(
            id: ActionID("fixture-transform-text-seam"),
            pluginID: package.manifest.id,
            command: command,
            input: .string("Spinnet Plugin fixture")
        )
        let registry = PluginRegistry()
        try registry.register(package)
        let runner = HostActionRunner(
            executor: NoopHostCommandExecutor(),
            scriptedExecutor: PluginRuntimeSupervisor(helperURL: helperURL)
        )

        let outcome = runner.invoke(action, using: registry)

        XCTAssertEqual(outcome.actionID, action.id)
        XCTAssertEqual(outcome.pluginID, action.pluginID)
        XCTAssertEqual(
            outcome.terminal,
            .succeeded(.object([
                "checksum": .string("1559691768"),
                "output_bytes": .number(22)
            ]))
        )
    }

    func testFixtureStructuredDataCommandRunsInTheJavaScriptCoreHelper() throws {
        let helperURL = try XCTUnwrap(helperURLIfBuilt(), "Build SpinnetPluginHelper before running integration tests")
        let package = try loadFixturePackage()
        let command = try XCTUnwrap(package.manifest.commands.first {
            $0.id == CommandID("fixture.transform_data")
        })
        let input = #"{"items":[{"id":2,"name":"beta","enabled":true},{"id":1,"name":"alpha","enabled":true},{"id":3,"name":"disabled","enabled":false}]}"#
        let action = try ActionConfiguration(
            id: ActionID("fixture-transform-data"),
            pluginID: package.manifest.id,
            command: command,
            input: .string(input)
        )

        let registry = PluginRegistry()
        try registry.register(package)
        let runner = HostActionRunner(
            executor: NoopHostCommandExecutor(),
            scriptedExecutor: PluginRuntimeSupervisor(helperURL: helperURL)
        )
        let outcome = runner.invoke(action, using: registry)
        guard case .succeeded(let result) = outcome.terminal else {
            return XCTFail("The structured-data Action should succeed through the Host seam")
        }
        XCTAssertEqual(
            result,
            .object([
                "checksum": .string("3454327220"),
                "output_bytes": .number(20)
            ])
        )

        let objectAction = try ActionConfiguration(
            id: ActionID("fixture-transform-data-object"),
            pluginID: package.manifest.id,
            command: command,
            input: .object([
                "items": .array([
                    .object([
                        "id": .number(2),
                        "name": .string("beta"),
                        "enabled": .bool(true)
                    ]),
                    .object([
                        "id": .number(1),
                        "name": .string("alpha"),
                        "enabled": .bool(true)
                    ]),
                    .object([
                        "id": .number(3),
                        "name": .string("disabled"),
                        "enabled": .bool(false)
                    ])
                ])
            ])
        )
        let objectOutcome = runner.invoke(objectAction, using: registry)
        guard case .succeeded(let objectResult) = objectOutcome.terminal else {
            return XCTFail("The object-form structured-data Action should succeed")
        }
        XCTAssertEqual(objectResult, result)
    }

    func testFatalHelperFaultIsContainedByTheHostProcess() throws {
        let helperURL = try XCTUnwrap(helperURLIfBuilt(), "Build SpinnetPluginHelper before running integration tests")
        let process = Process()
        process.executableURL = helperURL
        process.arguments = ["--fault-abort"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGABRT)
    }

    func testSupervisorReportsAFatalHelperFaultAtTheActionSeam() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpinnetCrashHelper-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let helperURL = directory.appendingPathComponent("crash-helper")
        try Data("#!/bin/sh\nkill -ABRT $$\n".utf8).write(to: helperURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: helperURL.path
        )

        let package = try loadFixturePackage()
        let command = try XCTUnwrap(package.manifest.commands.first {
            $0.id == CommandID("fixture.transform_text")
        })
        let action = try ActionConfiguration(
            id: ActionID("fixture-transform-text-crash"),
            pluginID: package.manifest.id,
            command: command,
            input: .string("Spinnet Plugin fixture")
        )
        let supervisor = PluginRuntimeSupervisor(helperURL: helperURL)
        let registry = PluginRegistry()
        try registry.register(package)
        let outcome = HostActionRunner(
            executor: NoopHostCommandExecutor(),
            scriptedExecutor: supervisor
        ).invoke(action, using: registry)

        guard case .failed(let failure) = outcome.terminal else {
            return XCTFail("A fatal helper fault should produce a terminal Host failure")
        }
        XCTAssertEqual(failure.category, .helperCrashed)
        XCTAssertEqual(failure.pluginID, action.pluginID)
        XCTAssertEqual(failure.actionID, action.id)
        XCTAssertEqual(supervisor.launchCount, 1)
    }

    private func loadFixturePackage() throws -> PluginPackage {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        return try PluginManifestLoader.load(
            packageAt: root.appendingPathComponent("Plugins/SpinnetFixture.spinnetplugin")
        )
    }

    private func helperURLIfBuilt() -> URL? {
        if let value = ProcessInfo.processInfo.environment["SPINNET_PLUGIN_HELPER_URL"] {
            let url = URL(fileURLWithPath: value)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }

        if let executableURL = Bundle.main.executableURL {
            var directory = executableURL.deletingLastPathComponent()
            for _ in 0..<5 {
                let candidate = directory.appendingPathComponent("SpinnetPluginHelper")
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
                directory.deleteLastPathComponent()
            }
        }

        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let buildRoot = root.appendingPathComponent(".build", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: buildRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isExecutableKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in enumerator {
            guard url.lastPathComponent == "SpinnetPluginHelper",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isExecutableKey]),
                  values.isRegularFile == true,
                  values.isExecutable == true else { continue }
            return url
        }
        return nil
    }
}

private struct NoopHostCommandExecutor: HostCommandExecutor {
    func execute(_ action: ActionConfiguration) throws -> JSONValue { .null }
}
