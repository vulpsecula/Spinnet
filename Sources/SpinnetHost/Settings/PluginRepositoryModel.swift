import Combine
import Foundation
import SpinnetCore

/// The Library's remote repository browser. It lists releases on request and
/// installs only a package the user chose, through the Library's review.
final class PluginRepositoryModel: ObservableObject {
    enum Listing: Equatable {
        case idle
        case loading
        case loaded(PluginRepositoryListing)
        case failed(String)
    }

    enum InstallState: Equatable {
        case available
        case downloading
        case awaitingReview
        case installed
        case failed(String)
    }

    static let repositoriesKey = "plugin-repositories.github"
    static let official = try! PluginUpdateSource(github: OfficialPlugin.repository)

    @Published private(set) var isPresented = false
    @Published private(set) var repositories: [PluginUpdateSource]
    @Published private(set) var selectedSource: PluginUpdateSource
    @Published private(set) var listing: Listing = .idle
    @Published private(set) var repositoryError: String?
    @Published private(set) var pendingReview: PendingPluginInstallation?
    @Published private var activePlugin: PluginID?
    @Published private var failures: [PluginID: String] = [:]

    var listReleases: ((PluginUpdateSource, HostFetchedSections.Cancellation) throws -> PluginRepositoryListing)?
    var lookUpRelease: ((PublishedPlugin, PluginUpdateSource, HostFetchedSections.Cancellation) throws -> PluginReleaseLookup)?

    private let queue = DispatchQueue(label: "Spinnet.PluginRepository") // Not localized: a dispatch queue label
    lazy var runInBackground: (@escaping () -> Void) -> Void = { [queue] in queue.async(execute: $0) }
    var runListingInBackground: (@escaping () -> Void) -> Void = { DispatchQueue.global(qos: .userInitiated).async(execute: $0) }
    var deliver: (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }

    private let defaults: UserDefaults
    private let isInstalled: (PluginID) -> Bool
    private let review: (URL) throws -> PluginInstallationReview
    private let install: (PendingPluginInstallation) throws -> Void
    private var generation = 0
    private var listingCancellation: HostFetchedSections.Cancellation?
    private var lookupCancellation: HostFetchedSections.Cancellation?
    private var observations: [AnyCancellable] = []

    init(defaults: UserDefaults, isInstalled: @escaping (PluginID) -> Bool,
         review: @escaping (URL) throws -> PluginInstallationReview,
         install: @escaping (PendingPluginInstallation) throws -> Void) {
        self.defaults = defaults
        self.isInstalled = isInstalled
        self.review = review
        self.install = install
        var sources = [Self.official]
        for name in defaults.stringArray(forKey: Self.repositoriesKey) ?? [] {
            guard let source = try? PluginUpdateSource(github: name),
                  !sources.contains(where: { $0.isSame(as: source) }) else { continue }
            sources.append(source)
        }
        repositories = sources
        selectedSource = Self.official
    }

    func observeInstalledPlugins<P: Publisher>(_ changes: P) where P.Failure == Never {
        changes.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
    }

    var isInstalling: Bool { activePlugin != nil }

    func open() {
        isPresented = true
        refresh()
    }

    /// Cancel work and ignore any result that arrived as the browser closed.
    func close() {
        generation += 1
        listingCancellation?.cancel()
        listingCancellation = nil
        lookupCancellation?.cancel()
        lookupCancellation = nil
        pendingReview = nil
        activePlugin = nil
        isPresented = false
    }

    func select(_ source: PluginUpdateSource) {
        guard !isInstalling, let existing = repositories.first(where: { $0.isSame(as: source) }) else { return }
        guard !selectedSource.isSame(as: existing) else { return }
        selectedSource = existing
        failures = [:]
        refresh()
    }

