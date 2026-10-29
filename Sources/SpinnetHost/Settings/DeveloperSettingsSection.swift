#if DEBUG
import AppKit
import SwiftUI

/// The Developer section, last on the General page of a DEBUG Host.
struct DeveloperSettingsSection: View {
    /// The section's names, in the order its controls appear.
    static var accessibleNames: [String] { [
        localized("Developer"),
        localized("Relaunch Spinnet"),
        localized("Lifecycle Test Window"),
        localized("Copy Diagnostics"),
        localized("Reveal Data Folder"),
        localized("Copy Log Stream Command")
    ] }

    let tools: DeveloperTools
    @State private var diagnostics: DeveloperDiagnostics?
    @State private var notice: String?

    var body: some View {
            VStack(alignment: .leading, spacing: 24) {
                pageHeader(title: localized("Developer"),
                           description: localized("Shortcuts for developing and testing Spinnet. Only development builds have this section."),
                           titleFont: .title2.weight(.semibold))

                section(localized("Host")) {
                    actionRow(
                        localized("Relaunch Spinnet"), button: localized("Relaunch"),
                        detail: tools.canRelaunch
                            ? localized("Quit and reopen this app bundle.")
                            : localized("Only a Host running from an app bundle can reopen itself."),
                        action: tools.relaunch
                    )
                    .disabled(!tools.canRelaunch)
                    Divider()
                    actionRow(
                        localized("Lifecycle Test Window"), button: localized("Open"),
                        detail: localized("Run the slow and hanging Action fixtures."),
                        action: tools.openLifecycleTestWindow
                    )
                }

                section(localized("Diagnostics")) {
                    if let diagnostics {
                        valueRow(localized("App"), diagnostics.appPath)
                        Divider()
                        valueRow(localized("Version"), "\(diagnostics.version) · \(diagnostics.sourceRevision)")
                        Divider()
                        valueRow(localized("Plugins"), pluginSummary(diagnostics))
                        Divider()
                    }
                    actionRow(
                        localized("Copy Diagnostics"), button: localized("Copy"),
                        detail: localized("The app path, version and every loaded Plugin, for an acceptance report."),
                        action: { run(localized("Diagnostics copied"), tools.copyDiagnostics) }
                    )
                    Divider()
                    actionRow(
                        localized("Reveal Data Folder"), button: localized("Reveal in Finder"),
                        detail: diagnostics?.dataDirectory ?? localized("Spinnet's Application Support folder."),
                        action: tools.revealDataFolder
                    )
                    Divider()
                    actionRow(
                        localized("Copy Log Stream Command"), button: localized("Copy"),
                        detail: localized("Streams the Host's and its helpers' logs in Terminal."),
                        action: { run(localized("Log stream command copied"), tools.copyLogStreamCommand) }
                    )
                }

                if let notice {
                    Label(notice, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        .onAppear { diagnostics = tools.diagnostics() }
    }

    private func run(_ confirmation: String, _ action: () -> Void) {
        action()
        diagnostics = tools.diagnostics()
        notice = confirmation
    }

    private func pluginSummary(_ diagnostics: DeveloperDiagnostics) -> String {
        let disabled = diagnostics.plugins.filter { !$0.isEnabled }.count
        var parts = [localized("\(diagnostics.plugins.count) loaded")]
        if disabled > 0 { parts.append(localized("\(disabled) disabled")) }
        if !diagnostics.refused.isEmpty { parts.append(localized("\(diagnostics.refused.count) refused")) }
        return parts.joined(separator: " · ")
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) { content() }
                .padding(.horizontal, 18)
                .settingsCard()
        }
    }

    private func actionRow(_ title: String, button: String, detail: String,
                           action: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(button, action: action)
                .accessibilityLabel(title)
                .accessibilityHint(detail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }

    private func valueRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text(title).font(.headline).frame(width: 140, alignment: .leading)
            Text(value)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }
}
#endif
