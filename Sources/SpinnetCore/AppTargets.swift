import Foundation

// MARK: - The addition to Plugin API Level 2

/// The App in front and its exits, appended to Plugin API Level 2 while it
/// is open (#83): `apps.frontmost` identifies the App behind Spinnet's panel
/// by an App Target, under `read_frontmost_app`; `apps.quit` asks the Host
/// to quit or force quit it, and `apps.close` to close its front window,
/// under `quit_frontmost_app`. Quit and Close are exactly the App's own ⌘Q
/// and ⌘W menu items, which the Host presses. Force Quit, and a quit or
/// close of an App that was not in front when the Host accepted the
/// request, need a Host Confirmation. The two Capabilities are separate, so
/// identifying an App never lets a Plugin end it, and ending one never
/// tells the Plugin which it was.
public enum CurrentAppAddition {
    /// How the catalogue records that Level 2 itself, not a Candidate
    /// Contract, first offered these IDs.
    public static let origin = "level_2"

    public static let frontmostID = "apps.frontmost"
    public static let quitID = "apps.quit"
    public static let closeID = "apps.close"
    /// The operations that perform an `AppExit`.
    public static let exitIDs = [quitID, closeID]

    /// The members appended to Level 2.
    public static let members: [PluginInterfaceMember] = [
        .hostService(frontmostID), .request(quitID), .standardAction(quitID), .request(closeID), .standardAction(closeID)
    ]

    /// The Capabilities only a Level 2 Plugin may declare.
    public static let capabilities: [PluginCapability] = [.readFrontmostApp, .quitFrontmostApp]
}

// MARK: - Running Apps

/// An exit the Host may perform on an App, in the order `apps.frontmost`
/// lists them.
public enum AppExit: String, CaseIterable, Hashable {
    /// Presses the App's own ⌘W menu item, exactly as ⌘W does: the App
    /// closes its front window, and may ask to save first.
    case close
    /// Presses the App's own ⌘Q menu item, exactly as ⌘Q or the Dock's Quit
    /// does: the App may ask to save first, or refuse.
    case quit
    /// Ends the App's process at once; unsaved changes are lost.
    case forceQuit = "force_quit"

    /// The key of the menu item that performs this exit with Command alone,
    /// as Accessibility reports it (`AXMenuItemCmdChar`); nil for Force
    /// Quit, which no menu of the App offers.
    public var menuKey: String? {
        switch self {
        case .close: return "W"
        case .quit: return "Q"
        case .forceQuit: return nil
        }
    }

    /// Whether the App's own menu item performs it.
    public var isMenuItem: Bool { menuKey != nil }
}

/// What came of performing an exit.
public enum AppExitDelivery: Hashable {
    /// The App was sent the exit: its menu item pressed, or its process
    /// ended. A pressed item the App had not answered within its bound
    /// counts, since the App may be asking to save.
    case delivered
    /// The App's menu no longer has the item, or it is disabled: nothing
    /// was done.
    case notOffered
    /// The App is gone, or macOS did not take the exit.
    case failed
}

/// One running App as the Host names it to identify or end it: its process
/// ID, bundle identifier and launch date together, so that another App that
/// later reuses the process ID, or the same App started again, is another
/// App. Its name is shown to the user and never given to a Plugin. It is
/// not an Insertion Target: nothing is ever inserted into it.
public struct RunningAppIdentity: Hashable {
    public let processIdentifier: Int32
    public let bundleIdentifier: String?
    public let launchDate: Date?
    public let name: String

