import Foundation
import SpinnetCore

/// What a launch does to the data an earlier Spinnet saved, before anything
/// runs: Actions move off retired Commands as each Plugin's manifest declares
/// and into Plugin Settings, and capability decisions line up with the Plugins
/// this launch registered.
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
        // Before Plugin Settings take anything from an Action, so an input a
        // Plugin drops is not moved into its settings instead.
        for manifest in registry.manifests() {
            configuration = try applyMigrations(declaredBy: manifest, to: configuration, pluginSettings: pluginSettings)
        }
        // Commands that ran a script and now open a Deep Link Template keep
        // their Actions.
        configuration = try DeepLinkMigration.migrate(configuration, registry: registry) ?? configuration
        // Actions from before their Plugin declared settings carried every
        // value; those move into Plugin Settings once.
        if let pluginSettings {
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

    /// The configuration with one Plugin's manifest `migrations` applied, and
    /// its stored Plugin Settings renamed as they declare. It runs whenever
    /// the Host registers or updates the Plugin, and changes nothing the
    /// second time.
    static func applyMigrations(
        declaredBy manifest: PluginManifest,
        to configuration: HostConfiguration,
        pluginSettings: PluginSettingsStore?
    ) throws -> HostConfiguration {
        if let pluginSettings, let renamed = manifest.migrateSettings(pluginSettings.values(for: manifest.id)) {
            try pluginSettings.setValues(renamed, for: manifest.id)
        }
        return try manifest.migrate(configuration) ?? configuration
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
        // A decision on routes the Host reviewed carries over to Deep Link
        // Templates only if they open the same links.
        DeepLinkMigration.carryGrants(in: grants, for: manifests)
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
