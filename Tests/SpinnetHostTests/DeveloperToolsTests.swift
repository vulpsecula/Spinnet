#if DEBUG
import AppKit
import XCTest
@testable import SpinnetHost

final class DeveloperToolsTests: XCTestCase {
    func testDiagnosticsNameTheRunningBuildAndItsPlugins() {
        let diagnostics = DeveloperDiagnostics(
            appPath: "/Users/dev/Spinnet/dist/SpinnetHost.app",
            bundleIdentifier: "com.vulpsecula.SpinnetHost.preview",
            version: "0.1.0",
            sourceRevision: "503b354-dirty",
            processIdentifier: 4242,
            arguments: [],
            bundledPluginSource: DeveloperDiagnostics.describe(.packaged(URL(fileURLWithPath: "/App/Plugins"))),
            dataDirectory: "/Users/dev/Library/Application Support/Spinnet",
            plugins: [
                .init(id: "com.spinnet.homebrew", name: "Homebrew", version: "2.5.5",
                      origin: "bundled", hostCompatibility: "^1.0.0", isEnabled: true),
                .init(id: "com.example.probe", name: "Probe", version: "0.3.0",
                      origin: "installed", hostCompatibility: "^1.0.0", isEnabled: false)
            ],
            refused: [.init(id: "com.example.old", reason: "Needs Plugin API Level 9")]
        )

        XCTAssertEqual(diagnostics.text, """
        Spinnet Host diagnostics
        App: /Users/dev/Spinnet/dist/SpinnetHost.app
        Bundle ID: com.vulpsecula.SpinnetHost.preview
        Version: 0.1.0
        Source revision: 503b354-dirty
        PID: 4242
        Arguments: (none)
        Bundled Plugins: packaged /App/Plugins
        Data: /Users/dev/Library/Application Support/Spinnet

        Plugins (2):
        - com.spinnet.homebrew 2.5.5 [bundled, Host ^1.0.0] Homebrew
        - com.example.probe 0.3.0 [installed, Host ^1.0.0, disabled] Probe

        Refused Plugins (1):
        - com.example.old: Needs Plugin API Level 9

        """)
    }

    func testDiagnosticsSayWhichBundledPluginSourceTheLaunchRead() {
        XCTAssertEqual(DeveloperDiagnostics.describe(.development(URL(fileURLWithPath: "/repo/Plugins"))),
                       "SPINNET_BUNDLED_PLUGINS_DIR /repo/Plugins")
        XCTAssertEqual(DeveloperDiagnostics.describe(BundledPluginSource.none), "none")
        XCTAssertEqual(DeveloperDiagnostics.describe(nil), "unresolved")
    }

    func testDeveloperToolsRunTheirActions() {
        var relaunched = false
        var lifecycleShown = false
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let tools = DeveloperTools(diagnostics: { Self.minimalDiagnostics },
                                   dataDirectory: FileManager.default.temporaryDirectory,
                                   showLifecycleTestWindow: { lifecycleShown = true },
                                   canRelaunch: true, relaunch: { relaunched = true },
                                   pasteboard: pasteboard)

        tools.copyDiagnostics()
        XCTAssertEqual(pasteboard.string(forType: .string), Self.minimalDiagnostics.text)
        tools.copyLogStreamCommand()
        XCTAssertEqual(pasteboard.string(forType: .string), DeveloperTools.logStreamCommand)
        tools.openLifecycleTestWindow()
        XCTAssertTrue(lifecycleShown)
        tools.relaunch()
        XCTAssertTrue(relaunched)
    }

    func testRelaunchDoesNothingOutsideAnAppBundle() {
        var relaunched = false
        let tools = DeveloperTools(diagnostics: { Self.minimalDiagnostics },
                                   dataDirectory: FileManager.default.temporaryDirectory,
                                   showLifecycleTestWindow: {}, canRelaunch: false, relaunch: { relaunched = true })
        tools.relaunch()
        XCTAssertFalse(relaunched)
    }

    func testTheDeveloperPageStaysHiddenUntilRevealedAndRemembersIt() throws {
        let suite = "DeveloperToolsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let userPages: [SettingsPage] = [.menu, .appearance, .privacyAndPermissions, .about]
        func makeSettings() throws -> SettingsWindowController {
            let controller = SettingsWindowController(editor: try makeEditor(), defaults: defaults)
            controller.developerTools = Self.tools()
            return controller
        }

        let controller = try makeSettings()
        XCTAssertEqual(controller.presentationSnapshot.navigationPages, userPages,
                       "Developer tools alone do not list the page")
        controller.select(page: .developer)
        XCTAssertEqual(controller.currentPage, .menu, "An unlisted page cannot be selected")

        controller.revealDeveloperPage()
        XCTAssertEqual(controller.presentationSnapshot.navigationPages, userPages + [.developer])
        XCTAssertEqual(controller.currentPage, .developer)
        XCTAssertEqual(controller.presentationSnapshot.visibleRegions, [.navigation, .pageContent])
        XCTAssertEqual(try makeSettings().presentationSnapshot.navigationPages.last, .developer,
                       "A revealed page stays revealed across launches")

        controller.hideDeveloperPage()
        XCTAssertEqual(controller.presentationSnapshot.navigationPages, userPages)
        XCTAssertEqual(controller.currentPage, .about)
        XCTAssertEqual(try makeSettings().presentationSnapshot.navigationPages, userPages)
    }

    func testOnlyAHostWithDeveloperToolsCanRevealThePage() throws {
        let suite = "DeveloperToolsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = SettingsWindowController(editor: try makeEditor(), defaults: defaults)
        controller.revealDeveloperPage()
        XCTAssertFalse(controller.presentationSnapshot.navigationPages.contains(.developer))
    }

    private static func tools() -> DeveloperTools {
        DeveloperTools(diagnostics: { minimalDiagnostics }, dataDirectory: FileManager.default.temporaryDirectory,
                       showLifecycleTestWindow: {}, canRelaunch: false, relaunch: {})
    }

    private static let minimalDiagnostics = DeveloperDiagnostics(
        appPath: "/A.app", bundleIdentifier: "b", version: "1", sourceRevision: "r", processIdentifier: 1,
        arguments: ["--lifecycle-check"], bundledPluginSource: "none", dataDirectory: "/d", plugins: [], refused: []
    )
}
#endif
