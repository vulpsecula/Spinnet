import Foundation
import SpinnetCore
import SpinnetTestSupport
import XCTest
@testable import SpinnetHost

final class PluginDataManagementTests: XCTestCase {
    private func manifest(_ number: Int) throws -> PluginManifest {
        let fields = PluginReleaseFixture.manifest(id: "com.example.plugin\(number)", version: "1.0.0")
        return try JSONDecoder().decode(PluginManifest.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    func testManagementPagesRowsAndConstructsAccessDetailsOnlyOnRequest() throws {
        let manifests = try (0..<25).map(manifest)
        let model = PluginDataManagementModel(manifests: { manifests }, refused: { [] })
        model.runInBackground = { $0() }
        model.deliver = { $0() }
        model.retainedPluginData = { [RetainedPluginData(id: PluginID("removed.plugin"), name: "Removed", source: .unknown)] }
        model.refresh()
        XCTAssertEqual(model.entries.count, 26)
        XCTAssertEqual(model.visible.count, 20)
        XCTAssertTrue(model.expanded.isEmpty)
        model.showMore()
        XCTAssertEqual(model.visible.count, 26)
        model.search = "removed.plugin"
        XCTAssertEqual(model.visible.map(\.id), [PluginID("removed.plugin")])
        XCTAssertEqual(model.visibleCount, 20)
        model.search = ""
        model.toggleDetails(manifests[0].id)
        XCTAssertEqual(model.expanded, [manifests[0].id])
    }

    func testClearRequiresConfirmationAndRefreshesTheList() throws {
        let plugin = try manifest(1)
        var retained = [RetainedPluginData(id: PluginID("gone"), name: "Gone", source: .unknown)]
        var cleared: [PluginID] = []
        let model = PluginDataManagementModel(manifests: { [plugin] }, refused: { [] })
        model.runInBackground = { $0() }
        model.deliver = { $0() }
        model.retainedPluginData = { retained }
        model.clearPluginData = { id in cleared.append(id); retained.removeAll { $0.id == id } }
        model.refresh()
        let gone = try XCTUnwrap(model.entries.first { $0.id == PluginID("gone") })
        model.requestClear(gone)
        XCTAssertTrue(cleared.isEmpty)
        model.cancelClear()
        XCTAssertTrue(cleared.isEmpty)
        model.requestClear(gone)
        model.confirmClear()
        XCTAssertEqual(cleared, [gone.id])
        XCTAssertEqual(model.entries.map(\.id), [plugin.id])
    }

    func testSlowRefreshCannotReplaceANewerResult() {
        let model = PluginDataManagementModel(manifests: { [] }, refused: { [] })
        var work: [() -> Void] = []
        model.runInBackground = { work.append($0) }
        model.deliver = { $0() }
        model.retainedPluginData = { [RetainedPluginData(id: PluginID("old"), name: "Old", source: .unknown)] }
        model.refresh()
        XCTAssertTrue(model.isLoading)
        model.retainedPluginData = { [RetainedPluginData(id: PluginID("new"), name: "New", source: .unknown)] }
        model.refresh()
        work[1]()
        XCTAssertEqual(model.entries.map(\.id), [PluginID("new")])
        XCTAssertFalse(model.isLoading)
        work[0]()
        XCTAssertEqual(model.entries.map(\.id), [PluginID("new")])
    }

    func testPrivacyDoesNotReadEveryPluginsGrantsWhenItIsCreated() throws {
        var reads = 0
        let plugin = try manifest(1)
        let suite = "PluginDataManagement." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let privacy = PrivacyPermissionsModel(grantStore: PluginCapabilityGrantStore(),
                                              manifests: { reads += 1; return [plugin] },
                                              accessibilityPermissionCheck: { true }, defaults: defaults,
                                              backgroundOperationsCheck: { .notEnabled })
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(privacy.capabilityGrants(for: plugin).count, plugin.capabilities.count)
        XCTAssertEqual(reads, 0)
    }

    func testCredentialCleanupDoesNotMatchAnotherPluginsAccountPrefix() {
        let accounts = ["plugin/key", "plugin2/key", "plugin/nested/key", "plugin/second"]
        XCTAssertEqual(KeychainPluginCredentialStore.references(for: PluginID("plugin"), accounts: accounts), ["key", "second"])
        XCTAssertEqual(KeychainPluginCredentialStore.references(for: PluginID("plugin/nested"), accounts: accounts), ["key"])
    }
}