    public init(processIdentifier: Int32, bundleIdentifier: String?, launchDate: Date?, name: String) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.launchDate = launchDate
        self.name = name
    }

    /// Whether the Host can tell this App from a later process that reuses
    /// its ID: it has a launch date, or for an App Launch Services did not
    /// start (such as Finder) its process's start time, which the Host gives
    /// as `launchDate`. Without either the Host neither names nor ends it.
    public var isComplete: Bool { launchDate != nil }

    /// The same running App, whatever it is called now. An incomplete
    /// identity is the same as no App, not even itself.
    public func isSameApp(as other: RunningAppIdentity) -> Bool {
        isComplete && other.isComplete && processIdentifier == other.processIdentifier
            && bundleIdentifier == other.bundleIdentifier && launchDate == other.launchDate
    }
}

/// What the Host knows of one running App when it decides what may be done
/// to it.
public struct RunningAppFacts: Hashable {
    public let identity: RunningAppIdentity
    /// A regular App, one with a Dock icon and menus; agents and
    /// background-only processes are not.
    public let isRegular: Bool

    public init(identity: RunningAppIdentity, isRegular: Bool) {
        self.identity = identity
        self.isRegular = isRegular
    }
}

/// Which exits the Host performs on which Apps, by generic rules alone: no
/// rule names an App. Close and Quit are the App's own, offered exactly
/// when its menu has an enabled ⌘W or ⌘Q item, so the Host does to an App
/// only what the user's ⌘W and ⌘Q would. Force Quit is offered for every
/// regular App. Spinnet itself, and every App that is not a regular App,
/// get none: the parts of macOS that run as Apps (the Dock, loginwindow,
/// Control Center and the like) are agents, not regular Apps. The rules are
/// the Host's, the same for every Plugin; no grant lifts them.
public enum AppExitPolicy {
    /// Whether the Host performs any exit on `facts`: a regular App other
    /// than Spinnet, whose process is `ownProcessIdentifier`.
    public static func isEligible(_ facts: RunningAppFacts, ownProcessIdentifier: Int32) -> Bool {
        facts.identity.processIdentifier != ownProcessIdentifier && facts.isRegular
    }

    /// The exits the Host would perform on `facts`, whose menu offers
    /// `menu`, in `AppExit`'s order; none for Spinnet or an App that is not
    /// regular.
    public static func exits(for facts: RunningAppFacts, menu: Set<AppExit>, ownProcessIdentifier: Int32) -> [AppExit] {
        guard isEligible(facts, ownProcessIdentifier: ownProcessIdentifier) else { return [] }
        return AppExit.allCases.filter { $0.isMenuItem ? menu.contains($0) : true }
    }
}

/// The running Apps the Host acts on: the desktop in the Host, recorded Apps
/// in the Plugin test kit. The Host's answers `frontmost` on any thread, so
/// `apps.frontmost` reads the App in front without waiting on the main
/// thread.
public protocol RunningApps: AnyObject {
    /// Spinnet's own process.
    var ownProcessIdentifier: Int32 { get }
    /// The App in front, whichever it is, Spinnet included.
    func frontmost() -> RunningAppFacts?
    /// `app` as it runs now, or nil when that App is no longer running:
    /// a process that reused its ID is another App.
    func facts(of app: RunningAppIdentity) -> RunningAppFacts?
    /// The exits `app`'s own menu offers now, of `close` and `quit`: an
    /// enabled item whose shortcut is ⌘W or ⌘Q, Command alone, in one of
    /// its menu bar's menus; none when it no longer runs or its menu does
    /// not answer. It messages the App, within a bound, so the Host never
    /// reads it on the main thread. Throws
    /// `PluginHostServiceError.systemPermissionDenied(.accessibility)` when
    /// Spinnet may not read other Apps' menus.
    func menuExits(of app: RunningAppIdentity) throws -> Set<AppExit>
    /// Performs `exit` on exactly `app`, whose identity the caller has just
    /// checked: presses its menu item, found again now, for Close and Quit,
    /// and ends its process for Force Quit. Like `menuExits`, it may message
    /// the App and throws the same for Close and Quit without
    /// Accessibility.
    func perform(_ exit: AppExit, on app: RunningAppIdentity) throws -> AppExitDelivery
    /// Calls `terminated` with every App that quits from now on.
    func observeTerminations(_ terminated: @escaping (RunningAppIdentity) -> Void)
}

