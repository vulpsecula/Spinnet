import Foundation
import SpinnetCore

/// The real JavaScriptCore helper, `SpinnetPluginHelper`, started the way the
/// Host starts it: one reusable process per Plugin, the same protocol, the
/// same budgets. Call `shutdown()` when the test is done.
public final class PluginTestHelper {
    private let supervisor: PluginRuntimeSupervisor
    /// What the Host under test offers, which every run and every
    /// `PluginTestPage` over this helper is held to.
    public let contracts: PluginInterfaceContracts

    /// The current Host release baseline and English, independent of the
    /// machine running the test.
    public static let defaultEnvironment = PluginRuntimeEnvironment(hostVersion: HostVersion.currentString, preferredLanguage: "en")

    /// Uses the real helper under the same current interface and Host-version
    /// compatibility checks as the Host. A custom contract set can model a
    /// Host that refuses a member without changing Plugin declarations.
    public init(helperURL: URL? = nil, environment: PluginRuntimeEnvironment? = nil,
                contracts: PluginInterfaceContracts = .host) throws {
        guard let url = helperURL ?? Self.locate() else { throw PluginTestKitError.helperNotFound }
        let environment = environment ?? PluginRuntimeEnvironment(
            hostVersion: contracts.hostVersion.description,
            preferredLanguage: Self.defaultEnvironment.preferredLanguage
        )
        supervisor = PluginRuntimeSupervisor(helperURL: url, environment: { environment }, contracts: contracts)
        self.contracts = contracts
    }

    /// Runs `invocation` in the helper. Each Host Service request the script
    /// makes is answered by `hostServices` and recorded in the returned run,
    /// whether it was answered or refused.
    ///
    /// A Command naming a catalogue ID in `host_command` runs without a
    /// script. Native command adapters require a `CatalogueCommandExecutor`
    /// such as `RecordedHostServices`; the result is its value or ActionFailure.
    public func run(_ invocation: PluginTestInvocation, of plugin: PluginUnderTest,
                    answering hostServices: PluginHostServiceBroker) -> PluginTestRun {
        let recorder = RecordingHostServiceBroker(answering: hostServices)
        let permits = contracts.permitting(plugin.manifest)
        let result: Result<JSONValue, Error>
        if let action = try? plugin.action(for: invocation), action.execution == .host,
           action.hostServiceID != nil || contracts.permits(HostServiceCatalogue.catalogueIDsOnly, declaredBy: plugin.manifest) {
            result = runCommand(action, of: plugin, recorder: recorder,
                                answering: hostServices as? CatalogueCommandExecutor)
        } else {
            result = Result {
                try execute(plugin.action(for: invocation), in: plugin.package, using: recorder,
                            control: ActionExecutionControl(), delivering: invocation.delivery(permits: permits))
            }
        }
        var run = PluginTestRun(result: result, requests: recorder.requests, performed: recorder.performed)
        run.reading = (invocation.event, permits)
        return run
    }

    /// A scriptless Command through the Host's own Action runner, held to
    /// the same contracts as a script.
    private func runCommand(_ action: ActionConfiguration, of plugin: PluginUnderTest,
                            recorder: RecordingHostServiceBroker,
                            answering commands: CatalogueCommandExecutor?) -> Result<JSONValue, Error> {
        let registry = PluginRegistry(contracts: contracts)
        do {
            try registry.register(plugin.package)
        } catch {
            return .failure(PluginRuntimeError.invalidAction(error.localizedDescription))
        }
        let executor = RecordingCatalogueCommands(answering: commands, recorder: recorder)
        switch HostActionRunner(executor: executor, hostServiceBroker: recorder).invoke(action, using: registry).terminal {
        case .succeeded(let value): return .success(value)
        case .failed(let failure): return .failure(failure)
        }
    }

    /// Retires the Plugin's helper, as the Host does when it has been idle,
    /// so a test can check that the next run starts a fresh one.
    public func retireHelper(of plugin: PluginUnderTest) { supervisor.terminate(pluginID: plugin.manifest.id) }

    /// How many helper processes this kit has started.
    public var launchCount: Int { supervisor.launchCount }

    public func shutdown() { supervisor.shutdown() }

    /// The helper built next to the running tests: `SPINNET_PLUGIN_HELPER_URL`
    /// if set, otherwise a `SpinnetPluginHelper` executable in the directory
    /// holding the test bundle or one of its parents, which is where SwiftPM
    /// and Xcode put it when the test target depends on it.
    public static func locate() -> URL? {
        if let value = ProcessInfo.processInfo.environment["SPINNET_PLUGIN_HELPER_URL"] {
            let url = URL(fileURLWithPath: value)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        let starts = [Bundle(for: PluginTestHelper.self).bundleURL, Bundle.main.executableURL].compactMap { $0 }
        for start in starts {
            var directory = start.deletingLastPathComponent()
            for _ in 0..<5 {
                let candidate = directory.appendingPathComponent("SpinnetPluginHelper")
                if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
                directory.deleteLastPathComponent()
            }
        }
        return nil
    }
}

/// A test that still drives a Plugin through the Host's own seams, such as
/// `HostActionRunner`, uses the helper as its scripted executor.
extension PluginTestHelper: ScriptedActionExecutor {
    public func execute(_ action: ActionConfiguration, in package: PluginPackage) throws -> JSONValue {
        try supervisor.execute(action, in: package)
    }

    public func execute(_ action: ActionConfiguration, in package: PluginPackage,
                        using hostServiceBroker: PluginHostServiceBroker?) throws -> JSONValue {
        try supervisor.execute(action, in: package, using: hostServiceBroker)
    }

