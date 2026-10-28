import SwiftUI
import SpinnetCore

/// A Library entry's Check for Update and Update controls, shown only for a
/// Plugin that declares an Update Source.
struct PluginUpdateControls: View {
    @ObservedObject var updates: PluginUpdatesModel
    let pluginID: PluginID
    let pluginName: String

    var body: some View {
        if updates.offersUpdates(for: pluginID) {
            HStack(spacing: 8) {
                switch updates.status(for: pluginID) {
                case .checking:
                    ProgressView().controlSize(.small)
                    Text("Checking for update…")
                case .available:
                    Button("Update to \(updates.availableVersion(for: pluginID) ?? "")") { updates.update(pluginID) }
                        .controlSize(.small)
                        .accessibilityLabel("Update \(pluginName) to \(updates.availableVersion(for: pluginID) ?? "")")
                default:
                    Button("Check for Update") { updates.checkForUpdate(pluginID) }
                        .controlSize(.small)
                        .accessibilityLabel("Check for Update: \(pluginName)")
                }
                if updates.status(for: pluginID) != .checking, let message = updates.message(for: pluginID) {
                    Text(message)
                        .foregroundStyle(updates.status(for: pluginID) == .failed || updates.status(for: pluginID) == .refused
                                         ? Color.orange : Color.secondary)
                        .lineLimit(2)
                        .help(message)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
