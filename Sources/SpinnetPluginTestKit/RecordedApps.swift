import Foundation
import SpinnetCore

/// Recorded running Apps for `apps.frontmost` and `apps.quit` (#83), in
/// place of the desktop: which App is in front, which Apps run, and the
/// exits the Host performed. Give it to `RecordedHostServices(apps:)` to
/// answer `apps.frontmost` and to `RecordedHostOperations(apps:)` to perform
/// `apps.quit`; both then follow the Host's own rules, with the Host's App
/// Targets, protection and identity checks, so a target outlives neither
/// its App nor a relaunch.
public final class RecordedApps: RunningApps {
    /// A recorded App, by what a user sees of it.
    public struct App: Hashable {
        public let name: String
        public let bundleID: String?
        /// False for an agent or background-only process.
        public let isRegular: Bool

        public init(_ name: String, bundleID: String?, isRegular: Bool = true) {
            self.name = name
            self.bundleID = bundleID
            self.isRegular = isRegular
        }

        public static let textEdit = App("TextEdit", bundleID: "com.apple.TextEdit")
        public static let safari = App("Safari", bundleID: "com.apple.Safari")
        public static let finder = App("Finder", bundleID: "com.apple.finder")
        public static let dock = App("Dock", bundleID: "com.apple.dock", isRegular: false)
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
    /// Every exit performed, in order.
    public private(set) var exits: [Exit] = []
    public let ownProcessIdentifier: Int32 = 100
    private var running: [App: RunningAppIdentity] = [:]
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

    public func perform(_ exit: AppExit, on app: RunningAppIdentity) -> Bool {
        guard let recorded = running.first(where: { $0.value.isSameApp(as: app) })?.key else { return false }
        exits.append(Exit(app: recorded, exit: exit))
        quit(recorded)
        return true
    }

    public func observeTerminations(_ terminated: @escaping (RunningAppIdentity) -> Void) {
        terminationObservers.append(terminated)
    }

    private func launch(_ app: App, processIdentifier: Int32? = nil) {
        launches += 1
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
