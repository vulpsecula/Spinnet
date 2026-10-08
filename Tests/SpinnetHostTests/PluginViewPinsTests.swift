import AppKit
import SpinnetCore
import XCTest
@testable import SpinnetHost

/// The Host's memory of a Plugin's Pin outlives Host restarts and updates
/// of the Plugin, and is forgotten when the user removes the Plugin (#73,
/// decided 2026-10-08), with the Host's own installation store and Pin
/// memory over a private defaults suite.
final class PluginViewPinsTests: XCTestCase {
    private static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/ViewGallery.spinnetplugin", isDirectory: true)
    private static let pluginID = PluginID("com.example.view-gallery")
    private static let placed = PluginPanelGeometry(frame: NSRect(x: 900, y: 100, width: 600, height: 500),
                                                    isUserSized: true)

    private var defaults: UserDefaults!
    private var pins: PluginViewPins!
    private var installation: PluginInstallationStore!
    private var registry: PluginRegistry!

    override func setUpWithError() throws {
        let suite = "PluginViewPinsTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Plugins-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        pins = PluginViewPins(defaults: defaults)
        registry = PluginRegistry()
        installation = PluginInstallationStore(directory: directory, registry: registry,
                                               grants: PluginCapabilityGrantStore(), persistGrants: {},
                                               forgetHostPreferences: { [unowned self] in pins.forget($0) })
    }

    private func pinAndPlace() {
        pins.setPinned(true, for: Self.pluginID)
        pins.setGeometry(Self.placed, for: Self.pluginID)
    }

    func testRemovingThePluginForgetsItsPinAndGeometryAcrossARestart() throws {
        try installation.install(from: Self.fixture)
        pinAndPlace()
        let other = PluginID("com.example.other")
        pins.setPinned(true, for: other)

        try installation.uninstall(Self.pluginID)

        XCTAssertFalse(pins.isPinned(Self.pluginID))
        XCTAssertNil(pins.geometry(for: Self.pluginID))
        let restarted = PluginViewPins(defaults: defaults)
        XCTAssertFalse(restarted.isPinned(Self.pluginID))
        XCTAssertNil(restarted.geometry(for: Self.pluginID))
        XCTAssertTrue(restarted.isPinned(other), "Another Plugin's Pin stays")
    }

    func testAnUpdateKeepsThePinAndGeometry() throws {
        try installation.install(from: Self.fixture)
        pinAndPlace()

        // Installing a registered Plugin again is an update.
        try installation.install(from: Self.fixture)

        XCTAssertNotNil(registry.package(for: Self.pluginID))
        let restarted = PluginViewPins(defaults: defaults)
        XCTAssertTrue(restarted.isPinned(Self.pluginID))
        XCTAssertEqual(restarted.geometry(for: Self.pluginID), Self.placed)
    }

    /// A Plugin installed after it was removed starts unpinned, even if its
    /// panel's last move reached the memory after the removal.
    func testInstallingARemovedPluginAgainStartsUnpinned() throws {
        try installation.install(from: Self.fixture)
        try installation.uninstall(Self.pluginID)
        pinAndPlace()

        try installation.install(from: Self.fixture)

        XCTAssertFalse(pins.isPinned(Self.pluginID))
        XCTAssertNil(pins.geometry(for: Self.pluginID))
    }
}
