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
        let model = SettingsWindowModel(
            editor: withPlugins ? try makeEditor() : try emptyEditor(),
            metadata: .current,
            defaults: defaults,
            accessibilityPermissionCheck: accessibilityGranted,
            mouseInputConflictCheck: { _ in [] }
        )
        model.openWelcomeGuideAtLaunchIfNeeded()
        return model
    }

    func testAFirstLaunchWithNoPluginInstalledOpensTheGuideAtWelcome() throws {
        let model = try launch()

        XCTAssertTrue(model.welcomeGuide.isPresented)
        XCTAssertEqual(model.welcomeGuide.step, .welcome)
    }

    func testALaunchWithAPluginInstalledDoesNotOpenTheGuide() throws {
        XCTAssertFalse(try launch(withPlugins: true).welcomeGuide.isPresented)
    }

    func testTheGuideStepsThroughPermissionsAndTheMenuTriggerToTheFinish() throws {
        let guide = try launch().welcomeGuide
        XCTAssertFalse(guide.canGoBack)

        var visited = [guide.step]
        while guide.step != .finish {
            guide.next()
            visited.append(guide.step)
        }
        XCTAssertEqual(visited, [.welcome, .systemPermissions, .menuTrigger, .finish])

        guide.back()
        XCTAssertEqual(guide.step, .menuTrigger)
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

        controller.openWelcomeGuideAtLaunchIfNeeded()

        XCTAssertTrue(controller.welcomeGuidePresented)
        XCTAssertTrue(controller.presentationSnapshot.accessibleNames.contains("Welcome Guide"))
    }
}
