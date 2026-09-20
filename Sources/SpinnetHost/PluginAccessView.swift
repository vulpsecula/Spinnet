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

    var body: some View {
        let disclosure = PluginPermissionDisclosure(manifest: manifest, commandIDs: commandIDs, inputs: inputs,
                                                    consentedHTTPSHosts: consentedHTTPSHosts)
        VStack(alignment: .leading, spacing: 12) {
            Text("\(manifest.name) · \(manifest.version)").font(.headline)
            ForEach(PluginConsentGroup.allCases, id: \.self) { group in
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.rawValue).font(.subheadline.weight(.semibold))
                    Text(disclosure.details(for: group)).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
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
                    Text(optional ? "\(capability.title) · Optional" : capability.title)
                    Spacer()
                    let decision = grants.first {
                        $0.pluginID == manifest.id && $0.pluginVersion == manifest.version && $0.capability == capability
                    }?.decision ?? .notDetermined
                    let granted = decision == .granted
                    Text(decision == .notDetermined ? "Not reviewed" : decision.title).foregroundStyle(.secondary)
                    Button(granted ? "Revoke Access" : "Grant Access") {
                        setDecision(granted ? .denied : .granted, manifest.id, manifest.version, capability)
                    }
                    .accessibilityLabel("\(granted ? "Revoke Access" : "Grant Access"): \(manifest.name), \(capability.title)")
                }
            }
            Text("Access applies Plugin-wide. Commands requiring denied access remain unavailable; optional access is skipped when not granted. Menu Items are preserved.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct PluginConsentSheet: View {
    @ObservedObject var privacy: PrivacyPermissionsModel
    let manifest: PluginManifest
    var reviewInstallation: Bool? = nil
    var onDone: (() -> Void)? = nil
    /// The Screenshot entry's own options, shown above its access.
    var screenshotSettings: ScreenshotSettingsModel? = nil
    /// The Plugin's declared settings, saved by Done.
    var pluginSettings: PluginSettingsModel? = nil

    private var isInstallation: Bool { reviewInstallation ?? privacy.installationConsentPresented }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isInstallation ? "Plugin Installed — Review Access" : "Plugin Settings")
                .font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let screenshotSettings, !isInstallation {
                        ScreenshotSettingsView(model: screenshotSettings)
                    }
                    if let pluginSettings, !isInstallation {
                        PluginSettingsForm(model: pluginSettings)
                    }
                    PluginAccessView(manifest: manifest, grants: privacy.capabilityGrants,
                                     setDecision: privacy.setCapabilityDecision,
                                     consentedHTTPSHosts: privacy.consentedHTTPSHosts(for: manifest))
                }
            }
            HStack {
                if isInstallation {
                    Button("Deny New Requests") { privacy.finishPluginConsent(grant: false) }
                    Spacer()
                    Button("Grant New Requests") { privacy.finishPluginConsent(grant: true) }
                } else {
                    if pluginSettings != nil {
                        Button("Cancel", action: close)
                            .keyboardShortcut(.cancelAction)
                    }
                    Spacer()
                    Button(pluginSettings == nil ? "Done" : "Save") {
                        // Settings that do not save keep the sheet open with the reason.
                        if let pluginSettings, !pluginSettings.save() { return }
                        close()
                    }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 600, height: 640)
    }

    private func close() {
        if let onDone { onDone() } else { privacy.pluginSettingsManifest = nil }
    }
}

struct MenuItemAccessSummary: View {
    @ObservedObject var privacy: PrivacyPermissionsModel
    let manifest: PluginManifest
    let commandIDs: Set<CommandID>
    let inputs: [CommandID: JSONValue]
    @State private var showingPluginSettings = false

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
        DisclosureGroup("Selected Commands — Access") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(capabilities, id: \.self) { capability in
                    Label("\(capability.title): \(granted(capability) ? "Granted" : "Not granted")",
                          systemImage: granted(capability) ? "checkmark.circle" : "lock")
                }
                ForEach(optionalCapabilities, id: \.self) { capability in
                    Label("\(capability.title) (Optional): \(granted(capability) ? "Granted" : "Not granted")",
                          systemImage: granted(capability) ? "checkmark.circle" : "lock")
                }
                if capabilities.isEmpty && optionalCapabilities.isEmpty {
                    Text("No Plugin access required for these Commands.")
                }
                if needsScreenRecording {
                    // The Screenshot Configuration Sheet is one of the two
                    // places the Screen Recording prompt may come from.
                    if privacy.screenRecordingAwaitsRestart && HostRelaunch.isAvailable {
                        Label("Screen Recording: Restart Spinnet to finish", systemImage: "arrow.clockwise")
                        Button("Restart Spinnet") { HostRelaunch.relaunch() }
                            .accessibilityLabel("Restart Spinnet to finish enabling Screen Recording")
                    } else {
                        Label("Screen Recording: Not granted", systemImage: "lock")
                        Button("Enable Screen Recording…") {
                            if !privacy.requestScreenRecordingPermission() { openScreenRecordingSettings() }
                        }
                        .accessibilityLabel("Enable Screen Recording")
                    }
                }
                Text("Manage Plugin-wide access in Library’s Plugin Settings. Your Slot edits will be kept while you open settings.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Plugin Settings") { showingPluginSettings = true }
                    .accessibilityLabel("Open Plugin Settings for \(manifest.name)")
            }
            .padding(.top, 8)
        }
        .sheet(isPresented: $showingPluginSettings) {
            PluginConsentSheet(privacy: privacy, manifest: manifest, reviewInstallation: false,
                               onDone: { showingPluginSettings = false })
        }
    }
}
