import XCTest
@testable import SpinnetCore

final class HostActionRunnerTests: XCTestCase {
    func testConfiguredURLActionRunsThroughHostActionSeam() throws {
        let action = try makeURLAction()
        let executor = RecordingHostCommandExecutor(result: .success(
            .object(["opened": .string("https://example.com")])
        ))

        let outcome = HostActionRunner(executor: executor).invoke(action)

        XCTAssertEqual(executor.actions, [action])
        XCTAssertEqual(outcome.actionID, action.id)
        XCTAssertEqual(outcome.pluginID, action.pluginID)
        guard case .succeeded(let result) = outcome.terminal else {
            return XCTFail("The configured Host Action should succeed")
        }
        XCTAssertEqual(result, .object(["opened": .string("https://example.com")]))
    }

    func testHostCommandFailureBecomesStableActionFailure() throws {
        let action = try makeURLAction()
        let executor = RecordingHostCommandExecutor(result: .failure(TestError.failed))

        let outcome = HostActionRunner(executor: executor).invoke(action)

        guard case .failed(let failure) = outcome.terminal else {
            return XCTFail("The failed Host Command should produce a failed outcome")
        }
        XCTAssertEqual(failure.category, .hostCommandFailed)
        XCTAssertEqual(failure.pluginID, action.pluginID)
        XCTAssertEqual(failure.actionID, action.id)
        XCTAssertEqual(failure.userMessage, "com.example.fixture — action-1 failed (host_command_failed)")
    }

    func testUnavailableConfiguredCommandCannotReachExecutor() throws {
        let action = try makeURLAction()
        let registry = PluginRegistry()
        let manifest = try PluginManifest(
            id: action.pluginID,
            name: "Fixture",
            version: "1.0.0",
            commands: [CommandDeclaration(
                id: action.commandID,
                title: "Changed title",
                hostCommand: .openURL
            )]
        )
        try registry.register(PluginPackage(
            rootURL: URL(fileURLWithPath: "/tmp/fixture.spinnetplugin"),
            manifest: manifest
        ))
        let executor = RecordingHostCommandExecutor(result: .success(.null))

        let outcome = HostActionRunner(executor: executor).invoke(action, using: registry)

        XCTAssertTrue(executor.actions.isEmpty)
        guard case .failed(let failure) = outcome.terminal else {
            return XCTFail("An unavailable Command should produce a failed outcome")
        }
        XCTAssertEqual(failure.category, .commandUnavailable)
        XCTAssertEqual(failure.userMessage, "com.example.fixture — action-1 failed (command_unavailable)")
    }

    func testMissingResourceDoesNotReachExecutorWhenResourceCheckingIsEnabled() throws {
        let command = CommandDeclaration(
            id: CommandID("fixture.open_file"),
            title: "Open File",
            hostCommand: .openFile
        )
        let action = try ActionConfiguration(
            id: ActionID("missing-file"),
            pluginID: PluginID("com.example.fixture"),
            command: command,
            input: .object(["path": .string("/tmp/spinnet-missing-runtime-file")])
        )
        let registry = PluginRegistry()
        try registry.register(PluginPackage(
            rootURL: URL(fileURLWithPath: "/tmp/fixture.spinnetplugin"),
            manifest: try PluginManifest(
                id: action.pluginID,
                name: "Fixture",
                version: "1.0.0",
                commands: [command]
            )
        ))
        let executor = RecordingHostCommandExecutor(result: .success(.null))

        let outcome = HostActionRunner(
            executor: executor,
            resourceAvailability: { ActionResourceAvailability.missingReason(for: $0) }
        ).invoke(action, using: registry)

        XCTAssertTrue(executor.actions.isEmpty)
        guard case .failed(let failure) = outcome.terminal else {
            return XCTFail("A missing resource should produce a failed outcome")
        }
        XCTAssertEqual(failure.category, .commandUnavailable)
    }

