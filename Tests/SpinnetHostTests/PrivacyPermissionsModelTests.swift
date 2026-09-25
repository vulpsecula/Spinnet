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
        // signals synchronously so grantRequestedAccess can iterate freshly
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

    func testAllowingAnInstallGrantsTheAccessItAskedFor() throws {
        let m = try manifest(capabilities: [.readSelectedText, .writeClipboard])
        let model = makeModel(manifests: [m])

        model.grantRequestedAccess(m, [.readSelectedText, .writeClipboard])

        XCTAssertTrue(model.pendingCapabilityRequests(for: m).isEmpty)
        XCTAssertTrue(model.capabilityGrants.allSatisfy { $0.decision == .granted })
    }

    func testAllowingAnInstallLeavesADecisionAlreadyMade() throws {
        let m = try manifest(capabilities: [.readSelectedText, .writeClipboard])
        let store = PluginCapabilityGrantStore()
        store.setDecision(.denied, for: m.id, pluginVersion: m.version, capability: .writeClipboard)
        let model = makeModel(manifests: [m], grantStore: store)

        model.grantRequestedAccess(m, [.readSelectedText, .writeClipboard])

        XCTAssertEqual(store.decision(for: m.id, pluginVersion: m.version, capability: .readSelectedText), .granted)
        XCTAssertEqual(store.decision(for: m.id, pluginVersion: m.version, capability: .writeClipboard), .denied)
    }

    func testPluginSettingsOpensForTheChosenPlugin() throws {
        let m = try manifest()
        let model = makeModel(manifests: [m])

        model.showPluginSettings(m.id)

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

    /// macOS applies a new Screen Recording grant only after Spinnet
    /// relaunches, so once the user has asked for it this session and it still
    /// reads as missing, the page offers a restart rather than asking again.
    func testAScreenRecordingRequestThisSessionAwaitsARestartUntilGranted() throws {
        var granted = false
        let model = PrivacyPermissionsModel(
            grantStore: PluginCapabilityGrantStore(), manifests: { [] },
            accessibilityPermissionCheck: { true }, defaults: defaults,
            screenRecordingPermissionCheck: { granted },
            screenRecordingPermissionRequest: { false }
        )
        XCTAssertFalse(model.screenRecordingAwaitsRestart, "nothing was asked for yet")

        model.requestScreenRecordingPermission()
        XCTAssertTrue(model.screenRecordingAwaitsRestart)

        // A second press goes to System Settings; the restart is still owed.
        model.requestScreenRecordingPermission()
        XCTAssertTrue(model.screenRecordingAwaitsRestart)

        granted = true
        model.refreshSystemPermissionStatus()
        XCTAssertFalse(model.screenRecordingAwaitsRestart)
    }

    func testAnEarlierSessionsRequestDoesNotAwaitARestart() throws {
        defaults.set(true, forKey: "privacy.screen-recording-requested")
        let model = PrivacyPermissionsModel(
            grantStore: PluginCapabilityGrantStore(), manifests: { [] },
            accessibilityPermissionCheck: { true }, defaults: defaults,
            screenRecordingPermissionCheck: { false },
            screenRecordingPermissionRequest: { false }
        )
        XCTAssertFalse(model.screenRecordingAwaitsRestart)
    }

    /// The first-run guide asks for Accessibility; once it is granted there is
    /// nothing left to guide, whether it was granted before launch or while
    /// Spinnet runs.
    func testThePermissionGuideIsNotShownOnceAccessibilityIsGranted() throws {
        let grantedBeforeLaunch = try XCTUnwrap(UserDefaults(suiteName: "SpinnetHostTests.Guide.\(UUID().uuidString)"))
        XCTAssertFalse(PrivacyPermissionsModel(grantStore: PluginCapabilityGrantStore(), manifests: { [] },
                                               accessibilityPermissionCheck: { true },
                                               defaults: grantedBeforeLaunch).permissionGuidePresented)

        var granted = false
        let model = makeModel(manifests: [], accessibilityGranted: { granted })
        XCTAssertTrue(model.permissionGuidePresented, "a first run without Accessibility shows the guide")
        granted = true
        model.refreshSystemPermissionStatus()
        XCTAssertFalse(model.permissionGuidePresented)

        granted = false
        XCTAssertFalse(makeModel(manifests: [], accessibilityGranted: { granted }).permissionGuidePresented,
                       "a guide that has done its job stays dismissed, even if access is later lost")
    }
}
