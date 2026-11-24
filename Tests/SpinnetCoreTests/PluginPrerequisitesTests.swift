import Foundation
import Testing
@testable import SpinnetCore

struct PluginPrerequisitesTests {
    private let bundleID = "com.spotify.client"
    private let play = CommandID("spotify.play")
    private let search = CommandID("spotify.search")

    @Test func missingExternalAppNamesTheRepairBeforeInstallation() throws {
        let package = try makePackage(target: spotify, affected: [play, search])
        let registry = PluginRegistry(externalAppExists: { _ in false })

        let prerequisite = try #require(registry.prerequisites(for: package).first)
        #expect(prerequisite.kind == .externalApp(bundleID: bundleID, displayName: "Spotify"))
        #expect(prerequisite.commandIDs == [play, search])
        #expect(!prerequisite.isSatisfied)
        #expect(prerequisite.reason.description == "Install Spotify to use Spotify Commands")

        try registry.register(package)
        #expect(registry.menuItemPreset(for: package.manifest.id)?.unavailableReason == .externalAppMissing("Spotify"))
    }

    @Test func missingExternalAppOnlyAffectsCommandsInItsScope() throws {
        let package = try makePackage(target: spotify, affected: [play])
        let registry = PluginRegistry(externalAppExists: { _ in false })

        let prerequisite = try #require(registry.prerequisites(for: package).first)
        #expect(prerequisite.commandIDs == [play])
        #expect(!prerequisite.isSatisfied)

        try registry.register(package)
        #expect(registry.menuItemPreset(for: package.manifest.id)?.isAvailable == true)
    }

    @Test func unnamedExternalAppUsesItsReviewedName() throws {
        let package = try makePackage(target: .init(bundleID: "com.hezongyidev.Bob", operationFamilies: ["translate"]),
                                      affected: [play])
        let registry = PluginRegistry(externalAppExists: { _ in false })

        let prerequisite = try #require(registry.prerequisites(for: package).first)
        #expect(prerequisite.kind == .externalApp(bundleID: "com.hezongyidev.Bob", displayName: "Bob"))
        #expect(!prerequisite.isSatisfied)
    }

    @Test func installedExternalAppSatisfiesThePrerequisite() throws {
        let package = try makePackage(target: spotify, affected: [play, search])
        let registry = PluginRegistry(externalAppExists: { $0 == bundleID })

        let prerequisite = try #require(registry.prerequisites(for: package).first)
        #expect(prerequisite.isSatisfied)
        try registry.register(package)
        #expect(registry.menuItemPreset(for: package.manifest.id)?.isAvailable == true)
    }

    @Test func unnamedExternalAppFallsBackToItsInstalledNameThenBundleID() throws {
        let target = PluginCapabilityScope.ExternalAppScope(bundleID: "com.example.player", operationFamilies: ["play"])
        let package = try makePackage(target: target, affected: [play])
        let installed = PluginRegistry(externalAppExists: { _ in true }, installedExternalAppName: { _ in "My Player" })

        #expect(installed.prerequisites(for: package).first?.kind
                == .externalApp(bundleID: target.bundleID, displayName: "My Player"))
        #expect(PluginRegistry().prerequisites(for: package).first?.kind
                == .externalApp(bundleID: target.bundleID, displayName: target.bundleID))
    }

    @Test func derivesHostPrerequisitesForAffectedCommands() throws {
        let capture = CommandID("capture")
        let task = CommandID("task")
        let manifest = try PluginManifest(
            id: PluginID("com.example.tools"), name: "Tools", version: "1.0.0",
            capabilities: [.captureScreen, .runReviewedToolTasks],
            capabilityScopes: [
                .init(capability: .captureScreen, commandIDs: [capture]),
                .init(capability: .runReviewedToolTasks, commandIDs: [task],
                      reviewedTools: [.init(tool: "homebrew", operations: ["refreshCatalog"], kinds: ["formula"])])
            ],
            commands: [
                .init(id: capture, title: "Capture", execution: .javascript, scriptPath: "capture.js"),
                .init(id: task, title: "Refresh", execution: .javascript, scriptPath: "refresh.js")
            ],
            settingsFields: [.init(kind: .text, title: "Name", key: "name")]
        )
        let package = PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/tools.spinnetplugin"), manifest: manifest)
        let registry = PluginRegistry(systemPermissionCheck: { _ in false }, backgroundOperationsEnabled: { false },
                                      pluginSettingsComplete: { _ in false })

        let unmet = registry.prerequisites(for: package).filter { !$0.isSatisfied }
        let affected = Dictionary(uniqueKeysWithValues: unmet.map { ($0.kind, $0.commandIDs) })
        #expect(affected == [
            .systemPermission(.screenRecording): [capture],
            .hostComponent(.backgroundOperations): [task]
        ])
    }

    private var spotify: PluginCapabilityScope.ExternalAppScope {
        .init(bundleID: bundleID, name: "Spotify",
              deepLinkTemplates: [.init(id: "play", url: "spotify://play")])
    }

    private func makePackage(target: PluginCapabilityScope.ExternalAppScope, affected: [CommandID]) throws -> PluginPackage {
        let manifest = try PluginManifest(
            id: PluginID("com.example.spotify"), name: "Spotify", version: "1.0.0",
            capabilities: [.controlExternalApp],
            capabilityScopes: [.init(capability: .controlExternalApp, commandIDs: affected, externalApps: [target])],
            commands: [
                .init(id: play, title: "Play", execution: .javascript, scriptPath: "play.js"),
                .init(id: search, title: "Search", execution: .javascript, scriptPath: "search.js")
            ]
        )
        return PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/playlist.spinnetplugin"), manifest: manifest)
    }
}
