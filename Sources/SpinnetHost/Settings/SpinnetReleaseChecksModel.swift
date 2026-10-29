import AppKit
import Combine
import Foundation
import SpinnetCore

/// Spinnet release checks: General's daily automatic check and Check Now of
/// the Spinnet repository's newest release. A newer release is shown on
/// General and in the Status Item, which link to its release page; nothing
/// is ever downloaded or installed. A development build says so and does not
/// check automatically. A failure is reported on General only, and is not
/// retried before the next check.
final class SpinnetReleaseChecksModel: ObservableObject {
    enum Status: Equatable {
        case notChecked
        case checking
        case upToDate(latest: String?)
        case available(SpinnetRelease)
        case failed(String)
    }

    static let checksAutomaticallyKey = "spinnet-releases.check-automatically"
    static let lastCheckKey = "spinnet-releases.last-check"
    static let availableVersionKey = "spinnet-releases.available-version"
    static let availablePageKey = "spinnet-releases.available-page"
    static let launchDelay = DailyCheckSchedule.launchDelay
    static let checkInterval = DailyCheckSchedule.interval

    /// Whether Spinnet checks once a day. Off, or in a development build, no
    /// automatic request is made.
    @Published var checksAutomatically: Bool {
        didSet {
            guard checksAutomatically != oldValue else { return }
            defaults.set(checksAutomatically, forKey: Self.checksAutomaticallyKey)
            if schedule.hasStarted { schedule.reschedule() }
        }
    }
    @Published private(set) var status: Status = .notChecked
    /// Why the last check failed while an earlier newer release is still shown.
    @Published private(set) var failure: String?
    /// When Spinnet was last checked, kept across launches.
    var lastCheck: Date? { schedule.lastCheck }

    /// The running Spinnet version, compared with a newer release kept from
    /// an earlier launch.
    var runningVersion = HostVersion.currentString {
        didSet { forgetAvailableReleaseIfApplied() }
    }
    /// A development build never checks automatically; Check Now still works.
    var isDevelopmentBuild: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()
    /// Asks GitHub for the newest release; it reaches the network.
    var checkRelease: (() throws -> SpinnetReleaseCheck)?
    var openReleasePage: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Where a check runs and lands, and the clocks and timer of the daily
    /// check; see `DailyCheckSchedule`.
    var runInBackground: (DispatchQoS.QoSClass, @escaping () -> Void) -> Void {
        get { schedule.runInBackground } set { schedule.runInBackground = newValue }
    }
    var deliver: (@escaping () -> Void) -> Void {
        get { schedule.deliver } set { schedule.deliver = newValue }
    }
    var now: () -> Date { get { schedule.now } set { schedule.now = newValue } }
    var uptime: () -> TimeInterval { get { schedule.uptime } set { schedule.uptime = newValue } }
    var scheduleCheck: (TimeInterval, @escaping () -> Void) -> () -> Void {
        get { schedule.scheduleCheck } set { schedule.scheduleCheck = newValue }
    }

    private let defaults: UserDefaults
    private let schedule: DailyCheckSchedule

    init(defaults: UserDefaults) {
        self.defaults = defaults
        schedule = DailyCheckSchedule(defaults: defaults, lastCheckKey: Self.lastCheckKey)
        checksAutomatically = defaults.object(forKey: Self.checksAutomaticallyKey) as? Bool ?? true
        if let version = defaults.string(forKey: Self.availableVersionKey),
           let page = defaults.string(forKey: Self.availablePageKey).flatMap(URL.init(string:)) {
            status = .available(SpinnetRelease(version: version, page: page))
        }
        forgetAvailableReleaseIfApplied()
        schedule.isEnabled = { [unowned self] in self.checksDaily }
        schedule.onDue = { [unowned self] in self.check(automatic: true) }
        schedule.willChange = { [unowned self] in self.objectWillChange.send() }
    }

