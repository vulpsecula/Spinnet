import Foundation
import XCTest
@testable import SpinnetCore

/// What the Host does itself in a Plugin View, without a View Event: the
/// standard actions, each under the Capability its matching Host Service
/// needs, and setting controls, stored as Plugin Settings are (W11 #58).
final class PluginViewHostActionsTests: XCTestCase {
    private static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/ViewGallery.spinnetplugin", isDirectory: true)

    private var package: PluginPackage!
    private var grants: PluginCapabilityGrantStore!
    private var accessibilityGranted = true
    private var copied: [String] = []
    private var opened: [URL] = []
    private var inserted: [(String, PluginViewOrigin?)] = []
    /// Each insertion's delivery, finished when a test says so.
    private var deliveries: [(PluginHostServiceError?) -> Void] = []
    private var settingsShown: [PluginID] = []
    private var stored: [String: JSONValue] = [:]
    private var actions: PluginViewHostActions!

    override func setUpWithError() throws {
        package = try PluginManifestLoader.load(packageAt: Self.fixture)
        grants = PluginCapabilityGrantStore()
        for capability in [PluginCapability.writeClipboard, .openURL, .insertIntoFocusedApp] {
            grants.setDecision(.granted, for: package.manifest.id, pluginVersion: package.manifest.version,
                               capability: capability, scope: package.manifest.scope(for: capability))
        }
        accessibilityGranted = true
        copied = []
        opened = []
        inserted = []
        deliveries = []
        settingsShown = []
        stored = [:]
        let broker = CapabilityCheckedHostServiceBroker(
            grantStore: grants, systemPermissionCheck: { [unowned self] _ in self.accessibilityGranted },
            selectedTextProvider: { _ in "" },
            clipboardWriter: { _ in XCTFail("A standard action does not go through the service's own effect") }
        )
        let package = package!
        actions = PluginViewHostActions(
            authorize: { service, action in try broker.authorize(service, for: package, action: action) },
            manifest: { $0 == package.manifest.id ? package.manifest : nil },
            copyText: { [unowned self] in copied.append($0) },
            openURL: { [unowned self] in opened.append($0) },
            insertText: { [unowned self] text, origin, finished in
                inserted.append((text, origin))
                deliveries.append(finished)
            },
            openPluginSettings: { [unowned self] in settingsShown.append($0) },
            readSettings: { [unowned self] manifest in manifest.resolvedSettings(stored: stored) },
            writeSettings: { [unowned self] _, values in stored = values }
        )
    }

    // MARK: - Standard actions

    /// Acceptance: each standard action works without a View Event.
    func testEachStandardActionIsPerformedByTheHostWhenItsCapabilityIsGranted() throws {
        let action = try self.action()
        let origin = PluginViewOrigin(processIdentifier: 42, name: "TextEdit")

        try actions.perform(.copyText("copied"), for: action, origin: origin)
        try actions.perform(.openURL(" https://example.com/page "), for: action, origin: origin)
        try actions.perform(.insertText("inserted"), for: action, origin: origin)
        try actions.perform(.openPluginSettings, for: action, origin: origin)

        XCTAssertEqual(copied, ["copied"])
        XCTAssertEqual(opened, [URL(string: "https://example.com/page")])
        XCTAssertEqual(inserted.map(\.0), ["inserted"])
        XCTAssertEqual(inserted.map(\.1), [origin], "Text goes into the App the view came from")
        XCTAssertEqual(settingsShown, [package.manifest.id])
    }