    func testConfiguredJavaScriptActionRunsThroughScriptedActionSeam() throws {
        let command = CommandDeclaration(
            id: CommandID("fixture.transform_text"),
            title: "Transform Text",
            execution: .javascript,
            script: "transform-text.js"
        )
        let action = try ActionConfiguration(
            id: ActionID("script-action"),
            pluginID: PluginID("com.example.fixture"),
            command: command,
            input: .string("Spinnet fixture")
        )
        let registry = PluginRegistry()
        try registry.register(PluginPackage(
            rootURL: URL(fileURLWithPath: "/tmp/fixture.spinnetplugin"),
            manifest: try PluginManifest(
                id: action.pluginID,
                name: "Fixture",
                version: "1.0.0",
                commands: [command]
            )
        ))
        let executor = RecordingScriptedActionExecutor(result: .success(
            .object(["transformed": .string("SPINNET-FIXTURE")])
        ))

        let outcome = HostActionRunner(
            executor: RecordingHostCommandExecutor(result: .success(.null)),
            scriptedExecutor: executor
        ).invoke(action, using: registry)

        XCTAssertEqual(executor.actions, [action])
        guard case .succeeded(let result) = outcome.terminal else {
            return XCTFail("The configured scripted Action should succeed")
        }
        XCTAssertEqual(result, .object(["transformed": .string("SPINNET-FIXTURE")]))
    }

    func testHelperCrashBecomesStableScriptedFailure() throws {
        let command = CommandDeclaration(
            id: CommandID("fixture.transform_text"),
            title: "Transform Text",
            execution: .javascript,
            script: "transform-text.js"
        )
        let action = try ActionConfiguration(
            id: ActionID("script-action"),
            pluginID: PluginID("com.example.fixture"),
            command: command,
            input: .string("Spinnet fixture")
        )
        let registry = PluginRegistry()
        try registry.register(PluginPackage(
            rootURL: URL(fileURLWithPath: "/tmp/fixture.spinnetplugin"),
            manifest: try PluginManifest(
                id: action.pluginID,
                name: "Fixture",
                version: "1.0.0",
                commands: [command]
            )
        ))
        let executor = RecordingScriptedActionExecutor(result: .failure(
            PluginRuntimeError.helperCrashed(signal: 6)
        ))

        let outcome = HostActionRunner(
            executor: RecordingHostCommandExecutor(result: .success(.null)),
            scriptedExecutor: executor
        ).invoke(action, using: registry)

        guard case .failed(let failure) = outcome.terminal else {
            return XCTFail("A crashed helper should produce a failed outcome")
        }
        XCTAssertEqual(failure.category, .helperCrashed)
        XCTAssertEqual(failure.pluginID, action.pluginID)
        XCTAssertEqual(failure.actionID, action.id)
    }

    private func makeURLAction() throws -> ActionConfiguration {
        try ActionConfiguration(
            id: ActionID("action-1"),
            pluginID: PluginID("com.example.fixture"),
            command: CommandDeclaration(
                id: CommandID("fixture.open_url"),
                title: "Open URL",
                hostCommand: .openURL
            ),
            input: .string("https://example.com")
        )
    }
}

private final class RecordingHostCommandExecutor: HostCommandExecutor {
    private(set) var actions: [ActionConfiguration] = []
    private let result: Result<JSONValue, Error>

    init(result: Result<JSONValue, Error>) {
        self.result = result
    }

    func execute(_ action: ActionConfiguration) throws -> JSONValue {
        actions.append(action)
        return try result.get()
    }
}

private final class RecordingScriptedActionExecutor: ScriptedActionExecutor {
    private(set) var actions: [ActionConfiguration] = []
    private let result: Result<JSONValue, Error>

    init(result: Result<JSONValue, Error>) {
        self.result = result
    }

    func execute(_ action: ActionConfiguration, in package: PluginPackage) throws -> JSONValue {
        actions.append(action)
        return try result.get()
    }
}

private enum TestError: Error {
    case failed
}
