import AppKit
import SwiftUI
import SpinnetCore

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
                        detail: localized("When off, the Status Item appears for ongoing Tasks and Effects, and for retained ended Tasks. Open Spinnet again to show Settings.")
                    )
                    Divider()
                    endedTaskRetentionRow
                    Divider()
                    InterfaceLanguageRow(language: interfaceLanguage)
                    Divider()
                    welcomeGuideRow
                }
                .padding(.horizontal, 18)
                .settingsCard()

                MenuOpeningDelayRow(trigger: model.trigger, privacy: model.privacy)
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
        .onAppear { launchAtLogin.refreshAsynchronously() }
    }

    private var endedTaskRetentionRow: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(localized("Remove Ended Tasks")).font(.body.weight(.medium))
                Text(localized("Automatically clear ended Tasks after this time. History is also limited to make room for new Host Activities."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Picker(localized("Remove Ended Tasks"), selection: $model.endedTaskRetention) {
                Text(localized("Immediately")).tag(EndedTaskRetention.immediately)
                Text(localized("After 1 hour")).tag(EndedTaskRetention.oneHour)
                Text(localized("After 1 day")).tag(EndedTaskRetention.oneDay)
                Text(localized("After 7 days")).tag(EndedTaskRetention.sevenDays)
                Text(localized("Never")).tag(EndedTaskRetention.never)
            }.labelsHidden()
            .accessibilityLabel(localized("Remove Ended Tasks"))
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
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
