import Foundation
import XCTest
@testable import SpinnetCore
import SpinnetPluginTestKit

/// Clipboard History's browser is the one Host Surface: the Host owns the
/// window and the Plugin only asks for it. The `read_clipboard_history` grant
/// decides who may ask; where the package came from grants nothing, so a copy
/// the user installs after removing the Bundled Plugin behaves the same.
final class ClipboardHistoryTests: XCTestCase {
    private var helper: PluginTestHelper!

    override func setUpWithError() throws {
        helper = try PluginTestHelper()
    }

    override func tearDown() {
        helper?.shutdown()
        helper = nil
    }

    func testBrowsingPresentsTheHostSurfaceForAnyOriginOnceGranted() throws {
        for origin in [PluginOrigin.bundled, .installed] {
            let plugin = try PluginUnderTest(named: "ClipboardHistory.spinnetplugin", origin: origin)
            let grants = PluginCapabilityGrantStore()
            var presented: [(plugin: PluginID, action: ActionID)] = []
            let broker = CapabilityCheckedHostServiceBroker(
                grantStore: grants, systemPermissionCheck: { _ in false },
                selectedTextProvider: { _ in "" }, clipboardWriter: { _ in },
                clipboardHistoryProvider: { _, _ in
                    XCTFail("Presenting reads nothing on the Plugin's behalf")
                    throw PluginHostServiceError.unavailable("not read")
                },
                clipboardHistoryPresenter: { package, action in presented.append((package.manifest.id, action.id)) }
            )

            let refused = helper.run(PluginTestInvocation("history.browse"), of: plugin, answering: broker)
            XCTAssertThrowsError(try refused.result.get(), "\(origin): refused until granted") { error in
                XCTAssertTrue("\(error)".contains("read_clipboard_history"), "\(origin): \(error)")
            }
            XCTAssertEqual(refused.requests.map(\.service), [.presentClipboardHistory])
            XCTAssertTrue(presented.isEmpty, "\(origin): nothing is presented without the grant")

            grants.setDecision(.granted, for: plugin.manifest.id, pluginVersion: plugin.manifest.version,
                               capability: .readClipboardHistory,
                               scope: plugin.manifest.scope(for: .readClipboardHistory))
            let browsed = helper.run(PluginTestInvocation("history.browse"), of: plugin, answering: broker)

            XCTAssertEqual(try browsed.result.get(), .null, "\(origin): the Plugin learns nothing from the window")
            XCTAssertEqual(browsed.requests, [PluginTestRequest(service: .presentClipboardHistory, input: .null)])
            XCTAssertEqual(presented.map(\.plugin), [plugin.manifest.id], "\(origin)")
            XCTAssertEqual(presented.map(\.action), [ActionID("history.browse")], "\(origin)")
        }
    }
}
