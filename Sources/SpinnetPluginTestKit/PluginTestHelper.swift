import Foundation
import SpinnetCore

/// The real JavaScriptCore helper, `SpinnetPluginHelper`, started the way the
/// Host starts it: one reusable process per Plugin, the same protocol, the
/// same budgets. Call `shutdown()` when the test is done.
public final class PluginTestHelper {
    private let supervisor: PluginRuntimeSupervisor

    /// What `spinnet.environment` reports unless a test says otherwise: the
    /// highest Plugin API Level this kit's Host supports, an unbundled
    /// Host's version, and English, whatever the machine running the tests
    /// prefers.
    public static let defaultEnvironment = PluginRuntimeEnvironment(hostVersion: "0.0.0", preferredLanguage: "en")

    /// Uses the helper at `helperURL`, or else the one `locate()` finds. Every
    /// script it runs sees `environment` as the Host's.
    public init(helperURL: URL? = nil, environment: PluginRuntimeEnvironment = PluginTestHelper.defaultEnvironment) throws {
        guard let url = helperURL ?? Self.locate() else { throw PluginTestKitError.helperNotFound }
        supervisor = PluginRuntimeSupervisor(helperURL: url, environment: { environment })
    }

    /// Runs `invocation` in the helper. Each Host Service request the script
    /// makes is answered by `hostServices` and recorded in the returned run,
    /// whether it was answered or refused.
    public func run(_ invocation: PluginTestInvocation, of plugin: PluginUnderTest,
                    answering hostServices: PluginHostServiceBroker) -> PluginTestRun {
        let recorder = RecordingHostServiceBroker(answering: hostServices)
        let result = Result {
            try execute(plugin.action(for: invocation), in: plugin.package, using: recorder,
                        control: ActionExecutionControl(), delivering: invocation.delivery)
        }
        return PluginTestRun(result: result, requests: recorder.requests)
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

    /// The inputs of the requests made to `service`, in order.
    public func inputs(to service: PluginHostService) -> [JSONValue] {
        requests.filter { $0.service == service }.map(\.input)
    }

    /// The script's answer as the Host reads it: the view and state it
    /// returned, whether it closed its view, and its toast. Throws the run's
    /// failure, or a protocol violation for a value that is no answer.
    public func answer() throws -> PluginScriptAnswer {
        try PluginScriptAnswer(parsing: result.get())
    }
}

/// One Host Service request as the script made it.
public struct PluginTestRequest: Equatable {
    public let service: PluginHostService
    public let input: JSONValue

    public init(service: PluginHostService, input: JSONValue) {
        self.service = service
        self.input = input
    }
}

/// Records each request before passing it on.
private final class RecordingHostServiceBroker: PluginHostServiceBroker {
    private let answering: PluginHostServiceBroker
    private let lock = NSLock()
    private var made: [PluginTestRequest] = []

    init(answering: PluginHostServiceBroker) { self.answering = answering }

    var requests: [PluginTestRequest] { lock.withLock { made } }

    func execute(request: PluginRuntimeHostServiceRequest, for package: PluginPackage,
                 action: ActionConfiguration) throws -> JSONValue {
        lock.withLock { made.append(PluginTestRequest(service: request.service, input: request.input)) }
        return try answering.execute(request: request, for: package, action: action)
    }
}
