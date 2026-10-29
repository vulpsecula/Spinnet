import AppKit
import Combine
import SpinnetCore
import SwiftUI

extension WelcomeGuideStep {
    var title: String {
        switch self {
        case .welcome: return "Welcome to Spinnet"
        case .systemPermissions: return "System Permissions"
        case .menuTrigger: return "Open the Menu"
        case .finish: return "You're Ready"
        }
    }
}

extension SettingsWindowModel {
    /// What the open Welcome Guide sheet presents, for the Settings seam.
    var welcomeGuideAccessibleNames: [String] {
        let guide = welcomeGuide
        var names = ["Welcome Guide", guide.step.title]
        switch guide.step {
        case .welcome:
            break
        case .systemPermissions:
            for permission in PluginSystemPermission.allCases {
                names.append("\(permission.title): \(privacy.statusTitle(for: permission))")
                names.append(privacy.actionTitle(for: permission).replacingOccurrences(of: "…", with: ""))
            }
        case .menuTrigger:
            names.append(contentsOf: ["Menu Trigger", "Mouse trigger", "Click & Drag", "Keyboard shortcut optional"])
        case .finish:
            names.append("Open Menu Editor")
        }
        if guide.canGoBack { names.append("Back") }
        if guide.step != .finish {
            names.append("Continue")
            names.append("Skip Welcome Guide")
        }
        return names
    }
}

/// The Welcome Guide sheet. Its trigger step embeds the Menu page's own
/// Menu Trigger controls, passed in by the Settings root view.
struct WelcomeGuideSheet<TriggerControls: View>: View {
    @ObservedObject var guide: WelcomeGuideModel
    @ObservedObject var privacy: PrivacyPermissionsModel
    let openURL: (URL) -> Bool
    let triggerControls: TriggerControls

    /// System Permissions change in System Settings while the sheet is open.
    private let permissionPoll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                stepIndicator
                Text(guide.step.title)
                    .font(.title.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                stepContent
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()
            controls
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
        }
        .frame(width: 620, height: 600)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Welcome Guide")
        .onReceive(permissionPoll) { _ in
            guard guide.step == .systemPermissions || guide.step == .menuTrigger else { return }
            privacy.refreshSystemPermissionStatus(includingBackgroundOperations: false)
        }
    }

    private var stepIndicator: some View {
        let steps = WelcomeGuideStep.allCases
        let index = steps.firstIndex(of: guide.step) ?? 0
        return Text("Step \(index + 1) of \(steps.count)")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch guide.step {
        case .welcome:
            Text("Spinnet opens a radial Menu wherever you are. This guide sets up the System Permissions Spinnet needs and how you open the Menu.")
                .fixedSize(horizontal: false, vertical: true)
            Text("You can change all of this later in Settings, and reopen this guide from General.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .systemPermissions:
            Text("Accessibility lets Spinnet see the mouse trigger and work with selected text. Screen Recording is needed only for screenshots.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(PluginSystemPermission.allCases, id: \.self) { permission in
                    permissionRow(permission)
                    if permission != PluginSystemPermission.allCases.last { Divider() }
                }
            }
            .padding(.horizontal, 14)
            .settingsCard()
        case .menuTrigger:
            ScrollView { triggerControls }
        case .finish:
            Text("Next, add Menu Items to your Slots in the Menu Editor. Plugins from the Library provide them.")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func permissionRow(_ permission: PluginSystemPermission) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: privacy.isGranted(permission) ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(privacy.isGranted(permission) ? Color.green : Color.orange)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(permission.title).font(.headline)
                Text(permission.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(privacy.statusTitle(for: permission))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(permission.title): \(privacy.statusTitle(for: permission))")
            }
            Spacer(minLength: 12)
            if !privacy.isGranted(permission) {
                let title = privacy.actionTitle(for: permission)
                Button(title) { privacy.performAction(for: permission, openURL: openURL) }
                    .controlSize(.small)
                    .accessibilityLabel(title.replacingOccurrences(of: "…", with: ""))
            }
        }
        .padding(.vertical, 12)
    }

    private var controls: some View {
        HStack {
            if guide.step != .finish {
                Button("Skip Welcome Guide", action: guide.skip)
                    .accessibilityLabel("Skip Welcome Guide")
            }
            Spacer()
            if guide.canGoBack {
                Button("Back", action: guide.back)
            }
            if guide.step == .finish {
                Button("Open Menu Editor", action: guide.complete)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Continue", action: guide.next)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
