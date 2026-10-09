import SpinnetCore
import SwiftUI

/// A small Host-owned list, separate from Plugin Collections and their
/// Immediate State. Stable resource IDs preserve each native Stop control.
struct PluginPageActivityListView: View {
    @ObservedObject var model: HostActivityListModel
    let declaration: PluginPageActivityList

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.rows.isEmpty {
                Text(declaration.emptyText).foregroundStyle(.secondary)
            }
            ForEach(model.rows, id: \.id) { activity in
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(activity.name).font(.headline)
                        Text(activity.status).font(.caption).monospacedDigit()
                    }
                    Spacer(minLength: 8)
                    Button("Stop") { model.stop(activity.id) }
                        .accessibilityLabel("Stop \(activity.name), \(activity.status)")
                        .help("Stop this Host-owned activity")
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityElement(children: .contain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Active activities")
    }
}
