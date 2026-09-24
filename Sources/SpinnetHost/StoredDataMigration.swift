import Foundation
import SpinnetCore

/// What a launch does to the data an earlier Spinnet saved, before anything
/// runs: Actions move off retired Commands and into Plugin Settings, and
/// capability decisions line up with the Plugins this launch registered.
///
/// It lives apart from the application delegate so the regression baseline's
/// fixtures go through exactly the steps a launch takes.
enum StoredDataMigration {
    /// The stored configuration brought up to date. Plugin Settings and the
    /// Screenshot Plugin Settings a migration seeds are written as it runs.
    static func migrate(
        _ stored: HostConfiguration,
        registry: PluginRegistry,
        pluginSettings: PluginSettingsStore?,
        defaults: UserDefaults
    ) throws -> HostConfiguration {
        // Menu Items built from the retired Screenshot Plugin move onto
        // the Host Commands once, and the result is kept.
        ScreenshotPluginMigration.seedSettings(from: stored, in: defaults)
        var configuration = try ScreenshotPluginMigration.migrate(stored) ?? stored
        // Translator 2 retired two Commands; their Actions move onto the new ones.
        configuration = try TranslatorCommandMigration.migrate(
            configuration, manifest: registry.package(for: TranslatorCommandMigration.pluginID)?.manifest
        ) ?? configuration
        // Actions from before their Plugin declared settings carried every
        // value; those move into Plugin Settings once.
        if let pluginSettings {
            let translator = TranslatorCommandMigration.pluginID
            if let renamed = TranslatorCommandMigration.migrateSettings(pluginSettings.values(for: translator)) {
                try pluginSettings.setValues(renamed, for: translator)
            }
            for manifest in registry.manifests() where manifest.hasSettings {
                let stored = pluginSettings.hasValues(for: manifest.id) ? pluginSettings.values(for: manifest.id) : nil
                guard let result = try PluginSettingsMigration.migrate(configuration, manifest: manifest,
                                                                      storedSettings: stored) else { continue }
                if let seeded = result.settings { try pluginSettings.setValues(seeded, for: manifest.id) }
                configuration = result.configuration
            }
        }
        return configuration
    }

    /// Restores saved decisions one at a time, as the user made them, so a
    /// scope keeps the hosts the user added to it.
    static func restoreCapabilityGrants(from data: Data, into grants: PluginCapabilityGrantStore) throws {
        for grant in try JSONDecoder().decode([PluginCapabilityGrant].self, from: data) {
            grants.setDecision(
                grant.decision,
                for: grant.pluginID,
                pluginVersion: grant.pluginVersion,
                capability: grant.capability,
                scope: grant.scope
            )
        }
    }

    /// Lines decisions up with the Plugins this launch registered: each
    /// declared Capability gets an entry, and, when `discardingOthers`, the
    /// decisions of Plugins that are gone are dropped.
    static func reconcileCapabilityGrants(
        _ grants: PluginCapabilityGrantStore,
        with manifests: [PluginManifest],
        discardingOthers: Bool
    ) {
        // Before decisions for Plugins that are gone are discarded below.
        ScreenshotPluginMigration.carryGrant(in: grants)
        for manifest in manifests {
            grants.register(pluginID: manifest.id, pluginVersion: manifest.version, capabilities: manifest.capabilities)
        }
        if discardingOthers {
            grants.discardGrants(outside: Set(manifests.map(\.id)))
        }
    }

    static func encodeCapabilityGrants(_ grants: PluginCapabilityGrantStore) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(grants.allGrants)
    }
}
