import Combine
import Foundation

/// When an automatic check that runs at most once a day across launches is
/// due, and where a check runs. It keeps a single timer for the next due
/// check, never sooner than `launchDelay` after launch, records when the
/// last check started, and follows clock changes. General's Plugin Update
/// checks and Spinnet release checks each keep one.
final class DailyCheckSchedule {
    /// How long after launch an overdue automatic check waits, so it never
    /// competes with starting up.
    static let launchDelay: TimeInterval = 60
    static let interval: TimeInterval = 24 * 60 * 60

    /// When the last check started, automatically or on request, kept
    /// across launches.
    private(set) var lastCheck: Date?
    /// Whether automatic checks run now; asked whenever one is scheduled or
    /// fires.
    var isEnabled: () -> Bool = { true }
    /// Runs the automatic check once it is due.
    var onDue: () -> Void = {}
    /// Called just before `lastCheck` changes, so its owner can republish.
    var willChange: () -> Void = {}

    /// Where a check runs, off the main thread, at the given priority:
    /// `.utility` for an automatic check, `.userInitiated` for one the user
    /// asked for. `deliver` is where its result lands.
    var runInBackground: (DispatchQoS.QoSClass, @escaping () -> Void) -> Void = { priority, work in
        DispatchQueue.global(qos: priority).async(execute: work)
    }
    var deliver: (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }
    var now: () -> Date = Date.init
    /// A clock that only moves forward, for how long ago the Host launched.
    var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Runs `fire` once after an interval and returns how to cancel it. At
    /// most one is kept, for the next due check.
    var scheduleCheck: (TimeInterval, @escaping () -> Void) -> () -> Void = { interval, fire in
        // Wall-clock time, so a Mac that slept still checks when due.
        let item = DispatchWorkItem(block: fire)
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + interval, execute: item)
        return item.cancel
    }

    private let defaults: UserDefaults
    private let lastCheckKey: String
    private var cancelScheduledCheck: (() -> Void)?
    /// `uptime` when automatic checks started, at launch.
    private var launchedAt: TimeInterval?
    private var observations: [AnyCancellable] = []

    init(defaults: UserDefaults, lastCheckKey: String) {
        self.defaults = defaults
        self.lastCheckKey = lastCheckKey
        lastCheck = defaults.object(forKey: lastCheckKey) as? Date
        // When the user or the network changes the clock, the next check is
        // due at another wall-clock time.
        NotificationCenter.default.publisher(for: .NSSystemClockDidChange)
            .sink { [weak self] _ in
                let reschedule = { [weak self] in
                    guard let self, self.hasStarted else { return }
                    self.reschedule()
                }
                if Thread.isMainThread { reschedule() } else { DispatchQueue.main.async(execute: reschedule) }
            }
            .store(in: &observations)
    }

    /// Whether automatic checks have started, at launch.
    var hasStarted: Bool { launchedAt != nil }

    /// When the last check started, never later than now: a check recorded
    /// before the clock was set back is shown as just made.
    var shownLastCheck: Date? { lastCheck.map { min($0, now()) } }

    /// Called once at launch. Asks for nothing until a check is due, and
    /// then not before `launchDelay` has passed since launch.
    func start() {
        launchedAt = uptime()
        reschedule()
    }

    /// Records that a check starts now, before asking, so a check cut short
    /// by quitting still counts as the day's check.
    func recordCheck() {
        let started = now()
        willChange()
        lastCheck = started
        defaults.set(started, forKey: lastCheckKey)
    }

    /// Replaces the one timer with one for the next due check, never sooner
    /// than `launchDelay` after launch.
    func reschedule() {
        cancelScheduledCheck?()
        cancelScheduledCheck = nil
        guard isEnabled() else { return }
        let wait = max(due.timeIntervalSince(now()), Self.launchDelay - (launchedAt.map { uptime() - $0 } ?? 0), 0)
        cancelScheduledCheck = scheduleCheck(wait) { [weak self] in self?.fired() }
    }

    /// A last check in the future, after the clock was set back, counts as now.
    private var due: Date {
        let now = now()
        return lastCheck.map { min($0, now) + Self.interval } ?? now
    }

    private func fired() {
        cancelScheduledCheck = nil
        guard isEnabled() else { return }
        guard now() >= due else { return reschedule() }
        onDue()
    }
}
