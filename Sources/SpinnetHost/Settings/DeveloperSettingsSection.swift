#if DEBUG
import AppKit
import SwiftUI

/// The Developer section, last on the General page of a DEBUG Host.
struct DeveloperSettingsSection: View {
    /// The section's names, in the order its controls appear.
    static let accessibleNames = [
        "Developer",
        "Relaunch Spinnet",
        "Lifecycle Test Window",
        "Copy Diagnostics",
        "Reveal Data Folder",
        "Copy Log Stream Command"
    ]

    let tools: DeveloperTools
    @State private var diagnostics: DeveloperDiagnostics?
    @State private var notice: String?

    var body: some View {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Developer").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    Text("Shortcuts for developing and testing Spinnet. Only development builds have this section.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section("Host") {
                    actionRow(
                        "Relaunch Spinnet", button: "Relaunch",
                        detail: tools.canRelaunch
                            ? "Quit and reopen this app bundle."
                            : "Only a Host running from an app bundle can reopen itself.",
                        action: tools.relaunch
                    )
                    .disabled(!tools.canRelaunch)
                    Divider()
                    actionRow(
                        "Lifecycle Test Window", button: "Open",
                        detail: "Run the slow and hanging Action fixtures.",
                        action: tools.openLifecycleTestWindow
                    )
                }

                section("Diagnostics") {
                    if let diagnostics {
                        valueRow("App", diagnostics.appPath)
                        Divider()
                        valueRow("Version", "\(diagnostics.version) · \(diagnostics.sourceRevision)")
                        Divider()
                        valueRow("Bundled Plugins", diagnostics.bundledPluginSource)
                        Divider()
                        valueRow("Plugins", pluginSummary(diagnostics))
                        Divider()
                    }
                    actionRow(
                        "Copy Diagnostics", button: "Copy",
                        detail: "The app path, version and every loaded Plugin, for an acceptance report.",
                        action: { run("Diagnostics copied", tools.copyDiagnostics) }
                    )
                    Divider()
                    actionRow(
                        "Reveal Data Folder", button: "Reveal in Finder",
                        detail: diagnostics?.dataDirectory ?? "Spinnet's Application Support folder.",
                        action: tools.revealDataFolder
                    )
                    Divider()
                    actionRow(
                        "Copy Log Stream Command", button: "Copy",
                        detail: "Streams the Host's and its helpers' logs in Terminal.",
                        action: { run("Log stream command copied", tools.copyLogStreamCommand) }
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
        var parts = ["\(diagnostics.plugins.count) loaded"]
        if disabled > 0 { parts.append("\(disabled) disabled") }
        if !diagnostics.refused.isEmpty { parts.append("\(diagnostics.refused.count) refused") }
        return parts.joined(separator: " · ")
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) { content() }
                .padding(.horizontal, 18)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                        }
                }
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