    /// Acceptance: a standard action whose Capability is not granted is
    /// refused, and the refusal names its repair route.
    func testAStandardActionWhoseCapabilityIsNotGrantedIsRefusedWithItsRepairRoute() throws {
        let action = try self.action()
        let refused: [(PluginViewStandardAction, PluginCapability)] = [
            (.copyText("x"), .writeClipboard), (.openURL("https://example.com"), .openURL),
            (.insertText("x"), .insertIntoFocusedApp)
        ]
        for (standard, capability) in refused {
            grants.setDecision(.denied, for: package.manifest.id, pluginVersion: package.manifest.version,
                               capability: capability, scope: package.manifest.scope(for: capability))
            XCTAssertThrowsError(try actions.perform(standard, for: action, origin: nil)) { error in
                XCTAssertEqual(error as? PluginHostServiceError, .capabilityDenied(capability))
                let failure = actions.failure(error, for: action)
                XCTAssertEqual(failure.category, .capabilityDenied)
                XCTAssertEqual(PluginViewRepairRoute(failure), .pluginSettings)
            }
        }
        XCTAssertEqual(copied, [])
        XCTAssertEqual(opened, [])
        XCTAssertTrue(inserted.isEmpty)

        try actions.perform(.openPluginSettings, for: action, origin: nil)
        XCTAssertEqual(settingsShown, [package.manifest.id], "Opening Plugin Settings needs no Capability")
    }

    /// Inserted text is typed after the Host brings the App forward, so
    /// its outcome arrives once that is done; the other standard actions
    /// finish at once.
    func testAStandardActionReportsWhenItsEffectFinishes() throws {
        let action = try self.action()
        var outcomes: [String: PluginHostServiceError?] = [:]
        try actions.perform(.copyText("copied"), for: action, origin: nil) { outcomes["copy"] = $0 }
        XCTAssertEqual(outcomes["copy"], .some(nil))

        try actions.perform(.insertText("inserted"), for: action, origin: nil) { outcomes["insert"] = $0 }
        XCTAssertNil(outcomes["insert"], "Still being typed")
        deliveries.first?(.unavailable("The App to insert into is no longer open"))
        XCTAssertEqual(outcomes["insert"], .some(.unavailable("The App to insert into is no longer open")))
    }

    func testInsertingTextNeedsAccessibilityAsInsertTextDoes() throws {
        accessibilityGranted = false
        XCTAssertThrowsError(try actions.perform(.insertText("x"), for: try action(), origin: nil)) { error in
            XCTAssertEqual(error as? PluginHostServiceError, .systemPermissionDenied(.accessibility))
            XCTAssertEqual(PluginViewRepairRoute(actions.failure(error, for: try! action())), .privacyAndPermissions)
        }
        XCTAssertTrue(inserted.isEmpty)
    }

    /// A link opens under the `open_url` rules: only http and https.
    func testOpeningALinkFollowsTheOpenURLRules() throws {
        for link in ["javascript:alert(1)", "file:///etc/hosts", "", "not a link"] {
            XCTAssertThrowsError(try actions.perform(.openURL(link), for: try action(), origin: nil), link) {
                guard case .invalidInput = $0 as? PluginHostServiceError else { return XCTFail("\($0)") }
            }
        }
        XCTAssertEqual(opened, [])
    }

    /// A standard action is only ever the Plugin's own: another Plugin's
    /// Action cannot borrow its grant.
    func testAnotherPluginsActionCannotPerformIt() throws {
        let other = try ActionConfiguration(
            id: ActionID("other"), pluginID: PluginID("com.example.other"),
            command: CommandDeclaration(id: CommandID("gallery.form"), title: "Form", execution: .javascript,
                                        script: "gallery.js"),
            input: .null)
        XCTAssertThrowsError(try actions.perform(.copyText("x"), for: other, origin: nil))
        XCTAssertEqual(copied, [])
    }

    // MARK: - Setting controls

    func testASettingControlShowsWhatIsStoredNow() throws {
        let tone = try XCTUnwrap(control("tone"))
        XCTAssertEqual(actions.value(of: tone, pluginID: package.manifest.id), .string("plain"))
        stored = ["tone": .string("warm")]
        XCTAssertEqual(actions.value(of: tone, pluginID: package.manifest.id), .string("warm"))
    }