public extension RunningApps {
    /// The App in front that the Host can name: nil while Spinnet or no App
    /// is in front, or an App whose identity is incomplete.
    func appInFront() -> RunningAppFacts? {
        guard let facts = frontmost(), facts.identity.processIdentifier != ownProcessIdentifier,
              facts.identity.isComplete else { return nil }
        return facts
    }
}

// MARK: - App Targets

/// The App Targets the Host has given Plugins: opaque names for running
/// Apps, which a Plugin allowed to identify the App in front receives and
/// may name back to the Host, as `apps.quit`'s and `apps.close`'s `target`.
/// A target names one
/// App, identified by process ID, bundle identifier and launch date, for
/// the Plugin it was given to only; it never contains the process ID, and
/// no target names an App whose identity is incomplete.
///
/// A target lasts until the App quits, the Plugin is updated, disabled or
/// removed or loses a Capability, or Spinnet quits; the Host keeps at most
/// `maximumPerPlugin` for each Plugin, forgetting the least recently given.
/// Identifying the same App again gives the same target.
public final class AppTargets {
    /// The most targets one Plugin holds at once. The App in front changes
    /// one at a time, so a Plugin reading it as the user switches Apps
    /// needs few; Current App needs one, an App-bound effect one more.
    public static let maximumPerPlugin = 16
    public static let prefix = "app_"
    /// `prefix` and 32 lowercase hexadecimal digits.
    public static let length = prefix.count + 32
    /// The most characters of a name or of a bundle identifier
    /// `apps.frontmost` gives.
    public static let maximumTextLength = 256

    private struct Entry {
        let target: String
        let identity: RunningAppIdentity
    }

    private let lock = NSLock()
    private var entries: [PluginID: [Entry]] = [:]
    private let makeTarget: () -> String

    public init(makeTarget: @escaping () -> String = AppTargets.randomTarget) {
        self.makeTarget = makeTarget
    }

    public static func randomTarget() -> String {
        prefix + (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased().prefix(32)
    }

    /// Whether `text` has a target's form; it may still name nothing.
    public static func isWellFormed(_ text: String) -> Bool {
        guard text.count == length, text.hasPrefix(prefix) else { return false }
        return text.dropFirst(prefix.count).unicodeScalars.allSatisfy {
            ("0"..."9").contains($0) || ("a"..."f").contains($0)
        }
    }

    /// Forgets the targets naming each App of `apps` as it quits, not only
    /// once a Plugin names one again.
    public func forgetTerminatedApps(of apps: RunningApps) {
        apps.observeTerminations { [weak self] in self?.forget($0) }
    }

    /// The target naming `app` for `plugin`, made when it has none; nil when
    /// `app`'s identity is incomplete.
    public func target(naming app: RunningAppIdentity, for plugin: PluginID) -> String? {
        guard app.isComplete else { return nil }
        lock.lock()
        defer { lock.unlock() }
        var held = entries[plugin] ?? []
        if let index = held.firstIndex(where: { $0.identity.isSameApp(as: app) }) {
            let entry = held.remove(at: index)
            held.append(entry)
            entries[plugin] = held
            return entry.target
        }
        var target = makeTarget()
        while held.contains(where: { $0.target == target }) { target = makeTarget() }
        held.append(Entry(target: target, identity: app))
        if held.count > Self.maximumPerPlugin { held.removeFirst(held.count - Self.maximumPerPlugin) }
        entries[plugin] = held
        return target
    }

    /// The App `target` names for `plugin`; nil when it names none, whoever
    /// else it may have been given to.
    public func app(for target: String, of plugin: PluginID) -> RunningAppIdentity? {
        lock.lock()
        defer { lock.unlock() }
        return entries[plugin]?.first { $0.target == target }?.identity
    }

    /// Forgets every target of `plugin`.
    public func forget(_ plugin: PluginID) {
        lock.lock()
        entries[plugin] = nil
        lock.unlock()
    }

    /// Forgets every target naming `app`, which has quit.
    public func forget(_ app: RunningAppIdentity) {
        lock.lock()
        for (plugin, held) in entries {
            entries[plugin] = held.filter { !$0.identity.isSameApp(as: app) }
        }
        lock.unlock()
    }

    /// The number of targets `plugin` holds.
    public func count(for plugin: PluginID) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return entries[plugin]?.count ?? 0
    }

