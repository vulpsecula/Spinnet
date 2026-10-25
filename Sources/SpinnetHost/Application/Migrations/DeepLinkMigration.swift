import Foundation
import SpinnetCore

/// Before Plugins declared Deep Link Templates (ADR 0012), the Host itself
/// reviewed the links one External App Adapter could open, as an operation
/// family of that app, and the user's decision was stored on that family.
/// Once the Plugin declares templates instead, its scope differs, so the
/// decision would be asked for again. It carries over only when the Host
/// verifies here that the templates open exactly the links it had reviewed;
/// anything else is a new scope and needs new consent.
///
/// The retired review is data this check needs and nothing more: which
/// Command opens which link is the Plugin's, and no Command runs through it.
enum DeepLinkMigration {
    /// One operation family the Host used to turn into links itself, and
    /// every link it could open.
    struct RetiredReview {
        let bundleID: String
        let operationFamily: String
        let links: Set<String>
    }

    static let retiredReviews = [
        // Shottr's capture routes, as its URL scheme adapter built them.
        RetiredReview(bundleID: "cc.ffitch.shottr", operationFamily: "capture", links: Set([
            "area", "fullscreen", "window", "repeat", "scrolling", "scrolling/reverse", "append",
            "delayed=3", "delayed=5", "delayed=10"
        ].map { "shottr://grab/" + $0 }))
    ]

    /// Carries each decision made on a reviewed family over to templates
    /// that open the same links, unless the user already decided on them.
    /// Run at launch, before decisions are reconciled with the registry.
    static func carryGrants(in grants: PluginCapabilityGrantStore, for manifests: [PluginManifest]) {
        let stored = grants.allGrants
        for manifest in manifests {
            guard let declared = manifest.scope(for: .controlExternalApp),
                  grants.decision(for: manifest.id, pluginVersion: manifest.version,
                                  capability: .controlExternalApp, scope: declared) == .notDetermined,
                  let legacy = stored.first(where: {
                      $0.pluginID == manifest.id && $0.pluginVersion == manifest.version
                          && $0.capability == .controlExternalApp
                  }),
                  legacy.decision != .notDetermined,
                  let legacyScope = legacy.scope,
                  isEquivalent(legacyScope, to: declared) else { continue }
            grants.setDecision(legacy.decision, for: manifest.id, pluginVersion: manifest.version,
                               capability: .controlExternalApp, scope: declared)
        }
    }

    /// Whether `declared` allows the same Commands the same links as the
    /// reviewed family in `legacy`, and nothing else.
    static func isEquivalent(_ legacy: PluginCapabilityScope, to declared: PluginCapabilityScope) -> Bool {
        guard legacy.capability == declared.capability, legacy.commandIDs == declared.commandIDs,
              legacy.dataTypes == declared.dataTypes,
              legacy.includesExistingHostData == declared.includesExistingHostData,
              legacy.httpsHosts == declared.httpsHosts,
              legacy.externalApps.count == 1, declared.externalApps.count == 1,
              let before = legacy.externalApps.first, let after = declared.externalApps.first,
              before.operationFamilies.count == 1, before.deepLinkTemplates.isEmpty,
              after.bundleID == before.bundleID, after.operationFamilies.isEmpty,
              let review = retiredReviews.first(where: {
                  $0.bundleID == before.bundleID && $0.operationFamily == before.operationFamilies[0]
              }) else { return false }
        var links: Set<String> = []
        for template in after.deepLinkTemplates {
            guard let concrete = template.concreteLinks else { return false }
            links.formUnion(concrete)
        }
        return links == review.links
    }

    /// Actions built when a Command ran a script, whose Plugin now runs the
    /// same Command, by ID and title, as a Deep Link Template, move onto it
    /// with their IDs and inputs. The template is narrower than the script
    /// was, and it still needs the Plugin's grant. Nil when nothing moves.
    static func migrate(_ configuration: HostConfiguration, registry: PluginRegistry) throws -> HostConfiguration? {
        var changed = false
        let actions = try configuration.actions.map { action -> ActionConfiguration in
            guard action.execution == .javascript,
                  let command = registry.command(for: action.pluginID, commandID: action.commandID),
                  command.hostCommand == .openDeepLink, command.title == action.title else { return action }
            changed = true
            return try ActionConfiguration(id: action.id, pluginID: action.pluginID, command: command, input: action.input)
        }
        return changed ? try HostConfiguration(actions: actions, menu: configuration.menu) : nil
    }
}
