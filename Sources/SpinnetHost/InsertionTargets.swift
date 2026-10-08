import AppKit
import Combine
import SpinnetCore

/// The App insertion would go to now, as the Host shows it in the Plugin
/// Views of Plugins declaring `host_operations` (ADR 0018): the App in
/// front, kept current from activation notifications, or no App while
/// Spinnet or nothing is in front. Its name is Host data, shown to the user
/// and never given to a Plugin.
final class InsertionTargetTracker: ObservableObject {
    struct Environment {
        /// The App in front, if any, whoever it is.
        var frontmost: () -> InsertionTargetApp?
        var ownProcessIdentifier: pid_t
        /// The element focused in the App, where Accessibility exposes one.
        var focusedElement: (pid_t) -> AnyHashable?
        var isRunning: (InsertionTargetApp) -> Bool
        /// Calls back on the main thread whenever another App comes to the
        /// front or one quits, until the returned token is released.
        var observeActivation: (@escaping () -> Void) -> AnyObject
    }

    /// The App the Host shows as the insertion target now.
    @Published private(set) var current: InsertionTargetApp?
    private let environment: Environment
    private var observation: AnyObject?

    init(environment: Environment = .live) {
        self.environment = environment
        current = Self.target(environment.frontmost(), own: environment.ownProcessIdentifier)
        observation = environment.observeActivation { [weak self] in self?.refresh() }
    }

    /// Reads the App in front again, as an activation notification does.
    func refresh() {
        let target = actualTarget()
        if target != current { current = target }
    }

    /// What the user sees at a gesture: the App shown now, with the element
    /// focused in it where Accessibility exposes one.
    func capture() -> InsertionTargetCapture {
        .shown(app: current, focus: current.flatMap { environment.focusedElement($0.processIdentifier) })
    }

    /// The App in front at execution, unless it is Spinnet.
    func actualTarget() -> InsertionTargetApp? {
        Self.target(environment.frontmost(), own: environment.ownProcessIdentifier)
    }

    func focusedElement(of app: InsertionTargetApp) -> AnyHashable? { environment.focusedElement(app.processIdentifier) }

    func isRunning(_ app: InsertionTargetApp) -> Bool { environment.isRunning(app) }

    private static func target(_ frontmost: InsertionTargetApp?, own: pid_t) -> InsertionTargetApp? {
        guard let frontmost, frontmost.processIdentifier != own else { return nil }
        return frontmost
    }
}

extension InsertionTargetTracker.Environment {
    static var live: InsertionTargetTracker.Environment {
        InsertionTargetTracker.Environment(
            frontmost: { NSWorkspace.shared.frontmostApplication.map(InsertionTargetApp.init) },
            ownProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
            focusedElement: { HostTextInserter.focusedElement(of: $0) },
            isRunning: { app in
                guard let running = NSRunningApplication(processIdentifier: app.processIdentifier) else { return false }
                return !running.isTerminated && InsertionTargetApp(running).isSameApp(as: app)
            },
            observeActivation: { changed in
                let center = NSWorkspace.shared.notificationCenter
                let tokens = [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didTerminateApplicationNotification]
                    .map { center.addObserver(forName: $0, object: nil, queue: .main) { _ in changed() } }
                return ObservationTokens(center: center, tokens: tokens)
            }
        )
    }
}

final class ObservationTokens {
    let center: NotificationCenter
    let tokens: [NSObjectProtocol]

    init(center: NotificationCenter, tokens: [NSObjectProtocol]) {
        self.center = center
        self.tokens = tokens
    }

    deinit { tokens.forEach(center.removeObserver) }
}

extension InsertionTargetApp {
    init(_ application: NSRunningApplication) {
        self.init(processIdentifier: application.processIdentifier, bundleIdentifier: application.bundleIdentifier,
                  launchDate: application.launchDate,
                  name: application.localizedName ?? application.bundleIdentifier ?? "the App in front")
    }
}

/// Inserts for a Plugin API Level 2 Plugin: into the App in front
/// at that moment, only if it is the App the Host showed when the user
/// acted and, where Accessibility exposed the element focused in it then,
/// only if that element is still focused. Every insertion path of such a
/// Plugin's View Session comes here: its standard insert action, a
/// requested `selection.replace` and a synchronous one. Messages that name
/// Apps are shown by the Host only; `naming: false` gives the ones a
/// Plugin's helper may carry.
final class TargetedTextInserter {
    private let tracker: InsertionTargetTracker
    private let inserter: HostTextInserter

    init(tracker: InsertionTargetTracker, inserter: HostTextInserter) {
        self.tracker = tracker
        self.inserter = inserter
    }