    /// Accepts an owner/name or a normal HTTPS GitHub repository URL; requests
    /// are constructed from the validated source, never from the entered URL.
    func addRepository(_ input: String) -> Bool {
        guard !isInstalling else { return false }
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let repository: String
        if value.contains("://") {
            guard let url = URLComponents(string: value), url.scheme?.lowercased() == "https",
                  url.host?.lowercased() == "github.com", url.user == nil, url.password == nil,
                  url.port == nil, url.query == nil, url.fragment == nil else {
                repositoryError = localized("Enter a public GitHub repository as owner/name or a github.com URL.")
                return false
            }
            repository = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else {
            repository = value
        }
        guard let source = try? PluginUpdateSource(github: repository) else {
            repositoryError = localized("Enter a public GitHub repository as owner/name or a github.com URL.")
            return false
        }
        repositoryError = nil
        if let existing = repositories.first(where: { $0.isSame(as: source) }) {
            select(existing)
            return true
        }
        repositories.append(source)
        saveRepositories()
        select(source)
        return true
    }

    var canRemoveSelected: Bool { !selectedSource.isSame(as: Self.official) && !isInstalling }

    func removeSelected() {
        guard canRemoveSelected else { return }
        repositories.removeAll { $0.isSame(as: selectedSource) }
        saveRepositories()
        select(Self.official)
    }

    private func saveRepositories() {
        defaults.set(repositories.filter { !$0.isSame(as: Self.official) }.map(\.github), forKey: Self.repositoriesKey)
    }

    func refresh() {
        guard isPresented, !isInstalling, let listReleases else { return }
        generation += 1
        let request = generation, source = selectedSource
        listingCancellation?.cancel()
        let cancellation = HostFetchedSections.Cancellation()
        listingCancellation = cancellation
        listing = .loading
        runListingInBackground { [weak self] in
            let result = Result { try listReleases(source, cancellation) }
            self?.deliver {
                guard let self, self.isPresented, self.generation == request else { return }
                self.listingCancellation = nil
                switch result {
                case .success(let listing): self.listing = .loaded(listing)
                case .failure(let error): self.listing = .failed(localizedFailure(error))
                }
            }
        }
    }

    func state(for plugin: PublishedPlugin) -> InstallState {
        if activePlugin == plugin.id {
            return pendingReview == nil ? .downloading : .awaitingReview
        }
        if isInstalled(plugin.id) { return .installed }
        if let failure = failures[plugin.id] { return .failed(failure) }
        return .available
    }

    func install(_ plugin: PublishedPlugin) {
        guard isPresented, !isInstalling, !isInstalled(plugin.id), let lookUpRelease,
              case .loaded(let result) = listing, result.plugins.contains(plugin) else { return }
        generation += 1
        let request = generation, source = selectedSource
        let cancellation = HostFetchedSections.Cancellation()
        lookupCancellation = cancellation
        activePlugin = plugin.id
        failures[plugin.id] = nil
        runInBackground { [weak self] in
            guard !cancellation.isCancelled else { return }
            let result = Result { try lookUpRelease(plugin, source, cancellation) }
            self?.deliver { self?.finishLookup(plugin, source: source, result: result, request: request) }
        }
    }

    private func finishLookup(_ plugin: PublishedPlugin, source: PluginUpdateSource,
                              result: Result<PluginReleaseLookup, Error>, request: Int) {
        guard isPresented, generation == request, activePlugin == plugin.id else { return }
        lookupCancellation = nil
        do {
            guard !isInstalled(plugin.id) else { activePlugin = nil; return }
            let lookup = try result.get()
            guard let offer = lookup.offer else {
                let reason = lookup.refusals.first.map { localized("\($0.version) was refused: \($0.localizedReason)") }
                failures[plugin.id] = HostLocalization.joiningSentences(
                    [localized("No compatible release of \(plugin.releaseTitle) could be installed.")] + [reason].compactMap { $0 })
                activePlugin = nil
                return
            }
            let checked = try review(offer.packageURL)
            guard checked.manifest == offer.manifest, checked.manifest.id == plugin.id,
                  checked.manifest.updateSource.map(source.isSame) == true else {
                throw PluginUpdateError.changedSinceCheck(HostText("The downloaded package changed.")) // Not localized: HostText is localized by localizedFailure
            }
            let pending = PendingPluginInstallation(source: offer.packageURL, review: checked,
                                                    installationSource: .github(source))
            if checked.requestedAccess.isEmpty {
                try finishInstall(pending)
            } else {
                pendingReview = pending
            }
        } catch {
            if case .rateLimited(let reset) = error as? PluginUpdateError {
                failures[plugin.id] = localizedFailure(PluginRepositoryError.rateLimited(resetsAt: reset))
            } else {
                failures[plugin.id] = localizedFailure(error)
            }
            activePlugin = nil
        }
    }

    private func finishInstall(_ pending: PendingPluginInstallation) throws {
        let id = pending.review.manifest.id
        guard !isInstalled(id), try review(pending.source) == pending.review else {
            throw PluginUpdateError.changedSinceCheck(HostText("The downloaded package changed.")) // Not localized: HostText is localized by localizedFailure
        }
        try install(pending)
        activePlugin = nil
        failures[id] = nil
    }

    func confirmReview() {
        guard let pending = pendingReview else { return }
        pendingReview = nil
        do {
            try finishInstall(pending)
        } catch {
            failures[pending.review.manifest.id] = localizedFailure(error)
            activePlugin = nil
        }
    }

    func cancelReview() {
        guard let pending = pendingReview else { return }
        pendingReview = nil
        failures[pending.review.manifest.id] = localized("Not installed: its access was not allowed.")
        activePlugin = nil
    }
}