    public func execute(_ action: ActionConfiguration, in package: PluginPackage,
                        using hostServiceBroker: PluginHostServiceBroker?,
                        control: ActionExecutionControl) throws -> JSONValue {
        try supervisor.execute(action, in: package, using: hostServiceBroker, control: control)
    }

    public func execute(_ action: ActionConfiguration, in package: PluginPackage,
                        using hostServiceBroker: PluginHostServiceBroker?,
                        control: ActionExecutionControl, delivering delivery: ViewEventDelivery) throws -> JSONValue {
        try supervisor.execute(action, in: package, using: hostServiceBroker, control: control, delivering: delivery)
    }
}

/// What one run produced.
public struct PluginTestRun {
    /// The value the script evaluated to, or why the run failed: a
    /// `PluginRuntimeError` as the Host would see it.
    public let result: Result<JSONValue, Error>
    /// Every Host Service request the script made, in order.
    public let requests: [PluginTestRequest]
    /// Every public operation the run performed, in order.
    public let performed: [PluginTestOperation]

    /// The event the run answered and what the Plugin may use, so its answer
    /// is read as the Host reads it.
    var reading: (event: PluginViewEvent?, permits: (PluginInterfaceMember) -> Bool) = (nil, { _ in false })

    public init(result: Result<JSONValue, Error>, requests: [PluginTestRequest], performed: [PluginTestOperation] = []) {
        self.result = result
        self.requests = requests
        self.performed = performed
    }

    /// The inputs of the requests made to `service`, in order.
    public func inputs(to service: PluginHostService) -> [JSONValue] {
        requests.filter { $0.service == service }.map(\.input)
    }

    /// The inputs of the operations performed under catalogue ID `id`, in
    /// order, each as the Host performs it: a bare string where the
    /// script gave the primary member alone.
    public func inputs(to id: String) -> [JSONValue] {
        performed.filter { $0.id == id }.map(\.input)
    }

    /// The script's answer as the Host reads it: the view and state it
    /// returned, whether it closed its view, its toast, and the operation it
    /// requested under `host_operations`. Throws the run's failure, or the
    /// protocol violation the Host would end the View Session with: a value
    /// that is no answer, a member the Plugin's declarations do not offer,
    /// or an operation in an answer to an event that is no gesture.
    public func answer() throws -> PluginScriptAnswer {
        try PluginScriptAnswer(parsing: result.get(), answering: reading.event, permits: reading.permits)
    }
}

/// One Host Service request as the script made it.
public struct PluginTestRequest: Equatable {
    /// The Host Service that performs it.
    public let service: PluginHostService
    public let input: JSONValue
    /// The public catalogue ID, or nil for a Host-internal request.
    public let operation: String?

    public init(service: PluginHostService, input: JSONValue, operation: String? = nil) {
        self.service = service
        self.input = input
        self.operation = operation
    }
}

/// One operation a run performed by its catalogue ID.
public struct PluginTestOperation: Equatable {
    public let id: String
    public let input: JSONValue

    public init(id: String, input: JSONValue) {
        self.id = id
        self.input = input
    }
}

/// Records each request before passing it on.
private final class RecordingHostServiceBroker: PluginHostServiceBroker {
    private let answering: PluginHostServiceBroker
    private let lock = NSLock()
    private var made: [PluginTestRequest] = []
    private var operations: [PluginTestOperation] = []

    init(answering: PluginHostServiceBroker) { self.answering = answering }

    var requests: [PluginTestRequest] { lock.withLock { made } }
    var performed: [PluginTestOperation] { lock.withLock { operations } }

    func record(_ operation: PluginTestOperation) { lock.withLock { operations.append(operation) } }

    func execute(request: PluginRuntimeHostServiceRequest, for package: PluginPackage,
                 action: ActionConfiguration) throws -> JSONValue {
        lock.withLock {
            made.append(PluginTestRequest(service: request.service, input: request.input, operation: request.operation))
            if let id = request.operation { operations.append(PluginTestOperation(id: id, input: request.input)) }
        }
        return try answering.execute(request: request, for: package, action: action)
    }
}

/// Records what a scriptless Command performs besides a Host Service request
/// before passing it on.
private final class RecordingCatalogueCommands: CatalogueCommandExecutor {
    private let answering: CatalogueCommandExecutor?
    private let recorder: RecordingHostServiceBroker

    init(answering: CatalogueCommandExecutor?, recorder: RecordingHostServiceBroker) {
        self.answering = answering
        self.recorder = recorder
    }

    private func answerer() throws -> CatalogueCommandExecutor {
        guard let answering else {
            throw PluginHostServiceError.unavailable("Answer a Command's operation with RecordedHostServices")
        }
        return answering
    }

    func execute(_ action: ActionConfiguration) throws -> JSONValue {
        throw HostCommandExecutionError.unavailable("The test kit runs only Commands that name a catalogue ID")
    }

    func perform(_ command: HostCommand, input: JSONValue, for action: ActionConfiguration,
                 in package: PluginPackage) throws -> JSONValue {
        recorder.record(PluginTestOperation(id: action.hostServiceID ?? command.rawValue, input: input))
        return try answerer().perform(command, input: input, for: action, in: package)
    }

    func showToast(_ text: String, for action: ActionConfiguration) throws {
        recorder.record(PluginTestOperation(id: action.hostServiceID ?? "host.toast", input: .string(text)))
        try answerer().showToast(text, for: action)
    }

    func showPluginSettings(for action: ActionConfiguration) throws {
        recorder.record(PluginTestOperation(id: action.hostServiceID ?? "host.showPluginSettings", input: .null))
        try answerer().showPluginSettings(for: action)
    }
}