    /// Call on the main thread; `completion` runs there once, with nil when
    /// every key press was posted.
    func insert(_ text: String, shown: InsertionTargetCapture, naming: Bool,
                completion: @escaping (InsertionFailure?) -> Void) {
        guard case .shown(let shownApp, let focus) = shown else {
            return completion(.notShown)
        }
        // The App shown follows what is in front, so a mismatch also
        // updates it.
        tracker.refresh()
        guard let front = tracker.actualTarget() else {
            return completion(InsertionFailure(.noTarget, message: naming
                ? "Spinnet or no App is in front. Nothing was inserted."
                : "No App is in front, so nothing was inserted"))
        }
        guard let shownApp else {
            return completion(InsertionFailure(.targetChanged, message: naming
                ? "Spinnet showed no App, but \(front.name) is in front. Nothing was inserted."
                : InsertionFailure.changedWithoutNames.message))
        }
        guard shownApp.isSameApp(as: front) else {
            if !tracker.isRunning(shownApp) {
                return completion(InsertionFailure(.noTarget, message: naming
                    ? "\(shownApp.name) has quit. Nothing was inserted."
                    : "The App Spinnet showed has quit, so nothing was inserted"))
            }
            return completion(InsertionFailure(.targetChanged, message: naming
                ? "Spinnet showed \(shownApp.name), but \(front.name) is in front. Nothing was inserted."
                : InsertionFailure.changedWithoutNames.message))
        }
        // Compared only where Accessibility exposed the element when the
        // user acted; elsewhere the App alone is compared (#69).
        if let focus, tracker.focusedElement(of: front) != focus {
            return completion(InsertionFailure(.targetChanged, message: naming
                ? "Focus moved to another field of \(front.name). Nothing was inserted."
                : "Focus moved to another field of the App, so nothing was inserted"))
        }
        inserter.insert(text, into: .application(front.processIdentifier)) { error in
            completion(error.map { Self.failure($0, in: front, naming: naming) })
        }
    }

    /// `insert`, for a synchronous `selection.replace`: blocks the calling
    /// thread, which must not be the main thread, and throws what the
    /// invocation fails with, naming no App.
    func insertAndWait(_ text: String, shown: InsertionTargetCapture, timeout: TimeInterval = 60) throws {
        guard !Thread.isMainThread else {
            throw PluginHostServiceError.failed("Text cannot be inserted from the main thread")
        }
        let finished = DispatchSemaphore(value: 0)
        let box = FailureBox()
        DispatchQueue.main.async {
            self.insert(text, shown: shown, naming: false) { failure in
                box.failure = failure
                finished.signal()
            }
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            throw PluginHostServiceError.insertion(InsertionFailure(.targetUnresponsive, refused: false,
                                                                   message: "Inserting the text took too long"))
        }
        if let failure = box.failure { throw PluginHostServiceError.insertion(failure) }
    }

    private final class FailureBox: @unchecked Sendable {
        var failure: InsertionFailure?
    }

    /// The reason a failed keyboard-event insertion reports.
    static func failure(_ error: PluginHostServiceError, in app: InsertionTargetApp, naming: Bool) -> InsertionFailure {
        let name = naming ? app.name : "The App"
        switch error {
        case .systemPermissionDenied:
            return InsertionFailure(.systemPermissionDenied, message: error.description)
        case HostTextInserter.passwordField:
            return InsertionFailure(.secureInput, message: "The focused field is a password field. Nothing was inserted.")
        case HostTextInserter.didNotComeForward:
            return InsertionFailure(.targetUnresponsive, refused: false,
                                    message: "\(name) did not come to the front. Nothing was inserted.")
        case HostTextInserter.leftTheFront:
            return InsertionFailure(.targetChanged, refused: false,
                                    message: "\(name) left the front while the text was typed. Only part of it was inserted.")
        case HostTextInserter.notOpen, HostTextInserter.noAppInFront, HostTextInserter.intoItself:
            return InsertionFailure(.noTarget, message: "\(name) is not in front. Nothing was inserted.")
        default:
            return InsertionFailure(.hostServiceFailed, refused: false, message: error.description)
        }
    }
}

/// Performs the Requested Host Operations the View Sessions commit, on the
/// main thread, which is the sessions' executor: it checks the requesting
/// Action's authority through the broker at commit and again at execution,
/// inserts through `TargetedTextInserter`, opens the Plugin's settings
/// itself, and hands every other operation to the broker off the main
/// thread, as a call of the same ID.
final class HostOperationsPerformer: HostOperationPerformer {
    private let registry: PluginRegistry
    private let broker: () -> CapabilityCheckedHostServiceBroker?
    private let inserter: TargetedTextInserter
    private let openPluginSettings: (PluginID) -> Void
    /// Quits and force quits for `apps.quit` (#83), after its Host
    /// Confirmation.
    private let exits: AppExitPerformer?
    private let queue = DispatchQueue(label: "com.vulpsecula.Spinnet.host-operations", qos: .userInitiated)

    init(registry: PluginRegistry, broker: @escaping () -> CapabilityCheckedHostServiceBroker?,
         inserter: TargetedTextInserter, exits: AppExitPerformer? = nil,
         openPluginSettings: @escaping (PluginID) -> Void) {
        self.registry = registry
        self.broker = broker
        self.inserter = inserter
        self.exits = exits
        self.openPluginSettings = openPluginSettings
    }

