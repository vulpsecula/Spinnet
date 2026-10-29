import AppKit
import Foundation
import SpinnetCore
import SpinnetTestSupport
import XCTest
@testable import SpinnetHost

/// General's Spinnet release checks and the Status Item's entry for a newer
/// release, driven through the Host settings model against recorded GitHub
/// answers and a clock and timer the test controls.
final class SpinnetReleaseChecksTests: XCTestCase {
    private final class Timer {
        let interval: TimeInterval
        private let block: () -> Void
        var cancelled = false
        private(set) var fired = false
        init(interval: TimeInterval, fire: @escaping () -> Void) {
            self.interval = interval
            block = fire
        }
        func fire() {
            fired = true
            block()
        }
    }

    private let latestURL = "https://api.github.com/repos/vulpsecula/Spinnet/releases/latest"
    private let day: TimeInterval = 24 * 60 * 60
    private var defaults: UserDefaults!
    private var suite: String!
    private var transport: RecordedGitHubTransport!
    private var settings: SettingsWindowModel!
    private var timers: [Timer] = []
    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    private var uptime: TimeInterval = 0
    private var opened: [URL] = []
    private var releases: SpinnetReleaseChecksModel { settings.spinnetReleases }
    private var liveTimers: [Timer] { timers.filter { !$0.cancelled && !$0.fired } }

    override func setUpWithError() throws {
        suite = "SpinnetReleaseChecks." + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        transport = RecordedGitHubTransport()
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
    }

    /// The settings model as one launch of a Host of `running` makes it.
    private func launch(running: String = "1.0.0", developmentBuild: Bool = false) throws {
        timers.removeAll()
        uptime = 0
        let configuration = try HostConfiguration(actions: [], menu: MenuConfiguration(slots: [.empty]))
        settings = SettingsWindowModel(editor: HostConfigurationEditor(registry: PluginRegistry(), configuration: configuration),
            metadata: .current, defaults: defaults,
            accessibilityPermissionCheck: { true }, mouseInputConflictCheck: { _ in [] })
        let checker = SpinnetReleaseChecker(transport: transport, runningVersion: running)
        releases.runningVersion = running
        releases.isDevelopmentBuild = developmentBuild
        releases.checkRelease = { try checker.check() }
        releases.runInBackground = { _, work in work() }
        releases.deliver = { $0() }
        releases.now = { [unowned self] in now }
        releases.uptime = { [unowned self] in uptime }
        releases.openReleasePage = { [unowned self] in opened.append($0) }
        releases.scheduleCheck = { [unowned self] interval, fire in
            let timer = Timer(interval: interval, fire: fire)
            timers.append(timer)
            return { timer.cancelled = true }
        }
        releases.startAutomaticChecks()
    }

    private func publishLatest(tag: String) throws {
        transport.answer(latestURL, body: try JSONSerialization.data(withJSONObject: [
            "tag_name": tag, "draft": false, "prerelease": false,
            "html_url": "https://github.com/vulpsecula/Spinnet/releases/tag/\(tag)"
        ] as [String: Any]))
    }

    private var generalNames: [String] {
        settings.selectPage(.general)
        return settings.accessibleNames
    }

    func testAReleaseBuildChecksDailyAfterLaunchAndShowsANewerRelease() throws {
        try publishLatest(tag: "v1.2.0")
        try launch()

        XCTAssertTrue(releases.checksAutomatically, "On by default")
        XCTAssertEqual(transport.requests, [], "Nothing is asked at launch")
        XCTAssertEqual(liveTimers.map(\.interval), [SpinnetReleaseChecksModel.launchDelay], "A single timer")

        liveTimers[0].fire()

        XCTAssertEqual(transport.requestedURLs, [latestURL])
        XCTAssertEqual(releases.availableRelease?.version, "1.2.0")
        XCTAssertTrue(generalNames.contains("Spinnet 1.2.0 is available."))
        XCTAssertTrue(generalNames.contains("View Release"))
        XCTAssertEqual(liveTimers.map(\.interval), [day], "The next check is a day later")

        releases.openAvailableRelease()
        XCTAssertEqual(opened, [URL(string: "https://github.com/vulpsecula/Spinnet/releases/tag/v1.2.0")!],
                       "It links to the release page and downloads nothing")
    }

    func testADevelopmentBuildSaysSoAndChecksOnlyWhenAsked() throws {
        try publishLatest(tag: "v1.2.0")
        try launch(developmentBuild: true)

        XCTAssertEqual(timers.count, 0, "Nothing is scheduled")
        XCTAssertTrue(generalNames.contains(SpinnetReleaseChecksModel.developmentBuildNote))
        releases.checksAutomatically = false
        releases.checksAutomatically = true
        XCTAssertEqual(timers.count, 0, "Turning checks on schedules nothing either")
        XCTAssertEqual(transport.requests, [])

        releases.checkNow()

        XCTAssertEqual(transport.requestedURLs, [latestURL], "Check Now asks at once")
        XCTAssertEqual(releases.availableRelease?.version, "1.2.0")
        XCTAssertEqual(timers.count, 0)
    }

