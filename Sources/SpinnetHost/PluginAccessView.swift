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

    var body: some View {
        let disclosure = PluginPermissionDisclosure(manifest: manifest, commandIDs: commandIDs, inputs: inputs)
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
                }
            }, id: \.self) { capability in
                HStack {
                    Text(capability.title)
                    Spacer()
                    let granted = grants.first {
                        $0.pluginID == manifest.id && $0.pluginVersion == manifest.version && $0.capability == capability
                    }?.decision == .granted
                    Text(granted ? "Granted" : "Unavailable").foregroundStyle(.secondary)
                    Button(granted ? "Revoke Access" : "Grant Access") {
                        setDecision(granted ? .denied : .granted, manifest.id, manifest.version, capability)
                    }
                    .accessibilityLabel("\(granted ? "Revoke Access" : "Grant Access"): \(manifest.name), \(capability.title)")
                }
            }
            Text("Access applies Plugin-wide. Denied Commands remain unavailable; Menu Items are preserved.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct PluginConsentSheet: View {
    @ObservedObject var model: SettingsWindowModel
    let manifest: PluginManifest

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.installationConsentPresented ? "Plugin Installed — Review Access" : "Plugin Settings")
                .font(.title2.weight(.semibold))
            ScrollView {
                PluginAccessView(manifest: manifest, grants: model.capabilityGrants,
                                 setDecision: model.setCapabilityDecision)
            }
            HStack {
                if model.installationConsentPresented {
                    Button("Deny Access") { model.finishPluginConsent(grant: false) }
                    Spacer()
                    Button("Grant Declared Access") { model.finishPluginConsent(grant: true) }
                } else {
                    Spacer()
                    Button("Done") { model.pluginSettingsManifest = nil }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 600, height: 640)
    }
}

struct MenuItemAccessSummary: View {
    @ObservedObject var model: SettingsWindowModel
    let manifest: PluginManifest
    let commandIDs: Set<CommandID>
    let inputs: [CommandID: JSONValue]

    var body: some View {
        DisclosureGroup("Selected Commands — Access") {
            PluginAccessView(manifest: manifest, grants: model.capabilityGrants,
                             commandIDs: commandIDs, inputs: inputs, setDecision: model.setCapabilityDecision)
        }
    }
}
