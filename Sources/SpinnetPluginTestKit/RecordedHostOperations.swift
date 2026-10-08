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
///
/// Given `apps`, `apps.quit` is performed the Host's way on those recorded
/// Apps, the App in front when `perform` is called being the one in front
/// when the Host accepted the request: its target resolved and checked, a
/// protected App refused, a Host Confirmation, for Force Quit or an App
/// that was not in front, recorded and answered with `confirmation`, and
/// authority and identity checked again before the exit. A graceful quit of
/// the App in front asks nothing. `whileConfirming` runs while a
/// confirmation is on screen, so a test can revoke a Capability or quit the
/// App meanwhile.
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
        /// The Host Confirmation shown, in the Host's words; nil when none
        /// was asked.
        public let confirmation: HostConfirmation?
        /// What the Host shows the user for an outcome other than success;
        /// it may name the App and never reaches the Plugin.
        public let message: String?
    }

    /// The outcome of each catalogue ID, when not success.
    public var outcomes: [String: HostOperationOutcome]
    /// Declared Capabilities the user refused.
    public var deniedCapabilities: Set<PluginCapability>
    /// Every request performed, in order.
    public private(set) var performed: [Performed] = []
    /// The recorded Apps `apps.quit` acts on.
    public let apps: RecordedApps?
    /// How the user answers each Host Confirmation; nil leaves it unanswered
    /// until it expires.
    public var confirmation: HostConfirmationAnswer?
    /// Runs while a Host Confirmation is on screen, before it is answered.
    public var whileConfirming: () -> Void = {}
    private let contracts: PluginInterfaceContracts

    public init(_ outcomes: [String: HostOperationOutcome] = [:], deniedCapabilities: Set<PluginCapability> = [],
                apps: RecordedApps? = nil, confirmation: HostConfirmationAnswer? = .confirmed,
                contracts: PluginInterfaceContracts = .host) {
        self.outcomes = outcomes
        self.deniedCapabilities = deniedCapabilities
        self.apps = apps
        self.confirmation = confirmation
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
        var outcome: HostOperationOutcome
        var confirmation: HostConfirmation?
        var message: String?
        if operation.perform == "selection.replace", !shown.isShown {
            outcome = .refused(.targetNotShown)
        } else if operation.perform == CurrentAppAddition.quitID, let apps {
            let quit = self.quit(operation, for: invocation, of: plugin, on: apps)
            outcome = quit.result.outcome
            confirmation = quit.confirmation
            message = quit.result.message
        } else {
            outcome = outcomes[operation.perform] ?? .succeeded
        }
        let result = Performed(
            perform: operation.perform, input: operation.input, id: operation.id, outcome: outcome,
            delivery: operation.notify ? .operationFinished(id: operation.id, perform: operation.perform, outcome: outcome) : nil,
            confirmation: confirmation, message: message
        )
        performed.append(result)
        return result
    }

    /// `apps.quit` as the Host performs it, on the recorded Apps.
    private func quit(_ operation: RequestedHostOperation, for invocation: PluginTestInvocation, of plugin: PluginUnderTest,
                      on apps: RecordedApps) -> (result: HostOperationResult, confirmation: HostConfirmation?) {
        let confirmer = RecordedConfirmations(answer: confirmation, whileShown: whileConfirming)
        let performer = AppExitPerformer(apps: apps, targets: apps.targets, confirmations: confirmer, schedule: { _, _ in })
        var outcome = HostOperationResult(.expired, message: "The Host Confirmation went unanswered")
        guard let request = try? AppQuitRequest(input: operation.input),
              let action = try? plugin.action(for: invocation) else { return (outcome, nil) }
        let capabilities = operation.definition?.capabilities ?? []
        performer.perform(request, accepted: performer.accept(request), for: action, pluginName: plugin.manifest.name,
                          authorize: { [weak self] in
            for capability in capabilities where self?.deniedCapabilities.contains(capability) == true {
                throw PluginHostServiceError.capabilityDenied(capability)
            }
        }, completion: { outcome = $0 })
        return (outcome, confirmer.shown)
    }
}

/// Answers Host Confirmations as a test recorded.
private final class RecordedConfirmations: HostConfirming {
    let answer: HostConfirmationAnswer?
    let whileShown: () -> Void
    private(set) var shown: HostConfirmation?

    init(answer: HostConfirmationAnswer?, whileShown: @escaping () -> Void) {
        self.answer = answer
        self.whileShown = whileShown
    }

    func confirm(_ confirmation: HostConfirmation, for action: ActionConfiguration,
                 answer respond: @escaping (HostConfirmationAnswer) -> Void) -> () -> Void {
        shown = confirmation
        whileShown()
        if let answer { respond(answer) }
        return {}
    }
}
