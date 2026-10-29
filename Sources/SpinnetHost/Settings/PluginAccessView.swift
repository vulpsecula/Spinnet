import AppKit
import SwiftUI
import SpinnetCore

/// Shared Host-rendered disclosure for installation, Plugin Settings, and
/// Privacy & Permissions. No Plugin code participates in the consent UI.
struct PluginAccessView: View {
    let manifest: PluginManifest
    let grants: [PluginCapabilityGrant]
    var commandIDs: Set<CommandID>? = nil
    var inputs: [CommandID: JSONValue] = [:]
    let setDecision: (PluginCapabilityGrantDecision, PluginID, String, PluginCapability) -> Void
    /// Hosts the user added to the contact scope, such as a self-hosted endpoint.
    var consentedHTTPSHosts: [String] = []
    /// Before an install there are no decisions yet, only what is asked for.
    var showsDecisions = true

    var body: some View {
        let disclosure = PluginPermissionDisclosure(manifest: manifest, commandIDs: commandIDs, inputs: inputs,
                                                    consentedHTTPSHosts: consentedHTTPSHosts)
        VStack(alignment: .leading, spacing: 12) {
            Text("\(manifest.name) · \(manifest.version)").font(.headline)
            ForEach(PluginConsentGroup.allCases, id: \.self) { group in
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.localizedTitle).font(.subheadline.weight(.semibold))
                    Text(disclosure.details(for: group)).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if showsDecisions {
                ForEach(manifest.capabilities.filter { capability in
                    commandIDs == nil || disclosure.commands.contains {
                        manifest.requiredCapabilities(for: $0, input: inputs[$0.id]).contains(capability)
                            || manifest.optionalCapabilities(forCommand: $0).contains(capability)
                    }
                }, id: \.self) { capability in
                    HStack {
                        let optional = disclosure.commands.contains {
                            manifest.optionalCapabilities(forCommand: $0).contains(capability)
                        }
                        Text(optional ? localized("\(capability.localizedTitle) · Optional") : capability.localizedTitle)
                        Spacer()
                        let decision = grants.first {
                            $0.pluginID == manifest.id && $0.pluginVersion == manifest.version && $0.capability == capability
                        }?.decision ?? .notDetermined
                        let granted = decision == .granted
                        Text(decision == .notDetermined ? localized("Not reviewed") : decision.localizedTitle).foregroundStyle(.secondary)
                        Button(granted ? localized("Revoke Access") : localized("Grant Access")) {
                            setDecision(granted ? .denied : .granted, manifest.id, manifest.version, capability)
                        }
                        .accessibilityLabel("\(granted ? localized("Revoke Access") : localized("Grant Access")): \(manifest.name), \(capability.localizedTitle)")
                    }
                }
                Text(localized("Access applies Plugin-wide. Commands requiring denied access remain unavailable; optional access is skipped when not granted. Menu Items are preserved."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Asks the user to allow an install before anything is copied. Installing
/// grants the access listed; each grant can be revoked later in Plugin
/// Settings.
struct PluginInstallSheet: View {
    let installation: PendingPluginInstallation
    let onCancel: () -> Void
    let onInstall: () -> Void

    private var manifest: PluginManifest { installation.review.manifest }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(localized("Install \(manifest.name)?"))
                .font(.title2.weight(.semibold))
            Text(localized("Installing allows \(manifest.name) to use:"))
                .font(.subheadline)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(installation.review.requestedAccess, id: \.self) { capability in
                    Label(capability.localizedTitle, systemImage: "checkmark.shield")
                }
            }
            ScrollView {
                PluginAccessView(manifest: manifest, grants: [], setDecision: { _, _, _, _ in },
                                 showsDecisions: false)
            }
            Text(localized("You can revoke access later in Plugin Settings."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(localized("Cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(localized("Install"), action: onInstall)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 600, height: 560)
    }
}

struct PluginConsentSheet: View {
    @ObservedObject var privacy: PrivacyPermissionsModel
    let manifest: PluginManifest
    var onDone: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil
    var connections: ExternalAppConnectionsModel? = nil
    var requiresConnection = false
    /// The Screenshot entry's own options, shown above its access.
    var screenshotSettings: ScreenshotSettingsModel? = nil
    /// The Plugin's declared settings, saved by Save.
    var pluginSettings: PluginSettingsModel? = nil
    /// What the Plugin keeps in Plugin Storage.
    var pluginStorage: PluginStorageModel? = nil
    @State private var showingPermissions = false

    var body: some View {
        if showingPermissions {
            PluginPermissionsPage(privacy: privacy, manifest: manifest,
                                  onDone: { showingPermissions = false })
        } else {
            VStack(alignment: .leading, spacing: 16) {
                Text(localized("Plugin Settings"))
                    .font(.title2.weight(.semibold))
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let screenshotSettings {
                            ScreenshotSettingsView(model: screenshotSettings)
                        }
                        if let pluginSettings {
                            PluginSettingsForm(model: pluginSettings)
                        }
                        if let connections { ExternalAppConnectionSettings(model: connections) }
                        PluginPermissionsLink(pluginName: manifest.name,
                                              open: { showingPermissions = true })
                        if let pluginStorage {
                            PluginStorageSection(model: pluginStorage, pluginName: manifest.name)
                        }
                    }
                }
                HStack {
                    if pluginSettings != nil || requiresConnection {
                        Button(localized("Cancel"), action: { if let onCancel { onCancel() } else { close() } })
                            .keyboardShortcut(.cancelAction)
                    }
                    Spacer()
                    Button(pluginSettings == nil ? localized("Done") : localized("Save")) {
                        // Settings that do not save keep the sheet open with the reason.
                        if let pluginSettings, !pluginSettings.save() { return }
                        close()
                    }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(width: 600, height: 640)
        }
    }

    private func close() {
        if let onDone { onDone() } else { privacy.pluginSettingsManifest = nil }
    }
}

/// A separate immediate-action surface: returning never saves or discards a
/// Plugin Settings draft in the presenting sheet.
struct PluginPermissionsPage: View {
    @ObservedObject var privacy: PrivacyPermissionsModel
    let manifest: PluginManifest
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(localized("Plugin Permissions")).font(.title2.weight(.semibold))
            Text(localized("Changes take effect immediately and apply to all Actions from this Plugin."))
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                PluginAccessView(manifest: manifest, grants: privacy.capabilityGrants,
                                 setDecision: privacy.setCapabilityDecision,
                                 consentedHTTPSHosts: privacy.consentedHTTPSHosts(for: manifest))
            }
            HStack {
                Spacer()
                Button(localized("Done"), action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 600, height: 640)
        .onExitCommand(perform: onDone)
    }
}

private struct PluginPermissionsLink: View {
    let pluginName: String
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(localized("Permissions")).font(.headline)
            Text(localized("Manage access separately. Permission changes take effect immediately; Save and Cancel apply only to Plugin Settings."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(localized("Manage Permissions"), action: open)
                .accessibilityLabel(localized("Manage Permissions for \(pluginName)"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct MenuItemAccessSummary: View {
    @ObservedObject var privacy: PrivacyPermissionsModel
    let manifest: PluginManifest
    let commandIDs: Set<CommandID>
    let inputs: [CommandID: JSONValue]
    @State private var showingPermissions = false

    private var capabilities: [PluginCapability] {
        manifest.capabilities.filter { capability in
            manifest.commands.contains { command in
                commandIDs.contains(command.id)
                    && manifest.requiredCapabilities(for: command, input: inputs[command.id]).contains(capability)
            }
        }
    }

    private var optionalCapabilities: [PluginCapability] {
        manifest.capabilities.filter { capability in
            manifest.commands.contains { command in
                commandIDs.contains(command.id)
                    && manifest.optionalCapabilities(forCommand: command).contains(capability)
            }
        }
    }

    private var needsScreenRecording: Bool {
        !privacy.screenRecordingPermissionGranted && manifest.commands.contains { command in
            commandIDs.contains(command.id)
                && manifest.requiredSystemPermissions(for: command, input: inputs[command.id]).contains(.screenRecording)
        }
    }

    private func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    private func granted(_ capability: PluginCapability) -> Bool {
        privacy.capabilityGrants.contains {
            $0.pluginID == manifest.id && $0.pluginVersion == manifest.version
                && $0.capability == capability && $0.decision == .granted
        }
    }

    var body: some View {
        DisclosureGroup(localized("Selected Commands — Access")) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(capabilities, id: \.self) { capability in
                    Label("\(capability.localizedTitle): \(granted(capability) ? localized("Granted") : localized("Not granted"))",
                          systemImage: granted(capability) ? "checkmark.circle" : "lock")
                }
                ForEach(optionalCapabilities, id: \.self) { capability in
                    Label(granted(capability) ? localized("\(capability.localizedTitle) (Optional): Granted") : localized("\(capability.localizedTitle) (Optional): Not granted"),
                          systemImage: granted(capability) ? "checkmark.circle" : "lock")
                }
                if capabilities.isEmpty && optionalCapabilities.isEmpty {
                    Text(localized("No Plugin access required for these Commands."))
                }
                if needsScreenRecording {
                    // The Screenshot Configuration Sheet is one of the two
                    // places the Screen Recording prompt may come from.
                    if privacy.screenRecordingAwaitsRestart && HostRelaunch.isAvailable {
                        Label(localized("Screen Recording: Restart Spinnet to finish"), systemImage: "arrow.clockwise")
                        Button(localized("Restart Spinnet")) { HostRelaunch.relaunch() }
                            .accessibilityLabel(localized("Restart Spinnet to finish enabling Screen Recording"))
                    } else {
                        Label(localized("Screen Recording: Not granted"), systemImage: "lock")
                        Button(localized("Enable Screen Recording…")) {
                            if !privacy.requestScreenRecordingPermission() { openScreenRecordingSettings() }
                        }
                        .accessibilityLabel(localized("Enable Screen Recording"))
                    }
                }
                Text(localized("Permission changes apply immediately to all Actions from this Plugin. Your Menu Item edits are kept while you manage permissions."))
                    .font(.caption).foregroundStyle(.secondary)
                Button(localized("Manage Permissions")) { showingPermissions = true }
                    .accessibilityLabel(localized("Manage Permissions for \(manifest.name)"))
            }
            .padding(.top, 8)
        }
        .sheet(isPresented: $showingPermissions) {
            PluginPermissionsPage(privacy: privacy, manifest: manifest,
                                  onDone: { showingPermissions = false })
        }
    }
}