    func testAFailureOrRateLimitIsReportedOnGeneralAndNotRetriedBeforeTheNextCheck() throws {
        transport.answer(latestURL, status: 403, headers: ["X-RateLimit-Remaining": "0"])
        try launch()
        liveTimers[0].fire()

        let message = "GitHub's limit on update checks is reached. Try again later."
        XCTAssertEqual(releases.status, .failed(message))
        XCTAssertTrue(generalNames.contains(message))
        XCTAssertEqual(liveTimers.map(\.interval), [day], "No retry before the next daily check")
        XCTAssertEqual(transport.requests.count, 1)

        try publishLatest(tag: "v1.2.0")
        releases.checkNow()
        transport.answer(latestURL)
        releases.checkNow()

        XCTAssertEqual(releases.availableRelease?.version, "1.2.0", "A failed check keeps a release already found")
        XCTAssertTrue(generalNames.contains("Spinnet 1.2.0 is available."))
        XCTAssertTrue(generalNames.contains("GitHub's newest Spinnet release could not be read: it is not a release."))
    }

    func testTheRunningVersionIsUpToDateWithTheNewestRelease() throws {
        try publishLatest(tag: "v1.0.0")
        try launch()

        releases.checkNow()

        XCTAssertEqual(releases.status, .upToDate(latest: "1.0.0"))
        XCTAssertNil(releases.availableRelease)
        XCTAssertTrue(releases.summary.hasPrefix("Spinnet 1.0.0 is up to date."))
    }

    func testGeneralSaysWhenItLastCheckedAndWhyItFailedInTheInterfaceLanguage() throws {
        try publishLatest(tag: "v1.0.0")
        try launch()
        releases.checkNow()

        try HostLocalization.withLanguage(.simplifiedChinese) {
            let summary = releases.summary
            XCTAssertTrue(summary.hasPrefix("Spinnet 1.0.0 已是最新版本。上次检查："), summary)
            XCTAssertTrue(summary.hasSuffix("。"), summary)

            transport.answer(latestURL, status: 429)
            releases.checkNow()
            XCTAssertEqual(releases.shownFailure, "GitHub 的更新检查次数已达上限。请稍后再试。")
        }
        XCTAssertEqual(releases.summary, "The last check did not complete.")
    }

    func testARunningVersionThatIsNotSemVerIsReportedAsAFailedCheck() throws {
        try publishLatest(tag: "v1.2.0")
        try launch(running: "dev-build")

        releases.checkNow()

        XCTAssertEqual(releases.status,
                       .failed("This Spinnet's version, dev-build, is not a SemVer version, so it cannot be compared."))
        XCTAssertTrue(generalNames.contains("This Spinnet's version, dev-build, is not a SemVer version, so it cannot be compared."))
    }

    func testANewerReleaseIsKeptAcrossLaunchesUntilItIsInstalled() throws {
        try publishLatest(tag: "v1.2.0")
        try launch()
        releases.checkNow()

        try launch()
        XCTAssertEqual(releases.availableRelease?.version, "1.2.0", "Still shown after a relaunch")

        try launch(running: "1.2.0")
        XCTAssertNil(releases.availableRelease, "Gone once that version runs")
    }

    func testTurningChecksOffStopsAutomaticRequestsAndIsKept() throws {
        try publishLatest(tag: "v1.2.0")
        try launch()
        let pending = liveTimers[0]

        releases.checksAutomatically = false

        XCTAssertEqual(liveTimers.count, 0)
        pending.fire()
        XCTAssertEqual(transport.requests, [])
        try launch()
        XCTAssertFalse(releases.checksAutomatically)
        XCTAssertEqual(timers.count, 0)
    }

    func testTheStatusItemOffersANewerReleaseThatOpensItsReleasePage() throws {
        _ = NSApplication.shared
        try publishLatest(tag: "v1.2.0")
        try launch()
        let controller = StatusItemController(openSettings: {}, quit: {}, releases: releases)
        let title = "Spinnet 1.2.0 Is Available…"
        XCTAssertFalse(controller.makeMenu().items.map(\.title).contains(title))

        releases.checkNow()

        let menu = controller.makeMenu()
        let item = try XCTUnwrap(menu.items.first { $0.title == title })
        XCTAssertEqual(menu.items.first?.title, title, "Listed first")
        let action = try XCTUnwrap(item.action)
        XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item))
        XCTAssertEqual(opened, [URL(string: "https://github.com/vulpsecula/Spinnet/releases/tag/v1.2.0")!])
    }
}
