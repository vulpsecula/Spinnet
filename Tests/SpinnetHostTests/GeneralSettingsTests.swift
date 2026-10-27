import AppKit
import SpinnetCore
import XCTest
@testable import SpinnetHost

final class GeneralSettingsTests: XCTestCase {
    func testGeneralIsTheFirstSettingsPageWithItsIconIdentifierAndContentNames() throws {
        let controller = try makeController()

        XCTAssertEqual(controller.presentationSnapshot.navigationPages,
                       [.general, .menu, .appearance, .privacyAndPermissions, .about])
        XCTAssertEqual(SettingsPage.general.title, "General")
        XCTAssertEqual(SettingsPage.general.systemImageName, "gearshape")
        XCTAssertEqual(SettingsPage.general.accessibilityIdentifier.rawValue, "settings.page.general")

        controller.select(page: .general)

        XCTAssertEqual(controller.presentationSnapshot.page, .general)
        XCTAssertEqual(controller.presentationSnapshot.visibleRegions, [.navigation, .pageContent])
        let names = controller.presentationSnapshot.accessibleNames
        for expected in ["General", "Launch at Login", "Show Status Item"] {
            XCTAssertTrue(names.contains(expected), "Missing accessible General content: \(expected)")
        }
        XCTAssertFalse(names.contains("Developer"), "Without developer tools General has no Developer section")
    }

    func testThereIsNoSeparateDeveloperPage() {
        XCTAssertNil(SettingsPage(rawValue: "developer"))
        XCTAssertFalse(SettingsPage.allCases.map(\.accessibilityIdentifier.rawValue)
            .contains("settings.page.developer"))
    }

    // MARK: Launch at Login

    func testLaunchAtLoginReflectsTheSystemStateIncludingApprovalRequired() throws {
        let service = RecordedLoginItemService(status: .notRegistered)
        let controller = try makeGeneralController(loginItems: service)
        XCTAssertFalse(controller.launchAtLogin.isOn)

        service.status = .requiresApproval
        controller.launchAtLogin.refresh()
        XCTAssertTrue(controller.launchAtLogin.isOn, "A registered item awaiting approval is on")
        let names = controller.presentationSnapshot.accessibleNames
        XCTAssertTrue(names.contains("Launch at Login needs your approval in System Settings"))
        XCTAssertTrue(names.contains("Open Login Items Settings"))
        controller.launchAtLogin.openLoginItemsSettings()
        XCTAssertEqual(service.openedSettings, 1)

        service.status = .enabled
        controller.launchAtLogin.refresh()
        XCTAssertTrue(controller.launchAtLogin.isOn)
        XCTAssertFalse(controller.presentationSnapshot.accessibleNames.contains("Open Login Items Settings"))
    }

    func testTurningLaunchAtLoginOnAndOffRegistersWithTheSystem() throws {
        let service = RecordedLoginItemService(status: .notRegistered)
        let controller = try makeGeneralController(loginItems: service)

        controller.launchAtLogin.setEnabled(true)
        XCTAssertEqual(service.calls, ["register"])
        XCTAssertTrue(controller.launchAtLogin.isOn)
        XCTAssertNil(controller.launchAtLogin.failure)

        controller.launchAtLogin.setEnabled(false)
        XCTAssertEqual(service.calls, ["register", "unregister"])
        XCTAssertFalse(controller.launchAtLogin.isOn)
    }

    func testLaunchAtLoginReportsAFailureAndKeepsTheRealState() throws {
        let service = RecordedLoginItemService(status: .notRegistered)
        service.failure = RecordedLoginItemService.Failure(message: "The operation couldn't be completed.")
        let controller = try makeGeneralController(loginItems: service)

        controller.launchAtLogin.setEnabled(true)

        XCTAssertFalse(controller.launchAtLogin.isOn, "The toggle shows the system state, not the request")
        let failure = try XCTUnwrap(controller.launchAtLogin.failure)
        XCTAssertEqual(failure, "Spinnet could not turn on Launch at Login: The operation couldn't be completed.")
        XCTAssertTrue(controller.presentationSnapshot.accessibleNames.contains(failure))

        service.failure = nil
        controller.launchAtLogin.setEnabled(true)
        XCTAssertNil(controller.launchAtLogin.failure, "A later success clears the failure")
    }

    func testLaunchAtLoginIsUnavailableOutsideAnAppBundle() throws {
        let service = RecordedLoginItemService(status: .notFound)
        let controller = try makeGeneralController(loginItems: service)

        XCTAssertFalse(controller.launchAtLogin.isAvailable)
        XCTAssertTrue(controller.presentationSnapshot.accessibleNames
            .contains("Only Spinnet running from its app bundle can launch at login"))
    }

    // MARK: Show Status Item

    func testShowStatusItemIsASavedPreferenceThatDefaultsOn() throws {
        let suite = "GeneralSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        func make() throws -> SettingsWindowController {
            SettingsWindowController(editor: try makeEditor(), defaults: defaults,
                                     loginItems: RecordedLoginItemService(status: .notRegistered))
        }
        let controller = try make()
        XCTAssertTrue(controller.showsStatusItem)
        var heard: [Bool] = []
        controller.onShowsStatusItemChanged = { heard.append($0) }

