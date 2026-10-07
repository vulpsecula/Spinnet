import Foundation

// MARK: - The addition to Plugin API Level 2

/// The App in front and its exit, appended to Plugin API Level 2 while it is
/// open (#83): `apps.frontmost` identifies the App behind Spinnet's panel by
/// an App Target, under `read_frontmost_app`, and `apps.quit` asks the Host
/// to quit or force quit it, under `quit_frontmost_app`, after a Host
/// Confirmation. The two Capabilities are separate, so identifying an App
/// never lets a Plugin end it, and ending one never tells the Plugin which
/// it was.
public enum CurrentAppAddition {
    /// How the catalogue records that Level 2 itself, not a Candidate
    /// Contract, first offered these IDs.
    public static let origin = "level_2"

    public static let frontmostID = "apps.frontmost"
    public static let quitID = "apps.quit"

    /// The members appended to Level 2.
    public static let members: [PluginInterfaceMember] = [
        .hostService(frontmostID), .request(quitID), .standardAction(quitID)
    ]

    /// The Capabilities only a Level 2 Plugin may declare.
    public static let capabilities: [PluginCapability] = [.readFrontmostApp, .quitFrontmostApp]
}

// MARK: - Running Apps

/// An exit the Host may perform on an App.
public enum AppExit: String, CaseIterable, Hashable {
    /// Asks the App to quit, as its Quit menu item does; it may ask to save
    /// first, or refuse.
    case quit
    /// Ends the App's process at once; unsaved changes are lost.
    case forceQuit = "force_quit"
}

/// What the Host knows of one running App when it decides what may be done
/// to it.
public struct RunningAppFacts: Hashable {
    /// The App, identified so a reused process ID cannot match.
    public let app: InsertionTargetApp
    /// A regular App, one with a Dock icon and menus; agents and
    /// background-only processes are not.
    public let isRegular: Bool

    public init(app: InsertionTargetApp, isRegular: Bool) {
        self.app = app
        self.isRegular = isRegular
    }
}

/// Which exits the Host performs on which Apps. An App is protected from an
/// exit it does not list: Spinnet itself, every App that is not a regular
/// App, the parts of macOS that run as Apps, and Finder from Force Quit.
/// Protection is decided by the Host for every Plugin alike; no grant lifts
/// it.
public enum AppExitPolicy {
    /// Parts of macOS that run as regular Apps or may come to the front, on
    /// which the Host performs no exit.
    public static let systemBundleIdentifiers: Set<String> = [
        "com.apple.loginwindow", "com.apple.dock", "com.apple.SystemUIServer", "com.apple.WindowManager",
        "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.Spotlight",
        "com.apple.coreservices.uiagent", "com.apple.UserNotificationCenter", "com.apple.SecurityAgent"
    ]
    /// Apps the Host asks to quit but never force quits: macOS relaunches
    /// Finder, and a forced exit loses its file operations.
    public static let forceQuitProtectedBundleIdentifiers: Set<String> = ["com.apple.finder"]

    /// The exits the Host would perform on `facts`, in `AppExit`'s order;
    /// none for a protected App. `ownProcessIdentifier` is Spinnet's.
    public static func exits(for facts: RunningAppFacts, ownProcessIdentifier: Int32) -> [AppExit] {
        let bundle = facts.app.bundleIdentifier
        guard facts.app.processIdentifier != ownProcessIdentifier, facts.isRegular,
              !(bundle.map(systemBundleIdentifiers.contains) ?? false) else { return [] }
        if let bundle, forceQuitProtectedBundleIdentifiers.contains(bundle) { return [.quit] }
        return [.quit, .forceQuit]
    }
}

