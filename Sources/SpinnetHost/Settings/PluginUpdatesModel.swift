import Combine
import Foundation
import SpinnetCore

/// Plugin Update checks: the Library's Check for Update and Update for each
/// Plugin that declares an Update Source, and General's daily automatic check
/// and Check Now of every such Plugin. A check installs nothing; Update hands
/// the accepted version to the Library's installation review. A refused or
/// failed check says why, and the installed version keeps working.
final class PluginUpdatesModel: ObservableObject {
    enum Status: Equatable {
        case notChecked
        case checking
        case upToDate
        case available
        case refused
        case failed
    }

    private struct Entry {
        /// The installed version the check was made for.
        let installedVersion: String?
        var status: Status
        var message: String?
        var offer: PluginUpdateOffer?
    }

    static let checksAutomaticallyKey = "plugin-updates.check-automatically"
    static let lastCheckKey = "plugin-updates.last-check"
    /// How long after launch an overdue automatic check waits, so it never
    /// competes with starting up.
    static let launchDelay: TimeInterval = 60
    static let checkInterval: TimeInterval = 24 * 60 * 60

    @Published private var entries: [PluginID: Entry] = [:]
    /// Whether every Plugin is checked once a day. Off, no automatic request
    /// is made at all.
    @Published var checksAutomatically: Bool {
        didSet {
            guard checksAutomatically != oldValue else { return }
            defaults.set(checksAutomatically, forKey: Self.checksAutomaticallyKey)
            // Off, an automatic check under way stops asking; Check Now does not.
            if !checksAutomatically, let run = currentRun, run.automatic { run.cancellation.cancel() }
            scheduleNextCheck()
        }
    }
    /// When every Plugin was last checked, automatically or on request, kept
    /// across launches.
    @Published private(set) var lastCheck: Date?
    @Published private(set) var isCheckingAll = false
    /// Why the last check of every Plugin did not complete for all of them.
    @Published private(set) var runFailure: String?