        controller.showsStatusItem = false

        XCTAssertEqual(heard, [false])
        XCTAssertFalse(try make().showsStatusItem, "The choice survives a relaunch")
    }

    func testAHiddenStatusItemIsRemovedExceptWhileHostActivityIsOngoing() throws {
        _ = NSApplication.shared
        let activities = HostActivities()
        let controller = StatusItemController(openSettings: {}, quit: {}, activities: activities)
        controller.install()
        defer { controller.setShowsStatusItem(true) }
        XCTAssertNotNil(controller.statusItem)

        controller.setShowsStatusItem(false)
        XCTAssertNil(controller.statusItem)

        let effect = try activities.register(owner: PluginID("clock"), pluginName: "Clock",
                                             kind: "keep_awake", status: "On", stop: {})
        drainMainQueue()
        XCTAssertNotNil(controller.statusItem, "An ongoing Effect keeps its Stop control reachable")

        XCTAssertTrue(activities.stop(effect.id))
        drainMainQueue()
        XCTAssertNil(controller.statusItem)

        controller.setShowsStatusItem(true)
        XCTAssertNotNil(controller.statusItem)
    }

    func testAnEndedTaskDoesNotKeepAHiddenStatusItem() throws {
        _ = NSApplication.shared
        let activities = HostActivities()
        let controller = StatusItemController(openSettings: {}, quit: {}, activities: activities)
        controller.install()
        defer { controller.setShowsStatusItem(true) }
        controller.setShowsStatusItem(false)

        let task = try activities.register(owner: PluginID("packages"), pluginName: "Packages",
                                           kind: "task", status: "Running", stop: {})
        drainMainQueue()
        XCTAssertNotNil(controller.statusItem, "A running Task is ongoing")

        activities.updateTask(task.id, status: "Completed", detail: .object([
            "id": .string(task.id), "status": .string("ended")]))
        drainMainQueue()
        XCTAssertNil(controller.statusItem)
    }

    // MARK: Reopen

    func testReopeningTheRunningAppOpensSettings() throws {
        let controller = try makeController()
        defer { controller.close() }
        let delegate = ApplicationDelegate()
        delegate.settings = controller

        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        XCTAssertEqual(controller.window?.isVisible, true)
    }

    private func makeGeneralController(loginItems: LoginItemService) throws -> SettingsWindowController {
        let suite = "GeneralSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let controller = SettingsWindowController(editor: try makeEditor(), defaults: defaults, loginItems: loginItems)
        controller.select(page: .general)
        return controller
    }

    private func drainMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    #if DEBUG
    func testDeveloperIsGeneralsLastSectionInADevelopmentBuildWithoutARevealStep() throws {
        let suite = "GeneralSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = SettingsWindowController(editor: try makeEditor(), defaults: defaults)
        controller.developerTools = DeveloperTools(
            diagnostics: { Self.diagnostics }, dataDirectory: FileManager.default.temporaryDirectory,
            showLifecycleTestWindow: {}, canRelaunch: false, relaunch: {}
        )

        XCTAssertEqual(controller.presentationSnapshot.navigationPages,
                       [.general, .menu, .appearance, .privacyAndPermissions, .about],
                       "Developer tools add no page")
        controller.select(page: .general)
        let names = controller.presentationSnapshot.accessibleNames
        let developer = try XCTUnwrap(names.firstIndex(of: "Developer"))
        XCTAssertGreaterThan(developer, try XCTUnwrap(names.firstIndex(of: "Show Status Item")))
        // The permission guide overlays the window and lists its names after
        // the page content, so only the page's own tail is compared.
        let pageNames = names.filter { !["Spinnet Permissions", "Open Accessibility Settings", "Skip for now"].contains($0) }
        XCTAssertEqual(Array(pageNames[try XCTUnwrap(pageNames.firstIndex(of: "Developer"))...]), [
            "Developer",
            "Relaunch Spinnet",
            "Lifecycle Test Window",
            "Copy Diagnostics",
            "Reveal Data Folder",
            "Copy Log Stream Command"
        ])
        XCTAssertFalse(names.contains("Hide Developer Page"))

        controller.select(page: .about)
        XCTAssertFalse(controller.presentationSnapshot.accessibleNames.contains("Developer"))
    }

    private static let diagnostics = DeveloperDiagnostics(
        appPath: "/A.app", bundleIdentifier: "b", version: "1", sourceRevision: "r", processIdentifier: 1,
        arguments: [], bundledPluginSource: "none", dataDirectory: "/d", plugins: [], refused: []
    )
    #endif
}

private final class RecordedLoginItemService: LoginItemService {
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
    var status: LoginItemStatus
    var failure: Failure?
    private(set) var calls: [String] = []
    private(set) var openedSettings = 0

    init(status: LoginItemStatus) { self.status = status }

    func register() throws {
        calls.append("register")
        if let failure { throw failure }
        status = .enabled
    }

    func unregister() throws {
        calls.append("unregister")
        if let failure { throw failure }
        status = .notRegistered
    }

    func openSystemSettingsLoginItems() { openedSettings += 1 }
}
