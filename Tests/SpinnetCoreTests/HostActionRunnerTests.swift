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

private enum TestError: Error {
    case failed
}