    /// Checks one Plugin's Update Source; it reaches the network.
    var checkPluginUpdate: ((PluginID) throws -> PluginUpdateCheck)?
    /// Checks several Plugins at once; it reaches the network and stops
    /// asking once the second argument answers true.
    var checkPluginUpdates: (([PluginID], @escaping () -> Bool) -> PluginUpdateRun)?
    /// Starts the Library's installation review for an accepted version.
    var startUpdate: ((PluginUpdateOffer) -> Void)?
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
    /// Runs `fire` once after an interval and returns how to cancel it. The
    /// model keeps at most one, for the next due check.
    var scheduleCheck: (TimeInterval, @escaping () -> Void) -> () -> Void = { interval, fire in
        // Wall-clock time, so a Mac that slept still checks when due.
        let item = DispatchWorkItem(block: fire)
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + interval, execute: item)
        return item.cancel
    }

    private let manifests: () -> [PluginManifest]
    private let defaults: UserDefaults
    private var cancelScheduledCheck: (() -> Void)?
    /// `uptime` when automatic checks started, at launch.
    private var launchedAt: TimeInterval?
    /// The check of every Plugin under way, if any.
    private var currentRun: (automatic: Bool, cancellation: HostFetchedSections.Cancellation)?
    private var observations: [AnyCancellable] = []

    init(manifests: @escaping () -> [PluginManifest], defaults: UserDefaults) {
        self.manifests = manifests
        self.defaults = defaults
        checksAutomatically = defaults.object(forKey: Self.checksAutomaticallyKey) as? Bool ?? true
        lastCheck = defaults.object(forKey: Self.lastCheckKey) as? Date
        // When the user or the network changes the clock, the next check is
        // due at another wall-clock time.
        NotificationCenter.default.publisher(for: .NSSystemClockDidChange)
            .sink { [weak self] _ in
                let reschedule = { [weak self] in
                    guard let self, self.launchedAt != nil else { return }
                    self.scheduleNextCheck()
                }
                if Thread.isMainThread { reschedule() } else { DispatchQueue.main.async(execute: reschedule) }
            }
            .store(in: &observations)
    }

    /// Re-reads the installed Plugins whenever `changes` emits, such as after
    /// the Library installs, updates or removes one, so General's count and
    /// Check Now are current.
    func observeInstalledPlugins<P: Publisher>(_ changes: P) where P.Failure == Never {
        changes.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
    }

    /// When every Plugin was last checked, never later than now: a check
    /// recorded before the clock was set back is shown as just made.
    var shownLastCheck: Date? { lastCheck.map { min($0, now()) } }

    private func manifest(_ pluginID: PluginID) -> PluginManifest? {
        manifests().first { $0.id == pluginID }
    }

    /// Whether the Library shows update controls for the Plugin.
    func offersUpdates(for pluginID: PluginID) -> Bool {
        manifest(pluginID)?.updateSource != nil
    }

    /// A result about a version that is no longer installed, such as after the
    /// update was applied, no longer applies.
    private func entry(for pluginID: PluginID) -> Entry? {
        guard let entry = entries[pluginID], entry.installedVersion == manifest(pluginID)?.version else { return nil }
        return entry
    }

    func status(for pluginID: PluginID) -> Status { entry(for: pluginID)?.status ?? .notChecked }
    func message(for pluginID: PluginID) -> String? { entry(for: pluginID)?.message }
    func availableVersion(for pluginID: PluginID) -> String? { entry(for: pluginID)?.offer?.manifest.version }

    /// How many installed Plugins have an update waiting to be applied.
    var availableUpdateCount: Int {
        manifests().filter { status(for: $0.id) == .available }.count
    }

    /// Whether any installed Plugin declares an Update Source.
    var canCheckAll: Bool { manifests().contains { $0.updateSource != nil } }

    func checkForUpdate(_ pluginID: PluginID) {
        guard offersUpdates(for: pluginID), status(for: pluginID) != .checking, let checkPluginUpdate else { return }
        let installed = manifest(pluginID)?.version
        entries[pluginID] = Entry(installedVersion: installed, status: .checking)
        runInBackground(.userInitiated) { [weak self] in
            let result = Result { try checkPluginUpdate(pluginID) }
            self?.deliver {
                self?.entries[pluginID] = Self.entry(for: result, installedVersion: installed)
            }
        }
    }

    private static func entry(for result: Result<PluginUpdateCheck, Error>, installedVersion: String?) -> Entry {
        switch result {
        case .failure(let error):
            return Entry(installedVersion: installedVersion, status: .failed, message: error.localizedDescription)
        case .success(let check):
            // Refusals carry the version their tag names, highest first.
            let refused = check.refusals.map { "\($0.version) was refused: \($0.reason)" }
            if let update = check.update {
                let message = (["Version \(update.manifest.version) is available."] + refused.prefix(1)).joined(separator: " ")
                return Entry(installedVersion: installedVersion, status: .available, message: message, offer: update)
            }
            if let refusal = check.refusals.first {
                return Entry(installedVersion: installedVersion, status: .refused,
                             message: "No acceptable update. \(refusal.version): \(refusal.reason)")
            }
            return Entry(installedVersion: installedVersion, status: .upToDate,
                         message: "\(check.installedVersion) is the latest version.")
        }
    }

    /// Applies the version the last check accepted, after the Library's review.
    func update(_ pluginID: PluginID) {
        guard let offer = entry(for: pluginID)?.offer else { return }
        startUpdate?(offer)
    }

    // MARK: - Checking every Plugin

    /// General's Check Now and the Library's Check All for Updates.
    func checkNow() {
        checkAll(automatic: false)
    }

    /// Called once at launch. Asks for nothing until a check is due, and
    /// then not before `launchDelay` has passed since launch.
    func startAutomaticChecks() {
        launchedAt = uptime()
        scheduleNextCheck()
    }

    /// Replaces the one timer with one for the next due check, never sooner
    /// than `launchDelay` after launch.
    private func scheduleNextCheck() {
        cancelScheduledCheck?()
        cancelScheduledCheck = nil
        guard checksAutomatically else { return }
        let now = now()
        // A last check in the future, after the clock was set back, counts as now.
        let due = lastCheck.map { min($0, now) + Self.checkInterval } ?? now
        let sinceLaunch = launchedAt.map { uptime() - $0 } ?? 0
        let wait = max(due.timeIntervalSince(now), Self.launchDelay - sinceLaunch, 0)
        cancelScheduledCheck = scheduleCheck(wait) { [weak self] in self?.automaticCheckFired() }
    }

    private func automaticCheckFired() {
        cancelScheduledCheck = nil
        guard checksAutomatically else { return }
        let due = lastCheck.map { min($0, now()) + Self.checkInterval } ?? now()
        guard now() >= due else { return scheduleNextCheck() }
        checkAll(automatic: true)
    }

    /// Checks every Plugin that declares an Update Source and is not being
    /// checked already. Whatever happens, the next automatic check is
    /// scheduled.
    private func checkAll(automatic: Bool) {
        defer { scheduleNextCheck() }
        guard !isCheckingAll else { return }
        let plugins = manifests().filter { $0.updateSource != nil && status(for: $0.id) != .checking }
        // Recorded before asking, so a run cut short by quitting, or with
        // nothing to check, still counts as the day's check.
        let started = now()
        lastCheck = started
        defaults.set(started, forKey: Self.lastCheckKey)
        guard !plugins.isEmpty, let checkPluginUpdates else { return }
        let installedVersions = Dictionary(plugins.map { ($0.id, $0.version) }, uniquingKeysWith: { first, _ in first })
        // Each Plugin shows it is being checked, so its own Check for Update
        // cannot start a second check of it meanwhile.
        var previous: [PluginID: Entry] = [:]
        for plugin in plugins {
            previous[plugin.id] = entry(for: plugin.id)
            entries[plugin.id] = Entry(installedVersion: plugin.version, status: .checking)
        }
        let cancellation = HostFetchedSections.Cancellation()
        currentRun = (automatic, cancellation)
        isCheckingAll = true
        runInBackground(automatic ? .utility : .userInitiated) { [weak self] in
            let run = checkPluginUpdates(plugins.map(\.id), { cancellation.isCancelled })
            self?.deliver { self?.finish(run, installedVersions: installedVersions, previous: previous) }
        }
    }

    private func finish(_ run: PluginUpdateRun, installedVersions: [PluginID: String], previous: [PluginID: Entry]) {
        isCheckingAll = false
        currentRun = nil
        var failures: [(name: String, message: String)] = []
        var checked: Set<PluginID> = []
        for (pluginID, result) in run.results {
            checked.insert(pluginID)
            let installed = installedVersions[pluginID]
            if case .failure(let error) = result {
                failures.append((manifest(pluginID)?.name ?? pluginID.rawValue, error.localizedDescription))
                // A failed run does not take away an update already found.
                if let entry = previous[pluginID], entry.installedVersion == installed, entry.status == .available {
                    entries[pluginID] = entry
                    continue
                }
            }
            entries[pluginID] = Self.entry(for: result, installedVersion: installed)
        }
        // A Plugin the run did not get to, because it was stopped, shows
        // what it showed before.
        for pluginID in installedVersions.keys where !checked.contains(pluginID) {
            entries[pluginID] = previous[pluginID]
        }
        if run.cancelled && run.stoppedBy == nil && failures.isEmpty { return }
        if let stoppedBy = run.stoppedBy {
            runFailure = stoppedBy.localizedDescription
        } else if failures.count == 1 {
            runFailure = "\(failures[0].name) could not be checked: \(failures[0].message)"
        } else if failures.count > 1 {
            runFailure = "\(failures.count) Plugins could not be checked. The Library shows why."
        } else {
            runFailure = nil
        }
    }

    var accessibleNames: [String] {
        var names = ["Check for Plugin updates automatically", "Check Now"]
        if let runFailure { names.append(runFailure) }
        return names
    }
}
