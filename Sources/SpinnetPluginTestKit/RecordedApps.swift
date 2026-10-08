import Foundation
import SpinnetCore

/// Recorded running Apps for `apps.frontmost`, `apps.quit` and `apps.close`
/// (#83), in place of the desktop: which App is in front, which Apps run,
/// what each App's own menu offers, whether Spinnet has Accessibility, and
/// the exits the Host performed. Give it to `RecordedHostServices(apps:)`
/// to answer `apps.frontmost` and to `RecordedHostOperations(apps:)` to
/// perform `apps.quit` and `apps.close`; both then follow the Host's own
/// rules, with the Host's App Targets, menu detection and identity checks,
/// so a target outlives neither its App nor a relaunch.
public final class RecordedApps: RunningApps {
    /// A recorded App, by what a user sees of it.
    public struct App: Hashable {
        public let name: String
        public let bundleID: String?
        /// False for an agent or background-only process.
        public let isRegular: Bool
        /// What its own menu offers when it launches: `close` for an enabled
        /// ⌘W item, `quit` for an enabled ⌘Q item.
        public let menu: Set<AppExit>

        public init(_ name: String, bundleID: String?, isRegular: Bool = true, menu: Set<AppExit> = [.close, .quit]) {
            self.name = name
            self.bundleID = bundleID
            self.isRegular = isRegular
            self.menu = menu.filter(\.isMenuItem)
        }

        public static let textEdit = App("TextEdit", bundleID: "com.apple.TextEdit")
        public static let safari = App("Safari", bundleID: "com.apple.Safari")
        /// Finder's menu has Close Window (⌘W) but no Quit.
        public static let finder = App("Finder", bundleID: "com.apple.finder", menu: [.close])
        public static let dock = App("Dock", bundleID: "com.apple.dock", isRegular: false, menu: [])
        /// Spinnet itself, as when its Settings window is in front.
        public static let spinnet = App("Spinnet", bundleID: "com.vulpsecula.Spinnet")
    }

    /// One exit the Host performed.
    public struct Exit: Equatable {
        public let app: App
        public let exit: AppExit

        public init(app: App, exit: AppExit) {
            self.app = app
            self.exit = exit
        }
    }

    /// The App Targets the Host gave the Plugins under test.
    public let targets = AppTargets()
    public private(set) var front: App?
    /// Every exit performed, in order: a Close or Quit when the Host pressed
    /// the App's menu item, a Force Quit when it ended the App.
    public private(set) var exits: [Exit] = []
    /// Whether Spinnet may read and press other Apps' menus. Without it
    /// the Host offers and performs no Close or Quit.
    public var isAccessibilityTrusted = true
    public let ownProcessIdentifier: Int32 = 100
    private var running: [App: RunningAppIdentity] = [:]
    private var menus: [App: Set<AppExit>] = [:]
    private var nextProcessIdentifier: Int32 = 200
    private var launches = 0
    private var terminationObservers: [(RunningAppIdentity) -> Void] = []

    /// `front` in front, with `others` running behind it. The targets of an
    /// App that quits are forgotten as it quits, as in the Host.
    public init(front: App? = .textEdit, running others: [App] = []) {
        for app in others { launch(app) }
        bringToFront(front)
        targets.forgetTerminatedApps(of: self)
    }

    /// Brings `app` to the front, launching it when it is not running;
    /// nil leaves no App in front.
    public func bringToFront(_ app: App?) {
        if let app, running[app] == nil { launch(app) }
        front = app
    }

    /// `app`'s menu now offers `menu`, as when its last window closed and
    /// ⌘W was disabled.
    public func offer(_ menu: Set<AppExit>, in app: App) {
        menus[app] = menu.filter(\.isMenuItem)
    }

    /// `app` quits by itself.
    public func quit(_ app: App) {
        guard let identity = running.removeValue(forKey: app) else { return }
        if front == app { front = nil }
        terminationObservers.forEach { $0(identity) }
    }

    /// `app` quits and starts again, a new process the Host must not take
    /// for the old one, here even reusing its process ID.
    public func relaunch(_ app: App) {
        let reused = running[app]?.processIdentifier
        quit(app)
        launch(app, processIdentifier: reused)
    }

    public func isRunning(_ app: App) -> Bool { running[app] != nil }

    // MARK: RunningApps

    public func frontmost() -> RunningAppFacts? {
        guard let front, let identity = running[front] else { return nil }
        return RunningAppFacts(identity: identity, isRegular: front.isRegular)
    }

    public func facts(of app: RunningAppIdentity) -> RunningAppFacts? {
        guard let (recorded, identity) = running.first(where: { $0.value.isSameApp(as: app) }) else { return nil }
        return RunningAppFacts(identity: identity, isRegular: recorded.isRegular)
    }

    public func menuExits(of app: RunningAppIdentity) throws -> Set<AppExit> {
        guard isAccessibilityTrusted else { throw PluginHostServiceError.systemPermissionDenied(.accessibility) }
        return recorded(app).map { menus[$0] ?? $0.menu } ?? []
    }

    public func perform(_ exit: AppExit, on app: RunningAppIdentity) throws -> AppExitDelivery {
        if exit.isMenuItem, !isAccessibilityTrusted {
            throw PluginHostServiceError.systemPermissionDenied(.accessibility)
        }
        guard let recorded = recorded(app) else { return .failed }
        guard !exit.isMenuItem || (menus[recorded] ?? recorded.menu).contains(exit) else { return .notOffered }
        exits.append(Exit(app: recorded, exit: exit))
        // A recorded App quits at once; a real one may ask to save first.
        if exit != .close { quit(recorded) }
        return .delivered
    }

    public func observeTerminations(_ terminated: @escaping (RunningAppIdentity) -> Void) {
        terminationObservers.append(terminated)
    }

    private func recorded(_ app: RunningAppIdentity) -> App? {
        running.first(where: { $0.value.isSameApp(as: app) })?.key
    }

    private func launch(_ app: App, processIdentifier: Int32? = nil) {
        launches += 1
        menus[app] = nil
        let pid: Int32
        if app == .spinnet {
            pid = ownProcessIdentifier
        } else if let processIdentifier {
            pid = processIdentifier
        } else {
            nextProcessIdentifier += 1
            pid = nextProcessIdentifier
        }
        running[app] = RunningAppIdentity(processIdentifier: pid, bundleIdentifier: app.bundleID,
                                          launchDate: Date(timeIntervalSince1970: TimeInterval(launches)), name: app.name)
    }
}
