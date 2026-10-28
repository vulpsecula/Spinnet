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
            dataDirectory: "/Users/dev/Library/Application Support/Spinnet",
            plugins: [
                .init(id: "com.spinnet.homebrew", name: "Homebrew", version: "2.5.5",
                      hostCompatibility: "^1.0.0", isEnabled: true),
                .init(id: "com.example.probe", name: "Probe", version: "0.3.0",
                      hostCompatibility: "^1.0.0", isEnabled: false)
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
        Data: /Users/dev/Library/Application Support/Spinnet

        Plugins (2):
        - com.spinnet.homebrew 2.5.5 [Host ^1.0.0] Homebrew
        - com.example.probe 0.3.0 [Host ^1.0.0, disabled] Probe

        Refused Plugins (1):
        - com.example.old: Needs Plugin API Level 9

        """)
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

    private static let minimalDiagnostics = DeveloperDiagnostics(
        appPath: "/A.app", bundleIdentifier: "b", version: "1", sourceRevision: "r", processIdentifier: 1,
        arguments: ["--lifecycle-check"], dataDirectory: "/d", plugins: [], refused: []
    )
}
#endif
