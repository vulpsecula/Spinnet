import XCTest
import SpinnetCore
@testable import SpinnetHost

/// Privacy & Permissions is reachable with a grant store, a manifest list and
/// two stubs. Before the split, reaching it meant building a whole
/// SettingsWindowModel with a configuration editor and a Clipboard History Store.
final class PrivacyPermissionsModelTests: XCTestCase {
    private var suiteName = ""
    private var defaults = UserDefaults.standard

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "SpinnetHostTests.Privacy.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func manifest(
        id: String = "com.example.reader",
        version: String = "1.0.0",
        capabilities: [PluginCapability] = [.readSelectedText]
    ) throws -> PluginManifest {
        try PluginManifest(
            protocolVersion: "1.0",
            id: PluginID(id),
            name: "Reader",
            version: version,
            capabilities: capabilities,
            commands: [CommandDeclaration(id: CommandID("reader.run"), title: "Run",
                                          execution: .javascript, script: "run.js")]
        )
    }

    private func makeModel(
        manifests: [PluginManifest],
        grantStore: PluginCapabilityGrantStore = PluginCapabilityGrantStore(),
        accessibilityGranted: @escaping () -> Bool = { false }
    ) -> PrivacyPermissionsModel {
        PrivacyPermissionsModel(
            grantStore: grantStore,
            manifests: { manifests },
            accessibilityPermissionCheck: accessibilityGranted,
            defaults: defaults
        )
    }

    func testEveryDeclaredCapabilityStartsUndecided() throws {
        let model = makeModel(manifests: [try manifest(capabilities: [.readSelectedText, .writeClipboard])])

        XCTAssertEqual(model.capabilityGrants.count, 2)
        XCTAssertTrue(model.capabilityGrants.allSatisfy { $0.decision == .notDetermined })
        XCTAssertEqual(Set(model.pendingCapabilityRequests(for: try manifest(capabilities: [.readSelectedText, .writeClipboard]))),
                       [.readSelectedText, .writeClipboard])
    }

    /// Authority decides what a Menu Item can do, so a decision has to reach
    /// the Menu Editor. Losing this signal leaves Slots showing stale
    /// availability after a grant or a revocation.
    func testADecisionNotifiesThatAuthorityChanged() throws {
        let m = try manifest()
        let model = makeModel(manifests: [m])
        var authorityChanges = 0
        var reportedGrants: [[PluginCapabilityGrant]] = []
        model.onAuthorityChanged = { authorityChanges += 1 }
        model.onGrantsChanged = { reportedGrants.append($0) }

        model.setCapabilityDecision(.granted, for: m.id, pluginVersion: m.version, capability: .readSelectedText)

        // Two notifications, from two paths that both have to stay: the model
        // signals synchronously so finishPluginConsent can iterate freshly
        // computed grants, and the grant store's observer signals again for
        // windows that did not make the edit. A looser assertion here would
        // pass even with one of them deleted.
        XCTAssertEqual(authorityChanges, 2)
        XCTAssertEqual(reportedGrants.count, 1, "The Host is told once per decision")
        XCTAssertEqual(model.capabilityGrants.first?.decision, .granted)
        XCTAssertTrue(model.pendingCapabilityRequests(for: m).isEmpty)
    }

    func testRefreshingSystemPermissionsNotifiesThatAuthorityChanged() throws {
        var granted = false
        let model = makeModel(manifests: [try manifest()], accessibilityGranted: { granted })
        var authorityChanges = 0
        model.onAuthorityChanged = { authorityChanges += 1 }
        XCTAssertFalse(model.accessibilityPermissionGranted)

        granted = true
        model.refreshSystemPermissionStatus()

        XCTAssertTrue(model.accessibilityPermissionGranted)
        XCTAssertEqual(authorityChanges, 1)
    }

    func testInstallationConsentOnlyOpensWhenSomethingIsUndecided() throws {
        let m = try manifest()
        let store = PluginCapabilityGrantStore()
        let model = makeModel(manifests: [m], grantStore: store)

        XCTAssertTrue(model.beginInstallationConsent(for: m))
        XCTAssertTrue(model.installationConsentPresented)
        XCTAssertEqual(model.pluginSettingsManifest?.id, m.id)

        model.finishPluginConsent(grant: true)
        XCTAssertFalse(model.installationConsentPresented)
        XCTAssertNil(model.pluginSettingsManifest)

        XCTAssertFalse(model.beginInstallationConsent(for: m),
                       "Reinstalling the same version asks nothing again")
        XCTAssertFalse(model.installationConsentPresented)
    }

    func testDenyingConsentAnswersEveryPendingRequest() throws {
        let m = try manifest(capabilities: [.readSelectedText, .writeClipboard])
        let model = makeModel(manifests: [m])
        model.beginInstallationConsent(for: m)

        model.finishPluginConsent(grant: false)

        XCTAssertTrue(model.capabilityGrants.allSatisfy { $0.decision == .denied })
        XCTAssertTrue(model.pendingCapabilityRequests(for: m).isEmpty)
    }

    /// Reviewing access from the Library opens the same sheet, but it is not a
    /// consent prompt and must not offer grant-everything buttons.
    func testReviewingPluginSettingsIsNotAConsentPrompt() throws {
        let m = try manifest()
        let model = makeModel(manifests: [m])
        model.beginInstallationConsent(for: m)
        XCTAssertTrue(model.installationConsentPresented)

        model.showPluginSettings(m.id)

        XCTAssertFalse(model.installationConsentPresented)
        XCTAssertEqual(model.pluginSettingsManifest?.id, m.id)
    }

    func testAGrantChangedElsewhereRefreshesAuthority() throws {
        let m = try manifest()
        let store = PluginCapabilityGrantStore()
        let model = makeModel(manifests: [m], grantStore: store)
        var authorityChanges = 0
        model.onAuthorityChanged = { authorityChanges += 1 }

        // Another window writing straight to the store, not through this model.
        store.setDecision(.granted, for: m.id, pluginVersion: m.version,
                          capability: .readSelectedText, scope: m.scope(for: .readSelectedText))

        XCTAssertEqual(model.capabilityGrants.first?.decision, .granted)
        XCTAssertGreaterThan(authorityChanges, 0)
    }

    func testDismissingThePermissionGuideIsRemembered() throws {
        let first = makeModel(manifests: [try manifest()])
        XCTAssertTrue(first.permissionGuidePresented, "The guide shows on a fresh install")

        first.dismissPermissionGuide()

        let second = makeModel(manifests: [try manifest()])
        XCTAssertFalse(second.permissionGuidePresented)
    }

    // MARK: Screen Recording

    /// Screen Recording is asked for only from an explicit enable action.
    /// Building the model, refreshing it, and reading its status never prompt.
    func testScreenRecordingIsNeverRequestedWithoutAnExplicitAction() throws {
        var requests = 0
        var granted = false
        let model = PrivacyPermissionsModel(
            grantStore: PluginCapabilityGrantStore(), manifests: { [] },
            accessibilityPermissionCheck: { true }, defaults: defaults,
            screenRecordingPermissionCheck: { granted },
            screenRecordingPermissionRequest: { requests += 1; return granted }
        )
        model.refreshSystemPermissionStatus()
        XCTAssertFalse(model.screenRecordingPermissionGranted)
        XCTAssertFalse(model.isGranted(.screenRecording))
        XCTAssertTrue(model.isGranted(.accessibility))
        XCTAssertEqual(requests, 0)

        var authorityChanges = 0
        model.onAuthorityChanged = { authorityChanges += 1 }
        granted = true
        model.requestScreenRecordingPermission()
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(model.screenRecordingPermissionGranted)
        XCTAssertEqual(authorityChanges, 1)
    }

    /// macOS prompts once. A declined request leaves the permission missing,
    /// and asking again sends the user to System Settings instead.
    func testADeclinedScreenRecordingRequestStaysMissing() throws {
        var requests = 0
        let model = PrivacyPermissionsModel(
            grantStore: PluginCapabilityGrantStore(), manifests: { [] },
            accessibilityPermissionCheck: { true }, defaults: defaults,
            screenRecordingPermissionCheck: { false },
            screenRecordingPermissionRequest: { requests += 1; return false }
        )
        XCTAssertTrue(model.requestScreenRecordingPermission())
        XCTAssertEqual(requests, 1)
        XCTAssertFalse(model.screenRecordingPermissionGranted)

        XCTAssertFalse(model.requestScreenRecordingPermission(), "the caller opens System Settings")
        XCTAssertEqual(requests, 1)
    }
}
