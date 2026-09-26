import SwiftUI
import SpinnetCore

/// How much one Plugin keeps in Plugin Storage, and Clear Stored Data. It is
/// the Library's view of the store (ADR 0015): the Plugin keeps its data
/// without a Capability, so the user sees it here instead.
final class PluginStorageModel: ObservableObject {
    let pluginID: PluginID
    private let storage: PluginStorage
    @Published private(set) var usage: Int
    /// Why the last Clear Stored Data did not finish, if it did not.
    @Published private(set) var failure: String?

    init(pluginID: PluginID, storage: PluginStorage) {
        self.pluginID = pluginID
        self.storage = storage
        usage = storage.usage(of: pluginID)
    }

    var usageDescription: String {
        usage == 0 ? "Nothing stored" : ByteCountFormatter.string(fromByteCount: Int64(usage), countStyle: .file)
    }

    var canClear: Bool { usage > 0 }

    /// Reads the size again; the Plugin may have written since the sheet opened.
    func refresh() {
        usage = storage.usage(of: pluginID)
    }

    func clear() {
        do {
            try storage.clear(pluginID)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        refresh()
    }
}

/// The Stored Data section of a Plugin's Plugin Settings sheet.
struct PluginStorageSection: View {
    @ObservedObject var model: PluginStorageModel
    let pluginName: String
    @State private var confirmingClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Stored Data").font(.headline)
            HStack {
                Text(model.usageDescription)
                    .accessibilityLabel("Stored Data: \(model.usageDescription)")
                Spacer()
                Button("Clear Stored Data…") { confirmingClear = true }
                    .disabled(!model.canClear)
                    .accessibilityLabel("Clear Stored Data: \(pluginName)")
            }
            if let failure = model.failure {
                Label(failure, systemImage: "exclamationmark.triangle").font(.caption)
            }
            Text("What \(pluginName) keeps for itself between runs. Removing the Plugin deletes it; an update keeps it.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
        .onAppear(perform: model.refresh)
        .alert("Clear Stored Data for \(pluginName)?", isPresented: $confirmingClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Stored Data", role: .destructive, action: model.clear)
        } message: {
            Text("\(pluginName) forgets everything it kept for itself. Its settings, access, and Menu Items stay as they are.")
        }
    }
}
