import Combine
import Foundation
import SpinnetCore

/// Owns the three layers of authority the Privacy & Permissions page presents:
/// the Host's System Permissions, the Capabilities granted to each Plugin, and
/// the consent sheet shown when a Plugin asks for something new.
///
/// Authority decides what a Menu Item can do, so every change here has to reach
/// the Menu Editor: a revoked Capability or a lost System Permission turns
/// Actions unavailable. `onAuthorityChanged` is that signal, and it fires for
/// grant edits, permission refreshes, and grants changed by another window.
final class PrivacyPermissionsModel: ObservableObject {
    @Published private(set) var capabilityGrants: [PluginCapabilityGrant] = []
    @Published private(set) var accessibilityPermissionGranted: Bool

    /// The Plugin whose access sheet is open, for review or for consent.
    @Published var pluginSettingsManifest: PluginManifest?
    /// True when that sheet is an install-time consent prompt rather than a
    /// review of decisions already made.
    @Published var installationConsentPresented = false

    @Published var permissionGuidePresented: Bool {
        didSet {
            if !permissionGuidePresented { defaults.set(true, forKey: Keys.permissionGuideShown) }
        }
    }

    /// Fires whenever authority changes in a way that can alter Menu Item
    /// availability.
    var onAuthorityChanged: (() -> Void)?
    /// Fires with the full grant set so the Host can re-authorize running work.
    var onGrantsChanged: (([PluginCapabilityGrant]) -> Void)?

    private enum Keys {
        static let permissionGuideShown = "privacy.permission-guide-shown"
    }

    private let grantStore: PluginCapabilityGrantStore
    private let manifests: () -> [PluginManifest]
    private let accessibilityPermissionCheck: () -> Bool
    private let defaults: UserDefaults
    private var grantObserver: UUID?

    init(
        grantStore: PluginCapabilityGrantStore,
        manifests: @escaping () -> [PluginManifest],
        accessibilityPermissionCheck: @escaping () -> Bool,
        defaults: UserDefaults
    ) {
        self.grantStore = grantStore
        self.manifests = manifests
        self.accessibilityPermissionCheck = accessibilityPermissionCheck
        self.defaults = defaults
        accessibilityPermissionGranted = accessibilityPermissionCheck()
        permissionGuidePresented = !defaults.bool(forKey: Keys.permissionGuideShown)
        refreshCapabilityGrants()

        // Another window can change a decision. Republishing off the main
        // thread would fault SwiftUI, so hop when the notification does not
        // already arrive there.
        grantObserver = grantStore.observeChanges { [weak self] in
            let refresh = { [weak self] in
                self?.refreshCapabilityGrants()
                self?.onAuthorityChanged?()
            }
            if Thread.isMainThread { refresh() } else { DispatchQueue.main.async(execute: refresh) }
        }
    }

    deinit {
        if let grantObserver { grantStore.removeChangeObserver(grantObserver) }
    }

    // MARK: System Permissions

    func refreshSystemPermissionStatus() {
        accessibilityPermissionGranted = accessibilityPermissionCheck()
        onAuthorityChanged?()
    }

    func dismissPermissionGuide() {
        permissionGuidePresented = false
    }

    // MARK: Capabilities

    func refreshCapabilityGrants() {
        capabilityGrants = manifests().flatMap { manifest in
            manifest.capabilities.map { capability in
                PluginCapabilityGrant(
                    pluginID: manifest.id,
                    pluginVersion: manifest.version,
                    capability: capability,
                    decision: grantStore.decision(for: manifest.id, pluginVersion: manifest.version,
                                                  capability: capability, scope: manifest.scope(for: capability)),
                    scope: manifest.scope(for: capability)
                )
            }
        }
    }

    func setCapabilityDecision(
        _ decision: PluginCapabilityGrantDecision,
        for pluginID: PluginID,
        pluginVersion: String,
        capability: PluginCapability
    ) {
        grantStore.setDecision(
            decision,
            for: pluginID,
            pluginVersion: pluginVersion,
            capability: capability,
            scope: manifests().first { $0.id == pluginID && $0.version == pluginVersion }?.scope(for: capability)
        )
        refreshCapabilityGrants()
        onAuthorityChanged?()
        onGrantsChanged?(grantStore.allGrants)
    }

    /// Capabilities this Plugin declares that have no decision yet. An update
    /// that widens a scope lands here again even when its version is unchanged.
    func pendingCapabilityRequests(for manifest: PluginManifest) -> [PluginCapability] {
        manifest.capabilities.filter {
            grantStore.decision(for: manifest.id, pluginVersion: manifest.version,
                                capability: $0, scope: manifest.scope(for: $0)) == .notDetermined
        }
    }

    // MARK: Consent and review sheets

    /// Opens the consent sheet for a freshly installed or updated Plugin.
    /// Returns false when nothing needs consent, so the caller can report a
    /// plain success instead.
    @discardableResult
    func beginInstallationConsent(for manifest: PluginManifest) -> Bool {
        refreshCapabilityGrants()
        installationConsentPresented = !pendingCapabilityRequests(for: manifest).isEmpty
        pluginSettingsManifest = installationConsentPresented ? manifest : nil
        return installationConsentPresented
    }

    /// Opens the same sheet for review, from the Library or a Menu Slot.
    func showPluginSettings(_ pluginID: PluginID) {
        installationConsentPresented = false
        refreshCapabilityGrants()
        pluginSettingsManifest = manifests().first { $0.id == pluginID }
    }

    /// Answers every outstanding request at once. Denying leaves decisions
    /// already granted untouched.
    func finishPluginConsent(grant: Bool) {
        guard let manifest = pluginSettingsManifest else { return }
        for capability in pendingCapabilityRequests(for: manifest) {
            setCapabilityDecision(grant ? .granted : .denied, for: manifest.id,
                                  pluginVersion: manifest.version, capability: capability)
        }
        pluginSettingsManifest = nil
        installationConsentPresented = false
    }
}