    /// `apps.frontmost`'s result for `plugin`: the App in front with its
    /// target, name, bundle identifier and the exits the Host would perform
    /// on it, or null when Spinnet, no App or an App the Host cannot name is
    /// in front. Any thread but the main thread may ask: it reads the App's
    /// menu, which messages the App, on the calling thread.
    public func identifyFrontmost(of apps: RunningApps, for plugin: PluginID) -> JSONValue {
        guard let facts = apps.appInFront(), let target = target(naming: facts.identity, for: plugin) else {
            return .null
        }
        let own = apps.ownProcessIdentifier
        // Without Accessibility the menu cannot be read: no Close or Quit.
        let menu = AppExitPolicy.isEligible(facts, ownProcessIdentifier: own)
            ? (try? apps.menuExits(of: facts.identity)) ?? [] : []
        return .object([
            "target": .string(target),
            "name": .string(String(facts.identity.name.prefix(Self.maximumTextLength))),
            "bundle_id": facts.identity.bundleIdentifier.map { .string(String($0.prefix(Self.maximumTextLength))) }
                ?? .null,
            "exits": .array(AppExitPolicy.exits(for: facts, menu: menu, ownProcessIdentifier: own)
                .map { .string($0.rawValue) })
        ])
    }
}

// MARK: - The request

/// An `apps.quit` or `apps.close` request's input: the App, named by an App
/// Target or, without one, the App in front when the Host accepts the
/// request; and the exit, which for `apps.quit` is Force Quit when it says
/// `force`.
public struct AppExitRequest: Equatable {
    public let target: String?
    public let exit: AppExit

    public init(target: String? = nil, exit: AppExit = .quit) {
        self.target = target
        self.exit = exit
    }

    /// Reads `input` as a request of the operation `perform` carries it:
    /// null, or an object of an optional `target` and, for `apps.quit`
    /// only, an optional `force`.
    public init(perform: String, input: JSONValue) throws {
        let members: [String]
        switch perform {
        case CurrentAppAddition.quitID: members = ["target", "force"]
        case CurrentAppAddition.closeID: members = ["target"]
        default: throw PluginHostServiceError.invalidInput("\(perform) performs no exit of an App")
        }
        let base: AppExit = perform == CurrentAppAddition.closeID ? .close : .quit
        switch input {
        case .null:
            self.init(exit: base)
        case .object(let given):
            if let unknown = given.keys.sorted().first(where: { !members.contains($0) }) {
                throw PluginHostServiceError.invalidInput("\(perform) takes no input member \(unknown)")
            }
            var target: String?
            switch given["target"] {
            case nil: break
            case .string(let text)? where AppTargets.isWellFormed(text): target = text
            default:
                throw PluginHostServiceError.invalidInput("\(perform)'s target is an App Target apps.frontmost gave")
            }
            var force = false
            switch given["force"] {
            case nil: break
            case .bool(let value)?: force = value
            default: throw PluginHostServiceError.invalidInput("\(perform)'s force is true or false")
            }
            self.init(target: target, exit: force ? .forceQuit : base)
        default:
            throw PluginHostServiceError.invalidInput(
                "\(perform)'s input is null or an object of \(members.joined(separator: " and "))")
        }
    }
}

// MARK: - Host Confirmation

