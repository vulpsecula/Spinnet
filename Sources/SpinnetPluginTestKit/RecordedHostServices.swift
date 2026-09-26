import Foundation
import SpinnetCore

/// Answers a script's Host Service requests from what the test recorded, in
/// place of the Host. A service with no recorded answer fails the way an
/// unavailable Host Service does.
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

    public init(_ answers: [PluginHostService: Answer] = [:]) {
        self.answers = answers
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
        switch answers[request.service] {
        case .value(let value):
            return value
        case .failure(let error):
            throw error
        case .answer(let answer):
            return try answer(request.input)
        case nil:
            throw PluginHostServiceError.unavailable("No recorded answer for \(request.service.rawValue)")
        }
    }
}