/// The running Apps the Host acts on: the desktop in the Host, recorded Apps
/// in the Plugin test kit.
public protocol RunningApps: AnyObject {
    /// Spinnet's own process.
    var ownProcessIdentifier: Int32 { get }
    /// The App in front, whichever it is, Spinnet included.
    func frontmost() -> RunningAppFacts?
    /// `app` as it runs now, or nil when that App is no longer running:
    /// a process that reused its ID is another App.
    func facts(of app: InsertionTargetApp) -> RunningAppFacts?
    /// Performs `exit` on exactly `app`, whose identity the caller has just
    /// checked; false when the exit could not be delivered.
    func perform(_ exit: AppExit, on app: InsertionTargetApp) -> Bool
}

// MARK: - App Targets

/// The App Targets the Host has given Plugins: opaque names for running
/// Apps, which a Plugin allowed to identify the App in front receives and
/// may name back to the Host, as `apps.quit`'s `target`. A target names one
/// App, identified by process ID, bundle identifier and launch date, for
/// the Plugin it was given to only; it never contains the process ID.
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

    private struct Entry {
        let target: String
        let app: InsertionTargetApp
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

    /// The target naming `app` for `plugin`, made when it has none.
    public func target(naming app: InsertionTargetApp, for plugin: PluginID) -> String {
        lock.lock()
        defer { lock.unlock() }
        var held = entries[plugin] ?? []
        if let index = held.firstIndex(where: { $0.app.isSameApp(as: app) }) {
            let entry = held.remove(at: index)
            held.append(entry)
            entries[plugin] = held
            return entry.target
        }
        var target = makeTarget()
        while held.contains(where: { $0.target == target }) { target = makeTarget() }
        held.append(Entry(target: target, app: app))
        if held.count > Self.maximumPerPlugin { held.removeFirst(held.count - Self.maximumPerPlugin) }
        entries[plugin] = held
        return target
    }

    /// The App `target` names for `plugin`; nil when it names none, whoever
    /// else it may have been given to.
    public func app(for target: String, of plugin: PluginID) -> InsertionTargetApp? {
        lock.lock()
        defer { lock.unlock() }
        return entries[plugin]?.first { $0.target == target }?.app
    }

    /// Forgets every target of `plugin`.
    public func forget(_ plugin: PluginID) {
        lock.lock()
        entries[plugin] = nil
        lock.unlock()
    }

    /// Forgets every target naming `app`, which has quit.
    public func forget(_ app: InsertionTargetApp) {
        lock.lock()
        for (plugin, held) in entries {
            entries[plugin] = held.filter { !$0.app.isSameApp(as: app) }
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
    /// on it, or null when Spinnet or no App is in front.
    public func identifyFrontmost(of apps: RunningApps, for plugin: PluginID) -> JSONValue {
        guard let facts = apps.frontmost(), facts.app.processIdentifier != apps.ownProcessIdentifier else { return .null }
        return .object([
            "target": .string(target(naming: facts.app, for: plugin)),
            "name": .string(String(facts.app.name.prefix(AppTargets.maximumNameLength))),
            "bundle_id": facts.app.bundleIdentifier.map { .string(String($0.prefix(AppTargets.maximumNameLength))) } ?? .null,
            "exits": .array(AppExitPolicy.exits(for: facts, ownProcessIdentifier: apps.ownProcessIdentifier)
                .map { .string($0.rawValue) })
        ])
    }

    /// The longest name or bundle identifier `apps.frontmost` gives.
    public static let maximumNameLength = 256
}

// MARK: - The request

/// `apps.quit`'s input: the App to end, named by an App Target or, without
/// one, the App in front when the Host starts the operation; and whether to
/// force quit it.
public struct AppQuitRequest: Equatable {
    public let target: String?
    public let force: Bool

    public var exit: AppExit { force ? .forceQuit : .quit }

    public init(target: String? = nil, force: Bool = false) {
        self.target = target
        self.force = force
    }

    /// Reads `input` as a request carries it: null, or an object of an
    /// optional `target` and an optional `force`.
    public init(input: JSONValue) throws {
        switch input {
        case .null:
            self.init()
        case .object(let members):
            if let unknown = members.keys.sorted().first(where: { !["target", "force"].contains($0) }) {
                throw PluginHostServiceError.invalidInput("apps.quit takes no input member \(unknown)")
            }
            var target: String?
            switch members["target"] {
            case nil: break
            case .string(let text)? where AppTargets.isWellFormed(text): target = text
            default:
                throw PluginHostServiceError.invalidInput("apps.quit's target is an App Target apps.frontmost gave")
            }
            var force = false
            switch members["force"] {
            case nil: break
            case .bool(let value)?: force = value
            default: throw PluginHostServiceError.invalidInput("apps.quit's force is true or false")
            }
            self.init(target: target, force: force)
        default:
            throw PluginHostServiceError.invalidInput("apps.quit's input is null or an object of target and force")
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

    /// How long a confirmation waits for an answer before the operation
    /// expires (#70's P8).
    public static let expiry: TimeInterval = 60

    /// The confirmation of `exit` on the App named `app`, asked for by the
    /// Plugin named `plugin`.
    public static func exit(_ exit: AppExit, of app: String, requestedBy plugin: String) -> HostConfirmation {
        switch exit {
        case .quit:
            return HostConfirmation(
                title: "Quit \(app)?",
                message: "\(plugin) asks Spinnet to quit \(app). \(app) may ask you to save your changes first.",
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
    /// sessions' executor, unless the returned dismissal runs first.
    func confirm(_ confirmation: HostConfirmation, for action: ActionConfiguration,
                 answer: @escaping (HostConfirmationAnswer) -> Void) -> () -> Void
}

// MARK: - Performing the exit

/// Performs `apps.quit` for the View Sessions' Requested Host Operations
/// (ADR 0018), on their executor. It resolves the target, refuses a
/// protected or unavailable one, asks for the Host Confirmation, and after
/// the user confirms checks the requesting Action's authority and the App's
/// identity again before ending exactly that App: a target that quit, or
/// whose process ID another App now has, is refused, and nothing is ever
/// retargeted. Messages name Apps; the Host shows them and never gives them
/// to a Plugin.
public final class AppExitPerformer {
    public typealias Schedule = (TimeInterval, @escaping () -> Void) -> Void

    private let apps: RunningApps
    private let targets: AppTargets
    private let confirmations: HostConfirming
    private let schedule: Schedule
    private var serials = 0
    /// The confirmation on screen for each Plugin: its dismissal and how to
    /// end the operation it holds.
    private var confirming: [PluginID: (serial: Int, dismiss: () -> Void, end: (HostOperationResult) -> Void)] = [:]

    public init(apps: RunningApps, targets: AppTargets, confirmations: HostConfirming, schedule: @escaping Schedule) {
        self.apps = apps
        self.targets = targets
        self.confirmations = confirmations
        self.schedule = schedule
    }

    /// Whether a confirmation is on screen for `plugin`.
    public func isConfirming(_ plugin: PluginID) -> Bool { confirming[plugin] != nil }

    /// Performs `request` for `action` of the Plugin named `pluginName`.
    /// `authorize` checks the Action's authority as it stands, and throws
    /// what refuses it.
    public func perform(_ request: AppQuitRequest, for action: ActionConfiguration, pluginName: String,
                        authorize: @escaping () throws -> Void, completion: @escaping (HostOperationResult) -> Void) {
        let plugin = action.pluginID
        let exit = request.exit
        let resolved: InsertionTargetApp
        switch resolve(request, for: plugin) {
        case .refused(let refusal): return completion(refusal)
        case .resolved(let facts):
            if let refusal = protection(of: facts, from: exit) { return completion(refusal) }
            resolved = facts.app
        }
        serials += 1
        let serial = serials
        var ended = false
        let end: (HostOperationResult) -> Void = { [weak self] result in
            guard !ended else { return }
            ended = true
            if self?.confirming[plugin]?.serial == serial { self?.confirming[plugin] = nil }
            completion(result)
        }
        let dismiss = confirmations.confirm(.exit(exit, of: resolved.name, requestedBy: pluginName), for: action) {
            [weak self] answer in
            guard let self, !ended else { return }
            switch answer {
            // The user's own answer needs no word.
            case .declined: end(HostOperationResult(.declined))
            case .confirmed: end(self.execute(exit, on: resolved, authorize: authorize))
            }
        }
        confirming[plugin] = (serial, dismiss, end)
        schedule(HostConfirmation.expiry) { [weak self] in
            guard let self, let current = self.confirming[plugin], current.serial == serial else { return }
            current.dismiss()
            end(HostOperationResult(.expired, message: "The confirmation to \(exit.verb) \(resolved.name) went unanswered"))
        }
    }

    /// The operation's owner ended while its confirmation was on screen:
    /// the confirmation goes away, declined when the user closed the view
    /// and cancelled otherwise. Nothing happens when none is on screen.
    public func abandon(_ plugin: PluginID, because reason: PluginViewSessionEnd) {
        guard let current = confirming[plugin] else { return }
        confirming[plugin] = nil
        current.dismiss()
        switch reason {
        case .viewClosed, .closedByPlugin: current.end(HostOperationResult(.declined))
        default: current.end(HostOperationResult(.cancelled, message: "Nothing was quit: \(reason.explanation)"))
        }
    }

    // MARK: Steps

    private enum Resolution {
        case resolved(RunningAppFacts)
        case refused(HostOperationResult)
    }

    private func resolve(_ request: AppQuitRequest, for plugin: PluginID) -> Resolution {
        if let target = request.target {
            guard let app = targets.app(for: target, of: plugin) else {
                return .refused(HostOperationResult(.refused(.noTarget),
                                                    message: "The App the Plugin named is no longer one it may quit"))
            }
            guard let facts = apps.facts(of: app) else {
                targets.forget(app)
                return .refused(HostOperationResult(.refused(.noTarget), message: "\(app.name) has quit"))
            }
            return .resolved(facts)
        }
        guard let facts = apps.frontmost(), facts.app.processIdentifier != apps.ownProcessIdentifier else {
            return .refused(HostOperationResult(.refused(.noTarget), message: "Spinnet or no App is in front"))
        }
        return .resolved(facts)
    }

    private func protection(of facts: RunningAppFacts, from exit: AppExit) -> HostOperationResult? {
        guard !AppExitPolicy.exits(for: facts, ownProcessIdentifier: apps.ownProcessIdentifier).contains(exit) else {
            return nil
        }
        return HostOperationResult(.refused(.targetProtected), message: "Spinnet does not \(exit.verb) \(facts.app.name)")
    }

    /// After the user confirmed: authority and identity again, then exactly
    /// the App confirmed.
    private func execute(_ exit: AppExit, on app: InsertionTargetApp, authorize: () throws -> Void) -> HostOperationResult {
        do {
            try authorize()
        } catch let error as PluginHostServiceError {
            let reason = HostOperationReason(error)
            return HostOperationResult(.refused(reason == .hostServiceFailed ? .commandUnavailable : reason),
                                       message: error.description)
        } catch {
            return HostOperationResult(.refused(.commandUnavailable), message: error.localizedDescription)
        }
        guard let facts = apps.facts(of: app) else {
            targets.forget(app)
            return HostOperationResult(.refused(.noTarget), message: "\(app.name) quit before Spinnet could \(exit.verb) it")
        }
        if let refusal = protection(of: facts, from: exit) { return refusal }
        guard apps.perform(exit, on: app) else {
            return HostOperationResult(.failed(.hostServiceFailed), message: "\(app.name) could not be asked to quit")
        }
        if exit == .forceQuit { targets.forget(app) }
        return HostOperationResult(.succeeded)
    }
}

extension AppExit {
    /// The verb a message uses.
    var verb: String {
        switch self {
        case .quit: return "quit"
        case .forceQuit: return "force quit"
        }
    }
}
