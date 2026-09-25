import Foundation
import XCTest
@testable import SpinnetCore

final class PluginRemovalTests: XCTestCase {
    private var storeDirectory: URL?

    private func makeStore(
        shipping shipped: PluginPackage? = nil
    ) throws -> (URL, PluginRegistry, PluginCapabilityGrantStore, PluginInstallationStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        storeDirectory = directory
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let registry = PluginRegistry()
        let grants = PluginCapabilityGrantStore()
        return (directory, registry, grants, PluginInstallationStore(
            directory: directory, registry: registry, grants: grants, persistGrants: {},
            shippedPackages: { [shipped].compactMap { $0 } }
        ))
    }

    /// The package the app ships, as discovery would hand it over.
    private func makeShippedPackage() throws -> PluginPackage {
        let loaded = try ScriptedPackageFixture.load()
        return PluginPackage(
            rootURL: loaded.rootURL, manifest: loaded.manifest, origin: .bundled
        )
    }

    func testRemovingAnInstalledPluginDeletesItsCopyAndDoesNotComeBack() throws {
        let (directory, registry, grants, store) = try makeStore()
        let manifest = try store.install(from: ScriptedPackageFixture.write())
        grants.setDecision(.granted, for: manifest.id, pluginVersion: manifest.version,
                           capability: .readSelectedText)
        XCTAssertNotNil(registry.package(for: manifest.id))

        try store.uninstall(manifest.id)

        XCTAssertNil(registry.package(for: manifest.id))
        // A restore reads the index from disk, so this proves the index was
        // rewritten and not only the in-memory registry.
        try store.restore()
        XCTAssertNil(registry.package(for: manifest.id))
        let remaining = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )
        XCTAssertFalse(remaining.contains { $0.pathExtension == "spinnetplugin" })
    }

    func testRemovingAPluginForgetsTheAccessTheUserGrantedIt() throws {
        let (_, _, grants, store) = try makeStore()
        let manifest = try store.install(from: ScriptedPackageFixture.write())
        grants.setDecision(.granted, for: manifest.id, pluginVersion: manifest.version,
                           capability: .readSelectedText)

        try store.uninstall(manifest.id)

        XCTAssertEqual(
            grants.decision(for: manifest.id, pluginVersion: manifest.version,
                            capability: .readSelectedText),
            .notDetermined,
            "A reinstalled Plugin must ask again rather than inherit a decision"
        )
        XCTAssertTrue(grants.allGrants.allSatisfy { $0.pluginID != manifest.id })
    }

    func testRemovingABundledPluginIsRecordedSoItStaysRemovedAcrossLaunches() throws {
        let (directory, registry, grants, store) = try makeStore()
        let loaded = try ScriptedPackageFixture.load()
        try registry.register(PluginPackage(
            rootURL: loaded.rootURL, manifest: loaded.manifest, origin: .bundled
        ))

        try store.uninstall(loaded.manifest.id)

        XCTAssertNil(registry.package(for: loaded.manifest.id))
        // A second Host launch reads the record back rather than the registry.
        let relaunched = PluginInstallationStore(
            directory: directory, registry: PluginRegistry(), grants: grants, persistGrants: {}
        )
        XCTAssertTrue(try relaunched.removedPluginIDs().contains(loaded.manifest.id))
    }

    func testInstallingACopyOfARemovedShippedPluginRestoresTheShippedOne() throws {
        // A removed Bundled Plugin comes back like any other Plugin, by
        // installing a copy of its package. Registering that copy would put
        // the Plugin back with the weaker origin of a user install, and its
        // Host Surface would be refused from then on.
        let shipped = try makeShippedPackage()
        let (directory, registry, grants, store) = try makeStore(shipping: shipped)
        try registry.register(shipped)
        grants.setDecision(.granted, for: shipped.manifest.id,
                           pluginVersion: shipped.manifest.version,
                           capability: .readSelectedText)
        try store.uninstall(shipped.manifest.id)

        let manifest = try store.install(from: try ScriptedPackageFixture.write())

        XCTAssertEqual(manifest, shipped.manifest)
        XCTAssertEqual(registry.package(for: shipped.manifest.id)?.origin, .bundled)
        XCTAssertEqual(
            grants.decision(for: shipped.manifest.id,
                            pluginVersion: shipped.manifest.version,
                            capability: .readSelectedText),
            .notDetermined,
            "A Plugin coming back asks for access again"
        )
        XCTAssertFalse(try store.removedPluginIDs().contains(shipped.manifest.id))
        let copies = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "spinnetplugin" }
        XCTAssertTrue(copies.isEmpty, "The Plugin the app carries needs no second copy")
    }

    func testInstallingAPluginTheAppNoLongerShipsClearsItsRemovalRecord() throws {
        // An app update can drop a Bundled Plugin the user had removed. The
        // record of that removal only exists to suppress a shipped copy, and
        // left behind it would make the next launch drop the copy the user
        // installed themselves.
        let shipped = try makeShippedPackage()
        let (_, registry, grants, store) = try makeStore(shipping: shipped)
        try registry.register(shipped)
        try store.uninstall(shipped.manifest.id)

        let laterRegistry = PluginRegistry()
        let laterStore = PluginInstallationStore(
            directory: try XCTUnwrap(storeDirectory), registry: laterRegistry,
            grants: grants, persistGrants: {}
        )
        let manifest = try laterStore.install(from: try ScriptedPackageFixture.write())

        XCTAssertEqual(manifest.id, shipped.manifest.id)
        XCTAssertEqual(laterRegistry.package(for: shipped.manifest.id)?.origin, .installed)
        XCTAssertFalse(try laterStore.removedPluginIDs().contains(shipped.manifest.id))

        // A relaunch reads the index back and keeps the copy the user chose.
        let relaunchedRegistry = PluginRegistry()
        let relaunched = PluginInstallationStore(
            directory: try XCTUnwrap(storeDirectory), registry: relaunchedRegistry,
            grants: grants, persistGrants: {}
        )
        try relaunched.restore()
        XCTAssertNotNil(relaunchedRegistry.package(for: shipped.manifest.id))
    }

    func testRestoringAShippedPluginDropsTheUserCopyLeftUnderneathIt() throws {
        let shipped = try makeShippedPackage()
        let (directory, registry, _, store) = try makeStore(shipping: shipped)
        try store.install(from: try ScriptedPackageFixture.write())
        registry.unregister(shipped.manifest.id)
        try registry.register(shipped)
        try store.uninstall(shipped.manifest.id)

        try store.install(from: try ScriptedPackageFixture.write())

        XCTAssertEqual(registry.package(for: shipped.manifest.id)?.origin, .bundled)
        let copies = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "spinnetplugin" }
        XCTAssertTrue(copies.isEmpty, "The shipped copy owns the identity again")
        // A later launch must not find a user copy to register in its place.
        let relaunchedRegistry = PluginRegistry()
        try PluginInstallationStore(
            directory: directory, registry: relaunchedRegistry,
            grants: PluginCapabilityGrantStore(), persistGrants: {}
        ).restore()
        XCTAssertNil(relaunchedRegistry.package(for: shipped.manifest.id))
    }

    func testRemovingABundledPluginKeepsAShadowedInstalledCopyFromBringingItBack() throws {
        // A Plugin that shipped after an earlier version of it was installed
        // leaves the user's own copy indexed underneath the shipped one. The
        // removal is of the Plugin, not of whichever copy is on top.
        let (directory, registry, grants, store) = try makeStore()
        let manifest = try store.install(from: ScriptedPackageFixture.write())
        registry.unregister(manifest.id)
        let loaded = try ScriptedPackageFixture.load()
        try registry.register(PluginPackage(
            rootURL: loaded.rootURL, manifest: loaded.manifest, origin: .bundled
        ))

        try store.uninstall(manifest.id)

        let relaunchedRegistry = PluginRegistry()
        let relaunched = PluginInstallationStore(
            directory: directory, registry: relaunchedRegistry, grants: grants, persistGrants: {}
        )
        try relaunched.restore()

        XCTAssertNil(
            relaunchedRegistry.package(for: manifest.id),
            "A removed Plugin stays removed, whichever copy of it is on disk"
        )
    }

    func testStartupForgetsDecisionsLeftBehindByPluginsThatAreGone() throws {
        let grants = PluginCapabilityGrantStore()
        let present = PluginID("com.example.present")
        let gone = PluginID("com.example.gone")
        for pluginID in [present, gone] {
            grants.setDecision(.granted, for: pluginID, pluginVersion: "1.0.0",
                               capability: .readSelectedText)
        }

        grants.discardGrants(outside: [present])

        XCTAssertEqual(grants.decision(for: present, pluginVersion: "1.0.0",
                                       capability: .readSelectedText), .granted)
        XCTAssertEqual(grants.decision(for: gone, pluginVersion: "1.0.0",
                                       capability: .readSelectedText), .notDetermined)
        XCTAssertTrue(grants.allGrants.allSatisfy { $0.pluginID != gone })
    }

    func testInstallingThroughASymlinkStoresTheRealPackage() throws {
        let (directory, registry, _, store) = try makeStore()
        let real = try ScriptedPackageFixture.write()
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).spinnetplugin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        addTeardownBlock { try? FileManager.default.removeItem(at: link) }

        let manifest = try store.install(from: link)

        XCTAssertNotNil(registry.package(for: manifest.id))
        let installed = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "spinnetplugin" }
        )
        XCTAssertNotEqual(
            try installed.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, true,
            "The installed copy must be the package, not a link to it"
        )
        // Readable after the original is gone, which a copied link would not be.
        try FileManager.default.removeItem(at: real)
        XCTAssertNoThrow(try PluginManifestLoader.load(packageAt: installed))
    }

    func testAPackageContainingASymbolicLinkIsRefused() throws {
        let (directory, registry, _, store) = try makeStore()
        let source = try ScriptedPackageFixture.write()
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent("escape.js"),
            withDestinationURL: URL(fileURLWithPath: "/etc/passwd")
        )

        XCTAssertThrowsError(try store.install(from: source))

        XCTAssertNil(registry.package(for: ScriptedPackageFixture.pluginID))
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertFalse(leftovers.contains { $0.pathExtension == "spinnetplugin" },
                       "A refused package must not be left in the install directory")
    }

    func testAHostCommandCannotBeRemoved() throws {
        let (_, registry, _, store) = try makeStore()
        let command = CommandDeclaration(
            id: CommandID("builtin.open_url"), title: "Open URL", hostCommand: .openURL
        )
        let manifest = try PluginManifest(
            id: PluginID("com.spinnet.builtin.open-url"), name: "Open URL", version: "1.0.0",
            commands: [command],
            preset: MenuItemPresetDeclaration(readiness: .setupRequired, defaultPrimaryCommandID: command.id)
        )
        try registry.register(PluginPackage(
            rootURL: nil, manifest: manifest, origin: .hostCommand
        ))
        XCTAssertNil(registry.package(for: manifest.id)?.rootURL,
                     "A Host Command has no package directory to name")

        XCTAssertThrowsError(try store.uninstall(manifest.id))
        XCTAssertNotNil(registry.package(for: manifest.id))
    }

    func testRemovingAPluginLeavesTheMenuItemsThatUsedItInPlace() throws {
        let (_, registry, _, store) = try makeStore()
        let manifest = try store.install(from: ScriptedPackageFixture.write())
        let command = try XCTUnwrap(manifest.commands.first { $0.execution == .host })
        let action = try ActionConfiguration(
            id: ActionID("kept"), pluginID: manifest.id, command: command,
            input: .string("https://example.com")
        )
        let configuration = try HostConfiguration(
            actions: [action],
            menu: MenuConfiguration(items: [MenuItemConfiguration(primaryActionID: action.id)])
        )

        try store.uninstall(manifest.id)

        XCTAssertEqual(configuration.menu.items.first?.primaryActionID, action.id)
        XCTAssertFalse(registry.availability(for: action).isAvailable)
    }
}
