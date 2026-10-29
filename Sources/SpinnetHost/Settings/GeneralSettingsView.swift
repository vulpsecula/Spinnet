import AppKit
import SwiftUI

/// The General page: app-wide preferences, and in a DEBUG Host the
/// Developer section last.
struct GeneralSettingsView: View {
    @ObservedObject var model: SettingsWindowModel
    @ObservedObject var launchAtLogin: LaunchAtLoginModel
    @ObservedObject var pluginUpdates: PluginUpdatesModel
    @ObservedObject var interfaceLanguage: InterfaceLanguageModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                pageHeader(title: SettingsPage.general.title,
                           description: localized("App-wide preferences for Spinnet."))

                VStack(spacing: 0) {
                    launchAtLoginRow
                    Divider()
                    toggleRow(
                        localized("Show Status Item"), isOn: $model.showsStatusItem,
                        detail: localized("When off, the Status Item still appears while a Task or Effect is ongoing. Open Spinnet again to show Settings.")
                    )
                    Divider()
                    InterfaceLanguageRow(language: interfaceLanguage)
                    Divider()
                    welcomeGuideRow
                }
                .padding(.horizontal, 18)
                .settingsCard()

                MenuOpeningDelayRow(trigger: model.trigger)
                    .padding(.horizontal, 18)
                    .settingsCard()

                PluginUpdateChecksSection(updates: pluginUpdates, showLibrary: { model.selectPage(.menu) })
                    .padding(.horizontal, 18)
                    .settingsCard()

                SpinnetReleaseChecksSection(releases: model.spinnetReleases)
                    .padding(.horizontal, 18)
                    .settingsCard()

                #if DEBUG
                if let tools = model.developerTools {
                    DeveloperSettingsSection(tools: tools)
                }
                #endif
            }
            .frame(maxWidth: 680, alignment: .leading)
        }
        .onAppear { launchAtLogin.refresh() }
    }

    private var launchAtLoginRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            toggleRow(
                localized("Launch at Login"),
                isOn: Binding(get: { launchAtLogin.isOn }, set: { launchAtLogin.setEnabled($0) }),
                detail: launchAtLogin.note ?? localized("Open Spinnet when you log in, so the Menu is ready.")
            )
            if launchAtLogin.needsApproval {
                Button(localized("Open Login Items Settings…"), action: launchAtLogin.openLoginItemsSettings)
                    .controlSize(.small)
                    .accessibilityLabel(localized("Open Login Items Settings"))
                    .accessibilityHint(localized("Allow Spinnet in System Settings → General → Login Items."))
            }
            if let failure = launchAtLogin.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(failure)
            }
        }
        .padding(.bottom, launchAtLogin.needsApproval || launchAtLogin.failure != nil ? 12 : 0)
    }

    private var welcomeGuideRow: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(localized("Welcome Guide")).font(.body.weight(.medium))
                Text(localized("Walk through System Permissions and how to open the Menu again."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(localized("Open Welcome Guide…"), action: model.openWelcomeGuide)
                .accessibilityLabel(localized("Open Welcome Guide"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>, detail: String) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel(title)
                .accessibilityHint(detail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }
}
