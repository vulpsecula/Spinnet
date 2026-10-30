import SpinnetCore
import SwiftUI

struct PluginRepositorySheet: View {
    @ObservedObject var model: PluginRepositoryModel
    @State private var repositoryInput = ""
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(localized("Browse Plugins"))
                .font(.title2.weight(.semibold))
            Text(localized("Browse published Plugins from a public GitHub repository. Installing checks compatibility and any requested access."))
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Picker(localized("Repository"), selection: Binding(
                    get: { model.selectedSource }, set: { model.select($0) }
                )) {
                    ForEach(model.repositories, id: \.github) { source in
                        Text(source.github).tag(source)
                    }
                }
                .disabled(model.isInstalling)
                Button(localized("Refresh"), action: model.refresh)
                    .disabled(model.isInstalling)
                Button(localized("Remove Repository"), action: model.removeSelected)
                    .disabled(!model.canRemoveSelected)
            }

            HStack {
                TextField(localized("GitHub repository (owner/name or URL)"), text: $repositoryInput)
                    .disabled(model.isInstalling)
                Button(localized("Add Repository")) {
                    if model.addRepository(repositoryInput) { repositoryInput = "" }
                }
                .disabled(model.isInstalling || repositoryInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let error = model.repositoryError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }

            TextField(localized("Search Plugins"), text: $search)
                .textFieldStyle(.roundedBorder)
            contents
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack {
                Spacer()
                Button(localized("Done"), action: model.close)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 680, height: 620)
        .sheet(item: Binding(
            get: { model.pendingReview },
            set: { if $0 == nil { model.cancelReview() } }
        )) { installation in
            PluginInstallSheet(installation: installation, onCancel: model.cancelReview, onInstall: model.confirmReview)
        }
    }

    @ViewBuilder
    private var contents: some View {
        switch model.listing {
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(localized("Loading Plugins…"))
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message).foregroundStyle(.orange)
                Button(localized("Retry"), action: model.refresh)
            }
        case .loaded(let listing):
            let plugins = listing.plugins.filter { plugin in
                search.isEmpty || plugin.releaseTitle.localizedCaseInsensitiveContains(search)
                    || plugin.id.rawValue.localizedCaseInsensitiveContains(search)
            }
            VStack(alignment: .leading, spacing: 8) {
                if listing.isTruncated {
                    Text(localized("Showing the first 1,000 releases; more may exist."))
                        .font(.caption).foregroundStyle(.orange)
                }
                if plugins.isEmpty {
                    Text(search.isEmpty ? localized("No published Plugins found in this repository.")
                         : localized("No matching Plugins."))
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(plugins) { plugin in
                                pluginRow(plugin)
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }

    private func pluginRow(_ plugin: PublishedPlugin) -> some View {
        let state = model.state(for: plugin)
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.releaseTitle).font(.headline).lineLimit(2)
                Text(plugin.id.rawValue).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                if case .failed(let message) = state {
                    Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            switch state {
            case .installed:
                Label(localized("Installed"), systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            case .downloading:
                ProgressView().controlSize(.small)
                    .accessibilityLabel(localized("Installing \(plugin.releaseTitle)"))
            case .awaitingReview:
                Text(localized("Waiting for review")).font(.caption).foregroundStyle(.secondary)
            case .available, .failed:
                Button(state == .available ? localized("Install") : localized("Retry")) { model.install(plugin) }
                    .disabled(model.isInstalling)
                    .accessibilityLabel(localized("Install \(plugin.releaseTitle)"))
            }
        }
        .padding(.vertical, 10)
    }
}