/// A confirmation the Host draws before an operation whose definition
/// requires one, in its own words, naming the target it resolved. A Plugin
/// can neither skip nor word it.
public struct HostConfirmation: Equatable {
    public let title: String
    public let message: String
    /// The button that performs the operation. Cancel is the default; Return
    /// never confirms a destructive operation.
    public let confirmTitle: String
    public let isDestructive: Bool

    public init(title: String, message: String, confirmTitle: String, isDestructive: Bool) {
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.isDestructive = isDestructive
    }

    /// How long a confirmation waits on screen for an answer before the
    /// operation expires (#70's P8).
    public static let expiry: TimeInterval = 60

    /// The confirmation of `exit` on the App named `app`, asked for by the
    /// Plugin named `plugin`.
    public static func exit(_ exit: AppExit, of app: String, requestedBy plugin: String) -> HostConfirmation {
        switch exit {
        case .close:
            return HostConfirmation(
                title: "Close \(app)'s Front Window?",
                message: "\(plugin) asks Spinnet to close the front window of \(app), as its Close menu item (⌘W) does. "
                    + "\(app) may ask you to save your changes first.",
                confirmTitle: "Close", isDestructive: true)
        case .quit:
            return HostConfirmation(
                title: "Quit \(app)?",
                message: "\(plugin) asks Spinnet to quit \(app), as its Quit menu item (⌘Q) does. "
                    + "\(app) may ask you to save your changes first.",
                confirmTitle: "Quit", isDestructive: true)
        case .forceQuit:
            return HostConfirmation(
                title: "Force Quit \(app)?",
                message: "\(plugin) asks Spinnet to force quit \(app). Any unsaved changes in \(app) will be lost.",
                confirmTitle: "Force Quit", isDestructive: true)
        }
    }
}

/// The user's answer to a Host Confirmation.
public enum HostConfirmationAnswer: Equatable {
    case confirmed
    case declined
}

/// Draws Host Confirmations: a panel in the Host, recorded answers in the
/// Plugin test kit.
public protocol HostConfirming: AnyObject {
    /// Shows `confirmation` for `action` and calls `answer` once, on the
    /// sessions' executor, unless the returned dismissal runs first. Each
    /// confirmation stands alone: showing one never answers or removes
    /// another.
    func confirm(_ confirmation: HostConfirmation, for action: ActionConfiguration,
                 answer: @escaping (HostConfirmationAnswer) -> Void) -> () -> Void
}

// MARK: - Performing the exit

/// Performs `apps.quit` and `apps.close` for the View Sessions' Requested
/// Host Operations (ADR 0018), on their executor. Without a target, the App
/// it acts on is the one in front when the Host accepted the request
/// (`accept`); with one, the App the target names. It refuses an App that
/// is gone, Spinnet, an App that is not regular, and a Close or Quit the
/// App's own menu does not offer. A Close or graceful Quit of the App that
/// was in front at acceptance, named by a target or not, runs at once, the
/// App's own save prompts still applying; Force Quit, and a Close or Quit
/// of an App that was not in front then, wait for the user to confirm a
/// Host Confirmation. Either way the Host checks the requesting Action's
/// authority and the App's identity again, and for Close and Quit finds the
/// App's menu item again, before acting on exactly that App: a target that
/// quit, or whose process ID another App now has, or whose item went away,
/// is refused, and nothing is ever retargeted.
///
/// Reading an App's menu and pressing its item message the App, which may
/// be slow to answer, so the Host does both away from the executor
/// (`detach`) and comes back to it with the answer. An operation whose
/// owner ends while its App's menu is read is cancelled, and the late
/// answer does nothing.
///
/// One confirmation is on screen at a time, whichever Plugin asked: the
/// others wait their turn in order, and each one's expiry runs from when it
/// is shown. Messages name Apps; the Host shows them and never gives them
/// to a Plugin.
public final class AppExitPerformer {
    public typealias Schedule = (TimeInterval, @escaping () -> Void) -> Void
    /// Runs `work` away from the executor, where it may message another
    /// App and wait for its answer, then `then` back on the executor.
    public typealias Detach = (_ work: @escaping () -> Void, _ then: @escaping () -> Void) -> Void

