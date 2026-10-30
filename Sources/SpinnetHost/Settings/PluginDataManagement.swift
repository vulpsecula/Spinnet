import Combine
import SpinnetCore
import SwiftUI

extension PluginInstallationSource {
    var localizedTitle: String {
        switch self {
        case .unknown: return localized("Source unknown")
        case .localFile: return localized("Local package")
        case .github(let source): return localized("GitHub: \(source.github)")
        }
    }
}

/// A lightweight row; detailed Capability controls are made only on demand.
struct PluginDataEntry: Identifiable, Equatable {
    enum Status: Equatable { case installed, refused, removed }
    let id: PluginID
    let name: String
    let status: Status
    let manifest: PluginManifest?
}

final class PluginDataManagementModel: ObservableObject {
    static let pageSize = 20
    @Published var search = "" { didSet { visibleCount = Self.pageSize } }
    @Published private(set) var entries: [PluginDataEntry] = []
    @Published private(set) var visibleCount = pageSize
    @Published private(set) var expanded: Set<PluginID> = []
    @Published private(set) var pendingClear: PluginDataEntry?
    @Published private(set) var isLoading = false
    @Published var failure: String?

    var retainedPluginData: () throws -> [RetainedPluginData] = { [] }
    var clearPluginData: ((PluginID) throws -> Void)?
    var afterClear: () -> Void = {}
    var runInBackground: (@escaping () -> Void) -> Void = { DispatchQueue.global(qos: .userInitiated).async(execute: $0) }
    var deliver: (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }
    private let manifests: () -> [PluginManifest]
    private let refused: () -> [RefusedPlugin]
    private var generation = 0

    init(manifests: @escaping () -> [PluginManifest], refused: @escaping () -> [RefusedPlugin]) {
        self.manifests = manifests
        self.refused = refused
    }

    func refresh() {
        let installed = manifests().map { PluginDataEntry(id: $0.id, name: $0.name, status: .installed, manifest: $0) }
        let rejected = refused().map { PluginDataEntry(id: $0.id, name: $0.libraryName, status: .refused, manifest: $0.manifest) }
        let active = installed + rejected
        let activeIDs = Set(active.map(\.id))
        let fetch = retainedPluginData
        let deliver = self.deliver
        generation += 1
        let currentGeneration = generation
        isLoading = true
        setEntries(active)
        runInBackground { [weak self] in
            let result = Result { try fetch() }
            deliver { [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                self.isLoading = false
                switch result {
                case .success(let data):
                    let retained = data.filter { !activeIDs.contains($0.id) }
                        .map { PluginDataEntry(id: $0.id, name: $0.name, status: .removed, manifest: nil) }
                    self.setEntries(active + retained)
                case .failure(let error):
                    self.failure = localizedFailure(error)
                }
            }
        }
    }

    private func setEntries(_ values: [PluginDataEntry]) {
        entries = values.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id.rawValue < $1.id.rawValue : comparison == .orderedAscending
        }
        expanded.formIntersection(Set(entries.map(\.id)))
    }

    var matching: [PluginDataEntry] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return entries }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(term) || $0.id.rawValue.localizedCaseInsensitiveContains(term) }
    }
    var visible: [PluginDataEntry] { Array(matching.prefix(visibleCount)) }
    var canShowMore: Bool { matching.count > visibleCount }
    func showMore() { visibleCount += Self.pageSize }
    func toggleDetails(_ id: PluginID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
    func requestClear(_ entry: PluginDataEntry) { pendingClear = entry }
    func cancelClear() { pendingClear = nil }
    func confirmClear() {
        guard let entry = pendingClear, let clearPluginData else { return }
        pendingClear = nil
        do {
            try clearPluginData(entry.id)
            afterClear()
            refresh()
        } catch {
            afterClear()
            refresh()
            failure = localizedFailure(error)
        }
    }
}

struct PluginDataManagementView: View {
    @ObservedObject var model: PluginDataManagementModel
    @ObservedObject var privacy: PrivacyPermissionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(localized("Plugin Access & Data")).font(.headline)
            Text(localized("Manage each Plugin's access and stored data. Removed Plugins appear here when their data was kept."))
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField(localized("Search Plugins"), text: $model.search).textFieldStyle(.roundedBorder)
            if model.matching.isEmpty && model.isLoading {
                Text(localized("Loading Plugins…")).foregroundStyle(.secondary)
            } else if model.matching.isEmpty {
                Text(localized("No matching Plugins.")).foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.visible) { entry in
                        row(entry)
                    }
                }
                if model.canShowMore {
                    Button(localized("Show More Plugins"), action: model.showMore)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localized("Plugin Access & Data"))
        .onAppear(perform: model.refresh)
        .alert(localized("Clear Plugin Data?"), isPresented: Binding(
            get: { model.pendingClear != nil }, set: { if !$0 { model.cancelClear() } }
        )) {
            Button(localized("Cancel"), role: .cancel, action: model.cancelClear)
            Button(localized("Clear Plugin Data"), role: .destructive, action: model.confirmClear)
        } message: {
            Text(localized("Clear settings, Plugin Storage, credentials, access decisions and view preferences for \(model.pendingClear?.name ?? "")? Its Menu Items and installed package remain."))
        }
        .alert(localized("Could Not Manage Plugin Data"), isPresented: Binding(
            get: { model.failure != nil }, set: { if !$0 { model.failure = nil } }
        )) {
            Button(localized("OK"), role: .cancel) { model.failure = nil }
        } message: {
            Text(model.failure ?? "")
        }
    }

    private func row(_ entry: PluginDataEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(.headline)
                    Text(status(entry)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if entry.status == .installed, entry.manifest?.capabilities.isEmpty == false {
                    Button(model.expanded.contains(entry.id) ? localized("Hide Access") : localized("Manage Access")) {
                        model.toggleDetails(entry.id)
                    }
                }
                Button(localized("Clear Plugin Data")) { model.requestClear(entry) }
                    .accessibilityLabel(localized("Clear Plugin Data: \(entry.name)"))
            }
            if model.expanded.contains(entry.id), let manifest = entry.manifest, entry.status == .installed {
                PluginAccessView(manifest: manifest, grants: privacy.capabilityGrants(for: manifest),
                                 setDecision: privacy.setCapabilityDecision)
            }
        }
        .padding(14)
        .settingsCard()
    }

    private func status(_ entry: PluginDataEntry) -> String {
        switch entry.status {
        case .installed: return localized("Installed")
        case .refused: return localized("Refused Plugin")
        case .removed: return localized("Removed · Data Kept")
        }
    }
}
