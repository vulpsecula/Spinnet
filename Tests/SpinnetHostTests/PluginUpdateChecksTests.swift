import Foundation
import SpinnetCore
import SpinnetTestSupport
import XCTest
@testable import SpinnetHost

/// General's automatic daily check, Check Now and the count of available
/// Plugin Updates, driven through the Host settings model against recorded
/// GitHub answers and a clock and timer the test controls.
final class PluginUpdateChecksTests: XCTestCase {
    /// One timer the model asked for.
    private final class Timer {
        let interval: TimeInterval
        private let block: () -> Void
        var cancelled = false
        private(set) var fired = false
        init(interval: TimeInterval, fire: @escaping () -> Void) {
            self.interval = interval
            block = fire
        }
        /// What the system timer does when its interval has passed.
        func fire() {
            fired = true
            block()
        }
    }

    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var grants: PluginCapabilityGrantStore!
    private var registry: PluginRegistry!
    private var store: PluginInstallationStore!
    private var transport: RecordedGitHubTransport!
    private var updater: PluginUpdater!
    private var settings: SettingsWindowModel!
    private var timers: [Timer] = []
    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    /// Seconds since this launch's settings model was made.
    private var uptime: TimeInterval = 0
    /// Background work held back until the test runs it, when `holdRuns`.
    private var holdRuns = false
    private var heldRuns: [() -> Void] = []
    private var priorities: [DispatchQoS.QoSClass] = []