    /// An operation the Host accepted and has not finished.
    private struct Operation {
        let serial: Int
        let plugin: PluginID
        let action: ActionConfiguration
        let exit: AppExit
        let app: RunningAppIdentity
        let pluginName: String
        /// Whether it waits for a Host Confirmation before it runs.
        let asks: Bool
        let authorize: () throws -> Void
        let completion: (HostOperationResult) -> Void
        var dismiss: (() -> Void)?

        var confirmation: HostConfirmation { .exit(exit, of: app.name, requestedBy: pluginName) }
    }

    private let apps: RunningApps
    private let targets: AppTargets
    private let confirmations: HostConfirming
    private let schedule: Schedule
    private let detach: Detach
    private var serials = 0
    /// The Close and Quit operations whose App's menu is being read.
    private var checking: [Operation] = []
    /// The operations waiting for an answer, in the order they asked; the
    /// one `showing` names is on screen.
    private var pending: [Operation] = []
    private var showing: Int?

    public init(apps: RunningApps, targets: AppTargets, confirmations: HostConfirming, schedule: @escaping Schedule,
                detach: @escaping Detach = { work, then in work(); then() }) {
        self.apps = apps
        self.targets = targets
        self.confirmations = confirmations
        self.schedule = schedule
        self.detach = detach
    }

    /// Whether an operation of `plugin` waits for a confirmation, on screen
    /// or for its turn.
    public func isConfirming(_ plugin: PluginID) -> Bool { pending.contains { $0.plugin == plugin } }

    /// Whether `plugin`'s confirmation is the one on screen.
    public func isShowing(_ plugin: PluginID) -> Bool {
        pending.contains { $0.serial == showing && $0.plugin == plugin }
    }

    /// Binds `request` to the App in front when the Host accepts it, or to
    /// no App when Spinnet, none or one the Host cannot name is: without a
    /// target, the App it acts on; with one, the App whose Close or
    /// graceful Quit needs no Host Confirmation.
    public func accept(_ request: AppExitRequest) -> AcceptedHostOperationTarget {
        .appInFront(apps.appInFront()?.identity)
    }

    /// Performs `request`, as `accept` bound it, for `action` of the Plugin
    /// named `pluginName`. `authorize` checks the Action's authority as it
    /// stands, and throws what refuses it. A request that was never
    /// accepted is accepted now.
    public func perform(_ request: AppExitRequest, accepted: AcceptedHostOperationTarget,
                        for action: ActionConfiguration, pluginName: String,
                        authorize: @escaping () throws -> Void, completion: @escaping (HostOperationResult) -> Void) {
        let accepted = accepted == .none ? accept(request) : accepted
        let facts: RunningAppFacts
        switch resolve(request, accepted: accepted, for: action.pluginID) {
        case .refused(let refusal): return completion(refusal)
        case .resolved(let resolved): facts = resolved
        }
        guard AppExitPolicy.isEligible(facts, ownProcessIdentifier: apps.ownProcessIdentifier) else {
            return completion(Self.protected(facts.identity, from: request.exit))
        }
        var wasInFront = false
        if case .appInFront(let front?) = accepted { wasInFront = front.isSameApp(as: facts.identity) }
        serials += 1
        let operation = Operation(serial: serials, plugin: action.pluginID, action: action, exit: request.exit,
                                  app: facts.identity, pluginName: pluginName,
                                  asks: request.exit == .forceQuit || !wasInFront,
                                  authorize: authorize, completion: completion)
        guard operation.exit.isMenuItem else { return proceed(operation) }
        // Close and Quit are only what the App's own menu offers now.
        checking.append(operation)
        var offered: Result<Set<AppExit>, Error> = .success([])
        detach({ [apps] in
            offered = Result { try apps.menuExits(of: operation.app) }
        }, { [weak self] in
            // Its owner may have ended while the menu was read.
            guard let self, let index = self.checking.firstIndex(where: { $0.serial == operation.serial }) else { return }
            self.checking.remove(at: index)
            switch offered {
            case .failure(let error): operation.completion(Self.refusal(error, of: operation.exit))
            case .success(let menu) where !menu.contains(operation.exit):
                operation.completion(Self.notOffered(operation.exit, by: operation.app))
            case .success: self.proceed(operation)
            }
        })
    }

