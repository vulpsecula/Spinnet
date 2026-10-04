import Foundation
import SpinnetCore

/// Answers a script's Host Service requests from what the test recorded, in
/// place of the Host. A service with no recorded answer fails the way an
/// unavailable Host Service does, except that Plugin Storage is answered by
/// `storage` when the test supplies one.
public final class RecordedHostServices: PluginHostServiceBroker {
    /// How one service answers each time it is asked.
    public enum Answer {
        /// The service returns this value.
        case value(JSONValue)
        /// The service fails with this error, which reaches the script as the
        /// Host's own failure would.
        case failure(PluginHostServiceError)
        /// The service returns what this closure makes of the request's input,
        /// or fails with what it throws.
        case answer((JSONValue) throws -> JSONValue)

        /// The service returns `value` encoded as the Host encodes its
        /// answers, so a Host type such as `FocusedWindow` can be recorded
        /// as itself.
        public static func encoding<Value: Encodable>(_ value: Value) throws -> Answer {
            .value(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)))
        }
    }

    private let answers: [PluginHostService: Answer]
    private let operations: [String: Answer]
    private let storage: PluginStorage?

    /// `storage`, when given, answers the Plugin Storage services the Host's
    /// own way, for the Plugin under test, unless a recorded answer is given
    /// for one. Give it a temporary directory, and a store over the same
    /// directory in a later run to stand for a relaunch.
    ///
    /// `operations` answers a Plugin declaring Candidate Contract
    /// `namespaces` by catalogue ID, such as `"clipboard.write"`, ahead of
    /// `answers` for the Host Service performing it.
    public init(_ answers: [PluginHostService: Answer] = [:], operations: [String: Answer] = [:],
                storage: PluginStorage? = nil) {
        self.answers = answers
        self.operations = operations
        self.storage = storage
    }

    public func execute(request: PluginRuntimeHostServiceRequest, for package: PluginPackage,
                        action: ActionConfiguration) throws -> JSONValue {
        // Every Capability the Command declares counts as granted; one it
        // does not declare is refused before any answer is looked up. A
        // service that needs no Capability, such as `detect_language`, is
        // never refused.
        if let capability = request.service.requiredCapability,
           !package.manifest.declares(capability, for: action.commandID) {
            throw PluginHostServiceError.capabilityDenied(capability)
        }
        switch request.operation.flatMap({ operations[$0] }) ?? answers[request.service] {
        case .value(let value):
            return value
        case .failure(let error):
            throw error
        case .answer(let answer):
            return try answer(request.input)
        case nil:
            if let storage, request.service.isPluginStorage {
                return try storage.answer(request.service, input: request.input, for: package.manifest.id)
            }
            throw PluginHostServiceError.unavailable("No recorded answer for \(request.operation ?? request.service.rawValue)")
        }
    }
}

/// A scriptless Command naming a catalogue ID is answered by that ID from
/// `operations`, as a call is, whether the Host would perform it as a Host
/// Command or show its own UI.
extension RecordedHostServices: CatalogueCommandExecutor {
    public func execute(_ action: ActionConfiguration) throws -> JSONValue {
        throw HostCommandExecutionError.unavailable("The test kit runs only Commands that name a catalogue ID")
    }

    public func perform(_ command: HostCommand, input: JSONValue, for action: ActionConfiguration,
                        in package: PluginPackage) throws -> JSONValue {
        try answer(action.hostServiceID ?? command.rawValue, input: input)
    }

    public func showToast(_ text: String, for action: ActionConfiguration) throws {
        _ = try answer(action.hostServiceID ?? "host.toast", input: .string(text))
    }

    public func showPluginSettings(for action: ActionConfiguration) throws {
        _ = try answer(action.hostServiceID ?? "host.showPluginSettings", input: .null)
    }

    private func answer(_ id: String, input: JSONValue) throws -> JSONValue {
        switch operations[id] {
        case .value(let value): return value
        case .failure(let error): throw error
        case .answer(let answer): return try answer(input)
        case nil: throw PluginHostServiceError.unavailable("No recorded answer for \(id)")
        }
    }
}