    private let pluginID = PluginReleaseFixture.pluginID
    private let day: TimeInterval = 24 * 60 * 60
    private var updates: PluginUpdatesModel { settings.pluginUpdates }
    /// Timers neither cancelled nor fired, in the order asked for.
    private var liveTimers: [Timer] { timers.filter { !$0.cancelled && !$0.fired } }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = "PluginUpdateChecks." + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        grants = PluginCapabilityGrantStore()
        registry = PluginRegistry(grantStore: grants)
        store = PluginInstallationStore(directory: directory.appendingPathComponent("Installed"),
                                        registry: registry, grants: grants, persistGrants: {})
        transport = RecordedGitHubTransport()
        updater = PluginUpdater(store: store, registry: registry, transport: transport,
                                downloads: directory.appendingPathComponent("Downloads"))
        try store.install(from: PluginReleaseFixture.package(PluginReleaseFixture.manifest(version: "1.0.0"), in: directory))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
    }

    /// The settings model as one launch of the Host makes it.
    private func launch() throws {
        timers.removeAll()
        uptime = 0
        let configuration = try HostConfiguration(actions: [], menu: MenuConfiguration(slots: [.empty]))
        settings = SettingsWindowModel(editor: HostConfigurationEditor(registry: registry, configuration: configuration),
            metadata: .current, capabilityGrantStore: grants, defaults: defaults,
            accessibilityPermissionCheck: { true }, mouseInputConflictCheck: { _ in [] })
        settings.menuEditor.reviewPluginInstallation = { [store] in try store!.review($0) }
        settings.menuEditor.installPlugin = { [store] in try store!.install(from: $0) }
        settings.menuEditor.applyPluginUpdate = { [updater] in try updater!.apply($0) }
        updates.checkPluginUpdate = { [updater] in try updater!.check($0) }
        updates.checkPluginUpdates = { [updater] in updater!.checkAll($0, isCancelled: $1) }
        updates.runInBackground = { [unowned self] priority, work in
            priorities.append(priority)
            if holdRuns { heldRuns.append(work) } else { work() }
        }
        updates.deliver = { $0() }
        updates.now = { [unowned self] in now }
        updates.uptime = { [unowned self] in uptime }
        updates.scheduleCheck = { [unowned self] interval, fire in
            let timer = Timer(interval: interval, fire: fire)
            timers.append(timer)
            return { timer.cancelled = true }
        }
        updates.startAutomaticChecks()
    }

    private func publish(version: String) throws {
        let tag = "\(pluginID.rawValue)/v\(version)"
        try PluginReleaseFixture.publish([.init(tag: tag)], on: transport)
        transport.answer(PluginReleaseFixture.assetURL(tag: tag), body: try PluginReleaseFixture.zipped(
            PluginReleaseFixture.manifest(version: version), in: directory))
    }

    func testChecksAreOnByDefaultAndTheFirstWaitsUntilAfterLaunch() throws {
        try publish(version: "1.1.0")
        try launch()

        XCTAssertTrue(updates.checksAutomatically)
        XCTAssertEqual(transport.requests, [], "Nothing is asked at launch")
        XCTAssertEqual(liveTimers.map(\.interval), [PluginUpdatesModel.launchDelay], "A single timer")

        liveTimers[0].fire()

        XCTAssertEqual(transport.requestedURLs.first, PluginReleaseFixture.tagsURL)
        XCTAssertEqual(updates.availableUpdateCount, 1)
        XCTAssertEqual(updates.availableVersion(for: pluginID), "1.1.0", "The Library entry shows its Update action")
        XCTAssertEqual(updates.lastCheck, now)
        XCTAssertEqual(liveTimers.map(\.interval), [day], "The next check is a day later")
        XCTAssertEqual(registry.package(for: pluginID)?.manifest.version, "1.0.0", "Nothing installs by itself")
    }

    func testAutomaticChecksRunAtMostOnceADayAcrossLaunches() throws {
        try publish(version: "1.1.0")
        try launch()
        liveTimers[0].fire()
        let asked = transport.requests.count

        now += 2 * 60 * 60
        try launch()

        XCTAssertEqual(liveTimers.map(\.interval), [day - 2 * 60 * 60], "Due a day after the last check")
        now += 60
        liveTimers[0].fire()
        XCTAssertEqual(transport.requests.count, asked, "A timer that fires early asks for nothing")
        XCTAssertEqual(liveTimers.map(\.interval), [day - 2 * 60 * 60 - 60])

        now += day
        liveTimers[0].fire()
        XCTAssertGreaterThan(transport.requests.count, asked)
        XCTAssertEqual(updates.lastCheck, now)
    }

    func testTurningChecksOffStopsEveryAutomaticRequest() throws {
        try publish(version: "1.1.0")
        try launch()
        let pending = liveTimers[0]

        updates.checksAutomatically = false

        XCTAssertEqual(liveTimers.count, 0, "The scheduled check is cancelled")
        pending.fire()
        XCTAssertEqual(transport.requests, [])

        now += 3 * day
        try launch()
        XCTAssertFalse(updates.checksAutomatically, "The choice is kept across launches")
        XCTAssertEqual(timers.count, 0, "Nothing is scheduled")
        XCTAssertEqual(transport.requests, [])

        uptime = PluginUpdatesModel.launchDelay + 1
        updates.checksAutomatically = true
        XCTAssertEqual(liveTimers.map(\.interval), [0], "A check overdue when turned on runs now")
    }

    func testTurningChecksOnSoonAfterLaunchStillWaitsForTheLaunchDelay() throws {
        defaults.set(false, forKey: PluginUpdatesModel.checksAutomaticallyKey)
        try launch()
        uptime = 10

        updates.checksAutomatically = true

        XCTAssertEqual(liveTimers.map(\.interval), [PluginUpdatesModel.launchDelay - 10])
    }

    func testAnAutomaticCheckWithNothingToCheckStillSchedulesTheNextOne() throws {
        try store.uninstall(pluginID)
        try launch()

        liveTimers[0].fire()

        XCTAssertEqual(transport.requests, [])
        XCTAssertEqual(liveTimers.map(\.interval), [day], "Automatic checks go on")
    }

    func testTurningChecksOffStopsAnAutomaticCheckUnderWay() throws {
        try publish(version: "1.1.0")
        try launch()
        holdRuns = true
        liveTimers[0].fire()
        XCTAssertTrue(updates.isCheckingAll)

        updates.checksAutomatically = false
        heldRuns.removeFirst()()

        XCTAssertEqual(transport.requests, [], "Nothing is asked once checks are off")
        XCTAssertFalse(updates.isCheckingAll)
        XCTAssertNil(updates.runFailure)
        XCTAssertEqual(updates.status(for: pluginID), .notChecked)
    }

    func testTurningChecksOffLetsCheckNowFinish() throws {
        try publish(version: "1.1.0")
        try launch()
        holdRuns = true
        updates.checkNow()

        updates.checksAutomatically = false
        heldRuns.removeFirst()()

        XCTAssertEqual(updates.availableUpdateCount, 1)
    }

    func testAPluginBeingCheckedWithEveryPluginCannotBeCheckedAgainUntilItIsDone() throws {
        try publish(version: "1.1.0")
        try launch()
        holdRuns = true

        updates.checkNow()
        XCTAssertEqual(updates.status(for: pluginID), .checking)
        updates.checkForUpdate(pluginID)

        XCTAssertEqual(heldRuns.count, 1, "No second check of the Plugin starts")
        heldRuns.removeFirst()()
        XCTAssertEqual(updates.status(for: pluginID), .available)
    }

    func testOnlyAutomaticChecksRunAtLowPriority() throws {
        try publish(version: "1.1.0")
        try launch()

        liveTimers[0].fire()
        updates.checkNow()
        updates.checkForUpdate(pluginID)

        XCTAssertEqual(priorities, [.utility, .userInitiated, .userInitiated])
    }

    func testAClockChangeReschedulesTheNextCheck() throws {
        try publish(version: "1.1.0")
        try launch()
        uptime = PluginUpdatesModel.launchDelay
        liveTimers[0].fire()

        now += 2 * day
        NotificationCenter.default.post(name: .NSSystemClockDidChange, object: nil)

        XCTAssertEqual(liveTimers.map(\.interval), [0], "Overdue after the clock moved forward")
    }

    func testALastCheckAfterTheClockWasSetBackIsShownAsNow() throws {
        try publish(version: "1.1.0")
        try launch()
        liveTimers[0].fire()

        now -= day

        XCTAssertEqual(updates.shownLastCheck, now)
    }

    func testGeneralIsToldWhenTheInstalledPluginsChange() throws {
        try publish(version: "1.1.0")
        try launch()
        updates.checkNow()
        var changes = 0
        let observation = updates.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }

        updates.update(pluginID)
        settings.menuEditor.confirmPendingInstallation()

        XCTAssertGreaterThan(changes, 0, "Its count of available updates is shown again")
        XCTAssertEqual(updates.availableUpdateCount, 0)
    }

    func testCheckNowRunsEvenWhenAutomaticChecksAreOffAndCountsUpdates() throws {
        defaults.set(false, forKey: PluginUpdatesModel.checksAutomaticallyKey)
        try publish(version: "1.1.0")
        try launch()

        updates.checkNow()

        XCTAssertEqual(updates.availableUpdateCount, 1)
        XCTAssertEqual(updates.status(for: pluginID), .available)
        XCTAssertNil(updates.runFailure)
        XCTAssertEqual(timers.count, 0, "Check Now schedules no automatic check")

        updates.update(pluginID)
        settings.menuEditor.confirmPendingInstallation()

        XCTAssertEqual(registry.package(for: pluginID)?.manifest.version, "1.1.0")
        XCTAssertEqual(updates.availableUpdateCount, 0, "An applied update is no longer counted")
    }

    func testARateLimitIsReportedOnGeneralWithoutRetrying() throws {
        transport.answer(PluginReleaseFixture.tagsURL, status: 403, headers: ["x-ratelimit-remaining": "0"])
        try launch()

        liveTimers[0].fire()

        XCTAssertEqual(updates.runFailure, "GitHub's limit on update checks is reached. Try again later.")
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(liveTimers.map(\.interval), [day], "No retry before the next daily check")
        XCTAssertEqual(updates.availableUpdateCount, 0)

        try publish(version: "1.1.0")
        updates.checkNow()
        XCTAssertNil(updates.runFailure, "A later check that succeeds clears the report")
        XCTAssertEqual(updates.availableUpdateCount, 1)
    }

    func testAFailedRunKeepsAnUpdateAlreadyFound() throws {
        try publish(version: "1.1.0")
        try launch()
        updates.checkNow()

        transport.answer(PluginReleaseFixture.tagsURL, status: 429)
        updates.checkNow()

        XCTAssertEqual(updates.runFailure, "GitHub's limit on update checks is reached. Try again later.")
        XCTAssertEqual(updates.availableUpdateCount, 1)
        XCTAssertEqual(updates.availableVersion(for: pluginID), "1.1.0")
    }

    func testPluginsWithoutAnUpdateSourceAreNotChecked() throws {
        try store.uninstall(pluginID)
        try store.install(from: PluginReleaseFixture.package(
            PluginReleaseFixture.manifest(version: "1.0.0", updateSource: nil), in: directory))
        try launch()

        updates.checkNow()

        XCTAssertEqual(transport.requests, [])
        XCTAssertEqual(updates.availableUpdateCount, 0)
        XCTAssertFalse(updates.canCheckAll)
    }
}
