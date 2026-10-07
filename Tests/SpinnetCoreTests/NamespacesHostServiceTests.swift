import Foundation
import XCTest
@testable import SpinnetCore
import SpinnetPluginTestKit

/// A Level 2 Plugin calls through the real
/// helper and the Host's own broker, which performs each ID with the
/// implementation Level 1 already has and checks the same authority.
final class NamespacesHostServiceTests: XCTestCase {
    private var helper: PluginTestHelper!
    private let grants = PluginCapabilityGrantStore()

    override func setUpWithError() throws {
        helper = try PluginTestHelper(contracts: NamespacesProbeFixture.host)
    }

    override func tearDown() {
        helper?.shutdown()
        helper = nil
    }

    private func run(_ script: String, capabilities: [PluginCapability] = [.readSelectedText, .writeClipboard],
                     granting granted: [PluginCapability]? = nil,
                     broker: CapabilityCheckedHostServiceBroker) throws -> PluginTestRun {
        let plugin = try PluginUnderTest(packageAt: NamespacesProbeFixture.write(scripts: ["shout.js": script]) {
            $0["capabilities"] = .array(capabilities.map { .string($0.rawValue) })
        })
        for capability in granted ?? capabilities {
            grants.setDecision(.granted, for: plugin.manifest.id, pluginVersion: plugin.manifest.version,
                               capability: capability, scope: plugin.manifest.scope(for: capability))
        }
        return helper.run(PluginTestInvocation("probe.shout"), of: plugin, answering: broker)
    }

    private func broker(clipboard: @escaping (String) -> Void = { _ in },
                        application: @escaping (String) -> Void = { _ in },
                        capture: @escaping (ScreenCaptureRequest) -> Void = { _ in },
                        preferredCapture: @escaping (ScreenCaptureSource) -> Void = { _ in }) -> CapabilityCheckedHostServiceBroker {
        CapabilityCheckedHostServiceBroker(
            grantStore: grants, systemPermissionCheck: { _ in true },
            selectedTextProvider: { _ in "selected" }, clipboardWriter: clipboard,
            screenCapturer: capture, applicationOpener: application, preferredScreenCapturer: preferredCapture
        )
    }

    func testACallIsPerformedByTheLevelOneImplementation() throws {
        var copied: [String] = []

        let run = try run(#"spinnet.clipboard.write({ text: spinnet.selection.readText() }); null"#,
                          broker: broker(clipboard: { copied.append($0) }))

        XCTAssertEqual(try run.result.get(), .null)
        XCTAssertEqual(copied, ["selected"])
    }

    /// `open.application` launches by bundle identifier or path under the
    /// `open_local_path` grant, and nothing without it.
    func testOpeningAnApplicationIsAuthorizedAsOpeningALocalPath() throws {
        var opened: [String] = []
        let script = #"spinnet.open.application("com.apple.TextEdit")"#

        let refused = try run(script, capabilities: [.writeClipboard, .openLocalPath], granting: [.writeClipboard],
                              broker: broker(application: { opened.append($0) }))
        let granted = try run(script, capabilities: [.writeClipboard, .openLocalPath],
                              broker: broker(application: { opened.append($0) }))

        XCTAssertEqual(try granted.result.get(), .null)
        XCTAssertThrowsError(try refused.result.get()) {
            XCTAssertEqual(($0 as? PluginRuntimeError)?.failureCategory, .capabilityDenied)
        }
        XCTAssertEqual(opened, ["com.apple.TextEdit"])
    }

    /// Decision N9: a capture naming only its source follows the user's
    /// screenshot preferences; one stating both options is Level 1's.
    func testACaptureNamingOnlyItsSourceFollowsThePreferences() throws {
        var preferred: [ScreenCaptureSource] = []
        var explicit: [ScreenCaptureRequest] = []
        let broker = broker(capture: { explicit.append($0) }, preferredCapture: { preferred.append($0) })

        let run = try run("""
            spinnet.screen.capture("area");
            spinnet.screen.capture({ source: "window" });
            spinnet.screen.capture({ source: "fullscreen", copy_to_clipboard: true, save: null }); null
            """, capabilities: [.writeClipboard, .captureScreen], broker: broker)

        XCTAssertEqual(try run.result.get(), .null)
        XCTAssertEqual(preferred, [.area, .window])
        XCTAssertEqual(explicit, [ScreenCaptureRequest(source: .fullScreen, copyToClipboard: true, saveFolder: nil,
                                                       saveFormat: .png)])
    }

    /// Invalid input is reported in the words of the ID the script called.
    func testInvalidInputNamesTheID() throws {
        let run = try run(#"spinnet.selection.readText("please")"#, broker: broker())

        XCTAssertThrowsError(try run.result.get()) {
            XCTAssertEqual($0 as? PluginRuntimeError, .hostServiceFailed(
                #"Host Service input is invalid: selection.readText expects null or {"best_effort": true}"#
            ))
        }
    }
}
