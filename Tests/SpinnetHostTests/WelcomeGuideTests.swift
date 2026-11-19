import XCTest
import SpinnetCore
@testable import SpinnetHost

/// The Welcome Guide's show, skip and complete rules, driven through the
/// Settings window model the Host builds at launch.
final class WelcomeGuideTests: XCTestCase {
    private var suiteName = ""
    private var defaults = UserDefaults.standard

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "SpinnetHostTests.WelcomeGuide.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func emptyEditor() throws -> HostConfigurationEditor {
        HostConfigurationEditor(
            registry: PluginRegistry(),
            configuration: try HostConfiguration(actions: [], menu: MenuConfiguration(slots: [.empty]))
        )
    }

    /// A launch of the Host with this saved data.
    private func launch(withPlugins: Bool = false,
                        accessibilityGranted: @escaping () -> Bool = { false }) throws -> SettingsWindowModel {
        let launched = try model(withPlugins: withPlugins, accessibilityGranted: accessibilityGranted)
        launched.openAtLaunch()
        return launched
    }

    /// The Settings model a launch builds, before it decides what to show.
    private func model(withPlugins: Bool = false,
                       accessibilityGranted: @escaping () -> Bool = { false }) throws -> SettingsWindowModel {
        SettingsWindowModel(
            editor: withPlugins ? try makeEditor() : try emptyEditor(),
            metadata: .current,
            defaults: defaults,
            accessibilityPermissionCheck: accessibilityGranted,
            mouseInputConflictCheck: { _ in [] }
        )
    }

    func testAFirstLaunchWithNoPluginInstalledOpensTheGuideAtWelcome() throws {
        let model = try launch()

        XCTAssertTrue(model.welcomeGuide.isPresented)
        XCTAssertEqual(model.welcomeGuide.step, .welcome)
    }

    func testALaunchWithAPluginInstalledDoesNotOpenTheGuide() throws {
        XCTAssertFalse(try launch(withPlugins: true).welcomeGuide.isPresented)
    }

    func testTheGuideStepsThroughPermissionsTheMenuTriggerAndOfficialPluginsToTheFinish() throws {
        let guide = try launch().welcomeGuide
        XCTAssertFalse(guide.canGoBack)

        var visited = [guide.step]
        while guide.step != .finish {
            guide.next()
            visited.append(guide.step)
        }
        XCTAssertEqual(visited, [.welcome, .systemPermissions, .menuTrigger, .officialPlugins, .finish])

        guide.back()
        XCTAssertEqual(guide.step, .officialPlugins)
        XCTAssertTrue(guide.isPresented)
    }

    func testASkippedGuideDoesNotReappearAtTheNextLaunch() throws {
        let first = try launch()
        first.welcomeGuide.next()
        first.welcomeGuide.skip()
        XCTAssertFalse(first.welcomeGuide.isPresented)

        XCTAssertFalse(try launch().welcomeGuide.isPresented)
    }

    func testAGuideClosedWithoutSkippingOrCompletingOpensAgainAtTheNextLaunch() throws {
        _ = try launch()

        XCTAssertTrue(try launch().welcomeGuide.isPresented)
    }

    /// Spinnet reopens itself, for System Settings' Quit & Reopen or its own
    /// restart, while the guide is on its permission step; Settings shows
    /// again with the guide there, even once a Plugin is installed.
    func testARelaunchMidGuideReopensSettingsWithTheGuideAtTheSameStep() throws {
        let first = try launch()
        first.welcomeGuide.next()
        XCTAssertEqual(first.welcomeGuide.step, .systemPermissions)

        first.prepareToQuit(reopeningSettings: true)
        XCTAssertTrue(first.isQuitting)
        XCTAssertTrue(first.welcomeGuide.isPresented, "a quit takes the sheet down without skipping the guide")

        let second = try model(withPlugins: true)
        XCTAssertTrue(second.openAtLaunch())
        XCTAssertTrue(second.welcomeGuide.isPresented)
        XCTAssertEqual(second.welcomeGuide.step, .systemPermissions)

        // Only that one launch continues; the guide is still owed until
        // completed or skipped, from Welcome as before.
        XCTAssertEqual(try launch().welcomeGuide.step, .welcome)
    }

    func testARelaunchResumesAGuideReopenedFromGeneral() throws {
        let first = try launch()
        first.welcomeGuide.skip()
        first.openWelcomeGuide()
        first.welcomeGuide.next()

        first.prepareToQuit(reopeningSettings: true)

        let second = try launch()
        XCTAssertTrue(second.welcomeGuide.isPresented)
        XCTAssertEqual(second.welcomeGuide.step, .systemPermissions)
        XCTAssertFalse(try launch().welcomeGuide.isPresented, "a finished guide stays closed after that launch")
    }

    func testARelaunchWithSettingsOpenShowsTheSamePageOnce() throws {
        let first = try launch(withPlugins: true)
        first.selectPage(.privacyAndPermissions)

        first.prepareToQuit(reopeningSettings: true)

        let second = try model(withPlugins: true)
        XCTAssertTrue(second.openAtLaunch())
        XCTAssertEqual(second.page, .privacyAndPermissions)
        XCTAssertFalse(second.welcomeGuide.isPresented)
        XCTAssertFalse(try model(withPlugins: true).openAtLaunch())
    }

    func testAnOrdinaryQuitRestoresNothing() throws {
        let first = try launch()
        first.welcomeGuide.next()
        first.selectPage(.general)

        first.prepareToQuit()

        let second = try model(withPlugins: true)
        XCTAssertFalse(second.openAtLaunch())
        XCTAssertEqual(try launch().welcomeGuide.step, .welcome, "a first-run guide still starts over")
    }

    func testACancelledRelaunchKeepsTheGuideOpenAndForgetsIt() throws {
        let first = try launch()
        first.welcomeGuide.next()
        first.prepareToQuit(reopeningSettings: true)

        first.cancelQuit()

        XCTAssertFalse(first.isQuitting)
        XCTAssertTrue(first.welcomeGuide.isPresented)
        XCTAssertFalse(try model(withPlugins: true).openAtLaunch())
    }

    func testARelaunchWithTheGuideClosedResumesNoGuide() throws {
        let first = try launch()
        first.welcomeGuide.next()
        first.welcomeGuide.skip()
        first.prepareToQuit(reopeningSettings: true)

        XCTAssertFalse(try launch().welcomeGuide.isPresented)
    }

    func testCompletingTheGuideOpensTheMenuEditorAndItDoesNotReappear() throws {
        let first = try launch()
        first.selectPage(.general)
        while first.welcomeGuide.step != .finish { first.welcomeGuide.next() }

        first.welcomeGuide.complete()

        XCTAssertFalse(first.welcomeGuide.isPresented)
        XCTAssertEqual(first.page, .menu)
        XCTAssertFalse(try launch().welcomeGuide.isPresented)
    }

    func testGeneralReopensTheGuideAtWelcomeAfterItWasCompleted() throws {
        let first = try launch()
        while first.welcomeGuide.step != .finish { first.welcomeGuide.next() }
        first.welcomeGuide.complete()

        let later = try launch(withPlugins: true)
        later.selectPage(.general)
        XCTAssertTrue(later.accessibleNames.contains("Open Welcome Guide"))

        later.openWelcomeGuide()

        XCTAssertTrue(later.welcomeGuide.isPresented)
        XCTAssertEqual(later.welcomeGuide.step, .welcome)
    }

    func testThePermissionStepShowsLiveSystemPermissionStatus() throws {
        var accessibilityGranted = false
        let model = try launch(accessibilityGranted: { accessibilityGranted })
        model.welcomeGuide.next()
        XCTAssertEqual(model.welcomeGuide.step, .systemPermissions)
        XCTAssertTrue(model.accessibleNames.contains("Accessibility: Accessibility required"))

        accessibilityGranted = true
        model.privacy.refreshSystemPermissionStatus(includingBackgroundOperations: false)

        XCTAssertTrue(model.accessibleNames.contains("Accessibility: Accessibility granted"))
        XCTAssertFalse(model.accessibleNames.contains("Accessibility: Accessibility required"))
    }

    /// The guide's permission step covers what the first-run Accessibility
    /// banner asked for, so the banner neither stacks on the guide nor
    /// follows a completed one.
    func testTheGuideStandsInForTheFirstRunPermissionBanner() throws {
        let model = try launch()
        XCTAssertTrue(model.privacy.permissionGuidePresented)
        XCTAssertFalse(model.accessibleNames.contains("Spinnet Permissions"))

        while model.welcomeGuide.step != .finish { model.welcomeGuide.next() }
        model.welcomeGuide.complete()

        XCTAssertFalse(model.privacy.permissionGuidePresented)
    }

    /// The path the Host takes at launch: the controller decides, then
    /// presents Settings with the guide on top.
    func testTheSettingsWindowOpensWithTheGuideAtAFirstLaunch() throws {
        let controller = SettingsWindowController(editor: try emptyEditor(), defaults: defaults)

        XCTAssertTrue(controller.openAtLaunch())
        XCTAssertTrue(controller.welcomeGuidePresented)
        XCTAssertTrue(controller.presentationSnapshot.accessibleNames.contains("Welcome Guide"))
    }
}