    /// The operation's owner ended before it ran: while its App's menu was
    /// read, or while it waited for its confirmation, which goes away. It is
    /// cancelled, without a word when the user closed the view. Nothing
    /// happens when `plugin` has none waiting, or one already running.
    public func abandon(_ plugin: PluginID, because reason: PluginViewSessionEnd) {
        let message = { (exit: AppExit) in
            reason == .viewClosed ? nil : "Nothing was \(exit == .close ? "closed" : "quit"): \(reason.explanation)"
        }
        if let index = checking.firstIndex(where: { $0.plugin == plugin }) {
            let cancelled = checking.remove(at: index)
            return cancelled.completion(HostOperationResult(.cancelled, message: message(cancelled.exit)))
        }
        guard let waiting = pending.first(where: { $0.plugin == plugin }) else { return }
        end(waiting.serial, with: HostOperationResult(.cancelled, message: message(waiting.exit)))
    }

    private func proceed(_ operation: Operation) {
        guard operation.asks else { return execute(operation) }
        pending.append(operation)
        showNext()
    }

    // MARK: Confirmations

    private func showNext() {
        guard showing == nil, let next = pending.first else { return }
        let serial = next.serial
        showing = serial
        let dismiss = confirmations.confirm(next.confirmation, for: next.action) { [weak self] answer in
            self?.answered(serial, answer)
        }
        // The confirmation may have been answered while it was drawn.
        guard showing == serial, let index = pending.firstIndex(where: { $0.serial == serial }) else { return }
        pending[index].dismiss = dismiss
        schedule(HostConfirmation.expiry) { [weak self] in
            guard let self, self.showing == serial else { return }
            self.end(serial, with: HostOperationResult(
                .expired, message: "The confirmation to \(next.exit.phrase(next.app.name)) went unanswered"))
        }
    }

    private func answered(_ serial: Int, _ answer: HostConfirmationAnswer) {
        guard showing == serial, let index = pending.firstIndex(where: { $0.serial == serial }) else { return }
        switch answer {
        // The user's own answer needs no word.
        case .declined: end(serial, with: HostOperationResult(.declined), dismissing: false)
        case .confirmed:
            let confirmed = pending.remove(at: index)
            showing = nil
            execute(confirmed)
            showNext()
        }
    }

    /// Ends the operation `serial` with `result` and shows the next
    /// confirmation. A confirmation the user did not answer goes away.
    private func end(_ serial: Int, with result: HostOperationResult, dismissing: Bool = true) {
        guard let index = pending.firstIndex(where: { $0.serial == serial }) else { return }
        let ended = pending.remove(at: index)
        if showing == serial {
            showing = nil
            if dismissing { ended.dismiss?() }
        }
        ended.completion(result)
        showNext()
    }

    // MARK: Steps

    private enum Resolution {
        case resolved(RunningAppFacts)
        case refused(HostOperationResult)
    }

