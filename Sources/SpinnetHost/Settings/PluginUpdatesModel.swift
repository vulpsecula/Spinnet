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
    static let launchDelay = DailyCheckSchedule.launchDelay
    static let checkInterval = DailyCheckSchedule.interval

    @Published private var entries: [PluginID: Entry] = [:]
    /// Whether every Plugin is checked once a day. Off, no automatic request
    /// is made at all.
    @Published var checksAutomatically: Bool {
        didSet {
            guard checksAutomatically != oldValue else { return }
            defaults.set(checksAutomatically, forKey: Self.checksAutomaticallyKey)
            // Off, an automatic check under way stops asking; Check Now does not.
            if !checksAutomatically, let run = currentRun, run.automatic { run.cancellation.cancel() }
            schedule.reschedule()
        }
    }
    /// When every Plugin was last checked, automatically or on request, kept
    /// across launches.
    var lastCheck: Date? { schedule.lastCheck }
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

    private let manifests: () -> [PluginManifest]
    private let defaults: UserDefaults
    private let schedule: DailyCheckSchedule
    /// The check of every Plugin under way, if any.
    private var currentRun: (automatic: Bool, cancellation: HostFetchedSections.Cancellation)?
    private var observations: [AnyCancellable] = []

    init(manifests: @escaping () -> [PluginManifest], defaults: UserDefaults) {
        self.manifests = manifests
        self.defaults = defaults
        schedule = DailyCheckSchedule(defaults: defaults, lastCheckKey: Self.lastCheckKey)
        checksAutomatically = defaults.object(forKey: Self.checksAutomaticallyKey) as? Bool ?? true
        schedule.isEnabled = { [unowned self] in self.checksAutomatically }
        schedule.onDue = { [unowned self] in self.checkAll(automatic: true) }
        schedule.willChange = { [unowned self] in self.objectWillChange.send() }
    }

    /// Re-reads the installed Plugins whenever `changes` emits, such as after
    /// the Library installs, updates or removes one, so General's count and
    /// Check Now are current.
    func observeInstalledPlugins<P: Publisher>(_ changes: P) where P.Failure == Never {
        changes.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
    }

    /// When every Plugin was last checked, never later than now: a check
    /// recorded before the clock was set back is shown as just made.
    var shownLastCheck: Date? { schedule.shownLastCheck }

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
            return Entry(installedVersion: installedVersion, status: .failed, message: localizedFailure(error))
        case .success(let check):
            // Refusals carry the version their tag names, highest first.
            let refused = check.refusals.map { localized("\($0.version) was refused: \($0.localizedReason)") }
            if let update = check.update {
                let message = HostLocalization.joiningSentences(
                    [localized("Version \(update.manifest.version) is available.")] + refused.prefix(1))
                return Entry(installedVersion: installedVersion, status: .available, message: message, offer: update)
            }
            if let refusal = check.refusals.first {
                return Entry(installedVersion: installedVersion, status: .refused,
                             message: localized("No acceptable update. \(refusal.version): \(refusal.localizedReason)"))
            }
            return Entry(installedVersion: installedVersion, status: .upToDate,
                         message: localized("\(check.installedVersion) is the latest version."))
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
        schedule.start()
    }

    /// Checks every Plugin that declares an Update Source and is not being
    /// checked already. Whatever happens, the next automatic check is
    /// scheduled.
    private func checkAll(automatic: Bool) {
        defer { schedule.reschedule() }
        guard !isCheckingAll else { return }
        let plugins = manifests().filter { $0.updateSource != nil && status(for: $0.id) != .checking }
        // Recorded with nothing to check too: it still counts as the day's check.
        schedule.recordCheck()
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
                failures.append((manifest(pluginID)?.name ?? pluginID.rawValue, localizedFailure(error)))
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
            runFailure = localizedFailure(stoppedBy)
        } else if failures.count == 1 {
            runFailure = localized("\(failures[0].name) could not be checked: \(failures[0].message)")
        } else if failures.count > 1 {
            runFailure = localized("\(failures.count) Plugins could not be checked. The Library shows why.")
        } else {
            runFailure = nil
        }
    }

    var accessibleNames: [String] {
        var names = [localized("Check for Plugin updates automatically"), localized("Check Now")]
        if let runFailure { names.append(runFailure) }
        return names
    }
}