    func authorize(_ operation: RequestedHostOperation, for action: ActionConfiguration) throws {
        guard let package = registry.package(for: action.pluginID) else {
            throw PluginHostServiceError.unavailable("The Plugin is no longer installed")
        }
        if operation.perform == CurrentAppAddition.quitID, let definition = operation.definition {
            guard let broker = broker() else { throw PluginHostServiceError.unavailable("Host Services") }
            return try broker.authorize(definition, for: package, action: action)
        }
        guard let (service, _) = try operation.implementation() else {
            // `host.showPluginSettings` needs nothing but the Plugin's own Command.
            guard package.manifest.commands.contains(where: { $0.matchesExecutableDefinition(action.declaredCommand) }) else {
                throw PluginHostServiceError.failed("The Action is not one of this Plugin's Commands")
            }
            return
        }
        guard let broker = broker() else { throw PluginHostServiceError.unavailable("Host Services") }
        try broker.authorize(service, for: package, action: action)
    }

    /// The Plugin or the requesting Command is missing, disabled or changed;
    /// a Capability or System Permission is read by `authorize` instead.
    private static func commandIsGone(_ availability: ActionAvailability) -> Bool {
        switch availability.reason {
        case .pluginMissing?, .pluginDisabled?, .pluginRefused?, .commandMissing?, .commandChanged?: return true
        default: return false
        }
    }

    /// The Action's authority over `operation` as it stands now: the Plugin
    /// and its Command still available, then what `authorize` checks. A
    /// Capability revoked, a permission removed or a Plugin changed since
    /// the commit refuses it.
    private func checkAuthorityAsItStands(_ operation: RequestedHostOperation, for action: ActionConfiguration) throws {
        guard registry.package(for: action.pluginID) != nil, !Self.commandIsGone(registry.availability(for: action)) else {
            throw PluginHostServiceError.unavailable("The Plugin or its Command is no longer available")
        }
        try authorize(operation, for: action)
    }

    /// `apps.quit` binds the App in front when the Host accepts it, not when
    /// it starts: without a target it acts on that App, and quits it
    /// gracefully without a Host Confirmation.
    func accept(_ operation: RequestedHostOperation, for action: ActionConfiguration) -> AcceptedHostOperationTarget {
        guard operation.perform == CurrentAppAddition.quitID, let exits,
              let request = try? AppQuitRequest(input: operation.input) else { return .none }
        return exits.accept(request)
    }

    func perform(_ operation: RequestedHostOperation, for action: ActionConfiguration, target: InsertionTargetCapture,
                 accepted: AcceptedHostOperationTarget, completion: @escaping (HostOperationResult) -> Void) {
        do {
            try checkAuthorityAsItStands(operation, for: action)
        } catch {
            return completion(.refusal(error))
        }
        if let text = operation.insertedText {
            inserter.insert(text, shown: target, naming: true) { failure in
                completion(failure.map { HostOperationResult($0.outcome, message: $0.message) } ?? HostOperationResult(.succeeded))
            }
            return
        }
        if operation.perform == CurrentAppAddition.quitID {
            guard let exits else {
                return completion(HostOperationResult(.refused(.hostServiceFailed), message: "This Host cannot quit Apps"))
            }
            let request: AppQuitRequest
            do {
                request = try AppQuitRequest(input: operation.input)
            } catch {
                // Checked when the answer committed, so only a Host fault
                // reaches here.
                let reason = (error as? PluginHostServiceError)?.description ?? error.localizedDescription
                return completion(HostOperationResult(.refused(.hostServiceFailed),
                                                      message: "Spinnet could not read what to quit: \(reason)"))
            }
            let name = registry.package(for: action.pluginID)?.manifest.name ?? action.pluginID.rawValue
            exits.perform(request, accepted: accepted, for: action, pluginName: name, authorize: { [weak self] in
                guard let self else { throw PluginHostServiceError.unavailable("Host Services") }
                try self.checkAuthorityAsItStands(operation, for: action)
            }, completion: completion)
            return
        }
        guard let implementation = try? operation.implementation() else {
            openPluginSettings(action.pluginID)
            return completion(HostOperationResult(.succeeded))
        }
        guard let package = registry.package(for: action.pluginID), let broker = broker() else {
            return completion(HostOperationResult(.refused(.commandUnavailable), message: "Host Services are unavailable"))
        }
        let request = PluginRuntimeHostServiceRequest(invocationID: UUID().uuidString, actionID: action.id,
                                                      service: implementation.service, input: implementation.input,
                                                      operation: operation.perform)
        queue.async {
            let result: HostOperationResult
            do {
                _ = try request.namingItsOperation { try broker.execute(request: request, for: package, action: action) }
                result = HostOperationResult(.succeeded)
            } catch let error as PluginHostServiceError {
                result = HostOperationResult(.failed(HostOperationReason(error)), message: error.description)
            } catch {
                result = HostOperationResult(.failed(.hostServiceFailed), message: error.localizedDescription)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func abandon(_ pluginID: PluginID, because reason: PluginViewSessionEnd) {
        exits?.abandon(pluginID, because: reason)
    }
}