    /// A setting control stores the value as Plugin Settings do, keeping the
    /// other settings, and then becomes a `setting_changed` event.
    func testASettingChangeIsStoredAsPluginSettingsAreAndThenBecomesAnEvent() throws {
        let event = try actions.changeSetting("tone", to: .string("warm"), pluginID: package.manifest.id)

        XCTAssertEqual(event, .settingChanged(key: "tone", value: .string("warm")))
        XCTAssertEqual(stored, ["tone": .string("warm"), "shout": .bool(false), "from": .string("en"), "into": .string("de")])
        XCTAssertEqual(try actions.changeSetting("shout", to: .bool(true), pluginID: package.manifest.id),
                       .settingChanged(key: "shout", value: .bool(true)))
        XCTAssertEqual(stored, ["tone": .string("warm"), "shout": .bool(true), "from": .string("en"), "into": .string("de")])
    }

    func testASettingValueItsFieldCannotHoldIsRefusedAndNothingIsStored() throws {
        for (key, value) in [("tone", JSONValue.string("loud")), ("shout", .string("yes")), ("missing", .bool(true))] {
            XCTAssertThrowsError(try actions.changeSetting(key, to: value, pluginID: package.manifest.id), key)
        }
        XCTAssertEqual(stored, [:])
    }

    /// A swap button stores both settings exchanged in one write, then
    /// delivers one `settings_swapped`, so the script can tell a swap from
    /// two changes.
    func testASwapStoresBothSettingsExchangedAndBecomesOneEvent() throws {
        stored = ["from": .string("en"), "into": .string("fr")]
        let event = try actions.swapSettings("from", "into", pluginID: package.manifest.id)

        XCTAssertEqual(event, .settingsSwapped(first: "from", second: "into"))
        XCTAssertEqual(stored["from"], .string("fr"))
        XCTAssertEqual(stored["into"], .string("en"))
        XCTAssertEqual(stored["tone"], .string("plain"), "The other settings are kept")
    }

    /// Only two choice settings that can hold each other's values swap.
    func testASwapEitherSettingCannotTakeIsRefusedAndNothingIsStored() throws {
        stored = ["from": .string("en"), "into": .string("fr")]
        for (first, second) in [("from", "tone"), ("tone", "shout"), ("from", "from"), ("from", "missing")] {
            XCTAssertThrowsError(try actions.swapSettings(first, second, pluginID: package.manifest.id), "\(first) \(second)")
        }
        XCTAssertEqual(stored, ["from": .string("en"), "into": .string("fr")])
    }

    // MARK: - Repair routes

    func testEachRefusalNamesTheRouteThatRepairsIt() {
        func failure(_ category: ActionFailureCategory, _ message: String = "") -> ActionFailure {
            ActionFailure(pluginID: PluginID("p"), actionID: ActionID("a"), category: category, message: message)
        }
        XCTAssertEqual(PluginViewRepairRoute(failure(.capabilityDenied)), .pluginSettings)
        XCTAssertEqual(PluginViewRepairRoute(failure(.systemPermissionDenied)), .privacyAndPermissions)
        XCTAssertNil(PluginViewRepairRoute(failure(.timedOut)))
        XCTAssertNil(PluginViewRepairRoute(failure(.hostServiceFailed)))
        XCTAssertEqual(PluginViewRepairRoute.pluginSettings.guidance, ActionUnavailableReason.capabilityDenied.description)
        XCTAssertEqual(PluginViewRepairRoute.privacyAndPermissions.guidance,
                       ActionUnavailableReason.systemPermissionDenied.description)
    }

    // MARK: - Support

    private func action() throws -> ActionConfiguration {
        let command = try XCTUnwrap(package.manifest.commands.first { $0.id == CommandID("gallery.form") })
        return try ActionConfiguration(id: ActionID("gallery"), pluginID: package.manifest.id, command: command,
                                       input: .null)
    }

    private func control(_ key: String) throws -> PluginViewSettingControl? {
        try PluginViewDescription(parsing: .object([
            "title": .string("T"), "settings": .array([.object(["key": .string(key)])]),
            "actions": .array([.object(["id": .string("a"), "title": .string("A")])])
        ]), settingsFields: package.manifest.settingsFields).settings.first
    }
}