    /// The newer release shown on General and in the Status Item, if any.
    var availableRelease: SpinnetRelease? {
        if case .available(let release) = status { return release }
        return nil
    }

    var isChecking: Bool { status == .checking }

    /// Whether automatic checks actually run.
    var checksDaily: Bool { checksAutomatically && !isDevelopmentBuild }

    /// When Spinnet was last checked, never later than now.
    var shownLastCheck: Date? { schedule.shownLastCheck }

    func openAvailableRelease() {
        guard let availableRelease else { return }
        openReleasePage(availableRelease.page)
    }

    /// General's Check Now.
    func checkNow() {
        check(automatic: false)
    }

    /// Called once at launch. Asks for nothing until a check is due, and
    /// then not before `launchDelay` has passed since launch.
    func startAutomaticChecks() {
        schedule.start()
    }

    /// Whatever happens, the next automatic check is scheduled; a failure is
    /// not retried sooner.
    private func check(automatic: Bool) {
        defer { if schedule.hasStarted { schedule.reschedule() } }
        guard !isChecking, let checkRelease else { return }
        schedule.recordCheck()
        let previous = status
        status = .checking
        runInBackground(automatic ? .utility : .userInitiated) { [weak self] in
            let result = Result { try checkRelease() }
            self?.deliver { self?.finish(result, previous: previous) }
        }
    }

    private func finish(_ result: Result<SpinnetReleaseCheck, Error>, previous: Status) {
        switch result {
        case .success(.newer(let release)):
            status = .available(release)
        case .success(.upToDate(let latest)):
            status = .upToDate(latest: latest)
        case .failure(let error):
            // A failed check does not take away a release already found; it
            // is still reported.
            if case .available = previous { status = previous; failure = localizedFailure(error); return }
            status = .failed(localizedFailure(error))
        }
        failure = nil
        keepAvailableRelease()
    }

    /// Kept across launches, so the newer release stays shown until the
    /// next check or until it is installed.
    private func keepAvailableRelease() {
        if let availableRelease {
            defaults.set(availableRelease.version, forKey: Self.availableVersionKey)
            defaults.set(availableRelease.page.absoluteString, forKey: Self.availablePageKey)
        } else {
            defaults.removeObject(forKey: Self.availableVersionKey)
            defaults.removeObject(forKey: Self.availablePageKey)
        }
    }

    private func forgetAvailableReleaseIfApplied() {
        guard let availableRelease,
              let running = try? PluginVersion(runningVersion),
              let available = try? PluginVersion(availableRelease.version),
              available <= running else { return }
        status = .notChecked
        keepAvailableRelease()
    }

    /// What General says about the last check.
    var summary: String {
        switch status {
        case .notChecked: return localized("Not checked yet.")
        case .checking: return localized("Checking for Spinnet updates…")
        case .upToDate(let latest):
            let base = latest == nil ? localized("No Spinnet release is published yet.") : localized("Spinnet \(runningVersion) is up to date.")
            guard let last = shownLastCheck else { return base }
            let relative = last.formatted(.relative(presentation: .named).locale(HostLocalization.locale))
            return HostLocalization.joiningSentences([base, localized("Last checked \(relative).")])
        case .available(let release): return localized("Spinnet \(release.version) is available.")
        case .failed: return localized("The last check did not complete.")
        }
    }

    /// Why the last check did not complete, shown on General only.
    var shownFailure: String? {
        if case .failed(let message) = status { return message }
        return failure
    }

    static var developmentBuildNote: String { localized("This development build does not check automatically. Use Check Now.") }

    var accessibleNames: [String] {
        var names = [localized("Check for Spinnet updates automatically"), localized("Check Now for Spinnet updates")]
        if isDevelopmentBuild { names.append(Self.developmentBuildNote) }
        if let availableRelease { names.append(contentsOf: [localized("Spinnet \(availableRelease.version) is available."), localized("View Release")]) }
        if let shownFailure { names.append(shownFailure) }
        return names
    }
}
