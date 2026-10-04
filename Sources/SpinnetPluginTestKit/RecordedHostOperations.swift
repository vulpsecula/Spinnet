import Foundation
import SpinnetCore

/// Performs the Requested Host Operation a script's answer carries the way
/// the Host performs it once the answer commits (Candidate Contract
/// `host_operations`), with recorded outcomes in place of the desktop, and
/// gives the `operation_finished` event to run next when the request asked
/// to be told.
///
/// It holds the request to the Host's rules: the answer is read as the Host
/// reads it, the Command must declare the operation's Capability, and an
/// insertion goes ahead only after a gesture made while the Host showed
/// where text would go; otherwise it is refused with `target_not_shown`, as
/// every insertion from an Action without a view is. Every other request
/// reaches the outcome recorded for its ID, by default success.
public final class RecordedHostOperations {
    /// One request the Host performed.
    public struct Performed: Equatable {
        /// The catalogue ID.
        public let perform: String
        /// The input as the script gave it.
        public let input: JSONValue
        /// The Plugin's own label for the request.
        public let id: String?
        public let outcome: HostOperationOutcome
        /// The `operation_finished` event the Host delivers when the request
        /// asked to `notify`, while the requesting Command still handles the
        /// view: run it next with the state the answer kept.
        public let delivery: PluginViewEvent?
    }

    /// The outcome of each catalogue ID, when not success.
    public var outcomes: [String: HostOperationOutcome]
    /// Declared Capabilities the user refused.
    public var deniedCapabilities: Set<PluginCapability>
    /// Every request performed, in order.
    public private(set) var performed: [Performed] = []
    private let contracts: PluginInterfaceContracts

    public init(_ outcomes: [String: HostOperationOutcome] = [:], deniedCapabilities: Set<PluginCapability> = [],
                contracts: PluginInterfaceContracts = .host) {
        self.outcomes = outcomes
        self.deniedCapabilities = deniedCapabilities
        self.contracts = contracts
    }

    /// Commits and performs what `run`'s answer requested, `run` being
    /// `invocation` of `plugin`. Returns nil when the answer requested
    /// nothing. Throws as the Host refuses the whole answer: the run's own
    /// failure, the protocol violation that would end the View Session, or
    /// `PluginHostServiceError.capabilityDenied` for a Capability the
    /// Command does not hold.
    @discardableResult
    public func perform(_ run: PluginTestRun, of plugin: PluginUnderTest,
                        for invocation: PluginTestInvocation) throws -> Performed? {
        guard let operation = try run.answer().operation else { return nil }
        let manifest = plugin.manifest
        for capability in operation.definition?.capabilities ?? []
        where !manifest.declares(capability, for: invocation.commandID) || deniedCapabilities.contains(capability) {
            throw PluginHostServiceError.capabilityDenied(capability)
        }
        let shown = invocation.delivery(permits: contracts.permitting(manifest)).insertionTarget
        let outcome: HostOperationOutcome
        if operation.perform == "selection.replace", !shown.isShown {
            outcome = .refused(.targetNotShown)
        } else {
            outcome = outcomes[operation.perform] ?? .succeeded
        }
        let result = Performed(
            perform: operation.perform, input: operation.input, id: operation.id, outcome: outcome,
            delivery: operation.notify ? .operationFinished(id: operation.id, perform: operation.perform, outcome: outcome) : nil
        )
        performed.append(result)
        return result
    }
}