    private func resolve(_ request: AppExitRequest, accepted: AcceptedHostOperationTarget,
                         for plugin: PluginID) -> Resolution {
        let app: RunningAppIdentity
        if let target = request.target {
            guard let named = targets.app(for: target, of: plugin) else {
                return .refused(HostOperationResult(.refused(.noTarget),
                                                    message: "The App the Plugin named is no longer one it may act on"))
            }
            app = named
        } else {
            guard case .appInFront(let front?) = accepted else {
                return .refused(HostOperationResult(.refused(.noTarget), message: "Spinnet or no App was in front"))
            }
            app = front
        }
        guard let facts = apps.facts(of: app) else {
            targets.forget(app)
            return .refused(HostOperationResult(.refused(.noTarget), message: "\(app.name) has quit"))
        }
        return .resolved(facts)
    }

    /// At once, or after the user confirmed: authority and identity again,
    /// then, away from the executor, exactly the App resolved, its menu item
    /// found again for Close and Quit.
    private func execute(_ operation: Operation) {
        do {
            try operation.authorize()
        } catch {
            return operation.completion(.refusal(error))
        }
        let app = operation.app
        guard let facts = apps.facts(of: app) else {
            targets.forget(app)
            return operation.completion(HostOperationResult(
                .refused(.noTarget), message: "\(app.name) quit before Spinnet could \(operation.exit.phrase(app.name))"))
        }
        guard AppExitPolicy.isEligible(facts, ownProcessIdentifier: apps.ownProcessIdentifier) else {
            return operation.completion(Self.protected(app, from: operation.exit))
        }
        var delivery: Result<AppExitDelivery, Error> = .success(.failed)
        detach({ [apps] in
            delivery = Result { try apps.perform(operation.exit, on: app) }
        }, { [targets] in
            switch delivery {
            case .success(.delivered):
                if operation.exit == .forceQuit { targets.forget(app) }
                operation.completion(HostOperationResult(.succeeded))
            case .success(.notOffered):
                operation.completion(Self.notOffered(operation.exit, by: app))
            case .success(.failed):
                operation.completion(HostOperationResult(
                    .failed(.hostServiceFailed), message: "Spinnet could not \(operation.exit.phrase(app.name))"))
            case .failure(let error):
                operation.completion(Self.refusal(error, of: operation.exit))
            }
        })
    }

    private static func protected(_ app: RunningAppIdentity, from exit: AppExit) -> HostOperationResult {
        HostOperationResult(.refused(.targetProtected), message: "Spinnet does not \(exit.phrase(app.name))")
    }

    /// The App's menu has no enabled item for `exit`.
    private static func notOffered(_ exit: AppExit, by app: RunningAppIdentity) -> HostOperationResult {
        HostOperationResult(.refused(.targetProtected),
                            message: "\(app.name) has no enabled \(exit.menuItemTitle) menu item (⌘\(exit.menuKey ?? ""))")
    }

    /// Without Accessibility the Host can neither read nor press an App's
    /// menu: the word names it.
    private static func refusal(_ error: Error, of exit: AppExit) -> HostOperationResult {
        guard case PluginHostServiceError.systemPermissionDenied(let permission)? = error as? PluginHostServiceError else {
            return .refusal(error)
        }
        return HostOperationResult(
            .refused(.systemPermissionDenied),
            message: "Spinnet needs \(permission.title) to \(exit.verb) an App as its \(exit.menuItemTitle) menu item does. "
                + "Allow Spinnet in System Settings > Privacy & Security > \(permission.title)")
    }
}

extension AppExit {
    /// The verb a message uses.
    var verb: String {
        switch self {
        case .close: return "close a window of"
        case .quit: return "quit"
        case .forceQuit: return "force quit"
        }
    }

    /// The exit performed on the App named `app`, as a message says it.
    func phrase(_ app: String) -> String {
        switch self {
        case .close: return "close the front window of \(app)"
        case .quit: return "quit \(app)"
        case .forceQuit: return "force quit \(app)"
        }
    }

    /// The title the App's own menu item usually has.
    var menuItemTitle: String {
        switch self {
        case .close: return "Close"
        case .quit: return "Quit"
        case .forceQuit: return "Force Quit"
        }
    }
}
