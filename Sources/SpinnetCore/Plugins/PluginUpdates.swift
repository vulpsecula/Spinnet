import Foundation

/// The bounds of one Plugin Update check. They are published in the Plugin
/// API's Update Source reference.
public enum PluginUpdateBudgets {
    /// Releases looked up by tag in one check, newest version first.
    public static let maximumReleaseLookups = 10
    /// Packages downloaded in one check, newest version first.
    public static let maximumDownloads = 5
    /// Largest tag list or release GitHub's API answer the Host reads.
    public static let maximumAnswerBytes = 4 * 1024 * 1024
    /// Largest zipped package the Host downloads.
    public static let maximumPackageBytes = 16 * 1024 * 1024
    /// Largest total a package archive may unpack to.
    public static let maximumUnpackedBytes = PluginPackageArchive.maximumUnpackedBytes
    /// Most entries a package archive may hold.
    public static let maximumArchiveEntries = PluginPackageArchive.maximumEntries
    /// Redirects followed from a release asset to GitHub's download storage.
    public static let maximumRedirects = 3
    public static let answerTimeout: TimeInterval = 15
    public static let downloadTimeout: TimeInterval = 60
    /// GitHub's download storage, where a release asset download may be
    /// redirected. The asset itself is always asked of github.com.
    public static let downloadHosts: Set<String> = [
        "objects.githubusercontent.com", "release-assets.githubusercontent.com"
    ]
}

/// Why one published version was not accepted as a Plugin Update.
public struct PluginUpdateRefusal: Equatable, Sendable {
    /// The release tag it was published under.
    public let tag: String
    /// The version the tag names, as written after `<id>/v`.
    public let version: String
    /// Why, shown by the Host in the interface language.
    public let reasonText: HostText
    /// Why, in English.
    public var reason: String { reasonText.english }

    public init(tag: String, version: String, reason: HostText) {
        self.tag = tag
        self.version = version
        reasonText = reason
    }
}

/// A newer version that passed every acceptance rule, unpacked and reviewed,
/// waiting for the user to apply it.
public struct PluginUpdateOffer: Equatable, Sendable {
    public let tag: String
    public let manifest: PluginManifest
    /// What installing it would have done when it was checked, including the
    /// Capabilities it newly asks for. Review it again before applying.
    public let review: PluginInstallationReview
    /// The unpacked package the update installs.
    public let packageURL: URL
}

/// The outcome of checking one installed Plugin's Update Source.
public struct PluginUpdateCheck: Equatable, Sendable {
    public let pluginID: PluginID
    public let installedVersion: String
    /// The highest accepted newer version, if any.
    public let update: PluginUpdateOffer?
    /// Newer versions that were refused or not tried, with why, highest
    /// first. With an update, these are all versions above it.
    public let refusals: [PluginUpdateRefusal]
}

/// The newest acceptable published version of a Plugin that is not
/// installed, found as a check finds a Plugin Update.
public struct PluginReleaseLookup: Equatable, Sendable {
    /// The highest accepted version, if any. It installs through the same
    /// installation review as a package the user chose.
    public let offer: PluginUpdateOffer?
    /// Higher versions that were refused or not tried, with why, highest first.
    public let refusals: [PluginUpdateRefusal]

    public init(offer: PluginUpdateOffer?, refusals: [PluginUpdateRefusal]) {
        self.offer = offer
        self.refusals = refusals
    }
}

/// The outcome of checking several installed Plugins at once.
public struct PluginUpdateRun {
    /// Each Plugin's check, or why it could not be made, in the order asked.
    public let results: [(pluginID: PluginID, result: Result<PluginUpdateCheck, Error>)]
    /// Why the run stopped before checking every Plugin, if it did.
    public let stoppedBy: PluginUpdateError?
    /// Whether whoever asked stopped the run; the Plugins it had not checked
    /// yet have no result.
    public let cancelled: Bool
}

/// Why a check or an update could not be completed at all. The installed
/// Plugin is untouched and keeps working.
public enum PluginUpdateError: Error, Equatable, LocalizedError {
    case notInstalled(PluginID)
    case noUpdateSource(String)
    case offline
    case timedOut
    case rateLimited(resetsAt: Date?)
    case repositoryNotFound(PluginUpdateSource)
    case unexpectedStatus(Int)
    case unreadableAnswer(HostText)
    /// The tag list is larger than the answer bound.
    case tagListTooLarge
    case changedSinceCheck(HostText)

    /// Whether asking GitHub about another Plugin now would fail the same way.
    public var stopsRun: Bool {
        switch self {
        case .offline, .timedOut, .rateLimited: return true
        default: return false
        }
    }

    /// What the Host shows, in the interface language. A reset time is
    /// written as whoever shows it writes times.
    public func text(resetTime: (Date) -> String) -> HostText {
        switch self {
        case .notInstalled(let id):
            return HostText("%@ is not installed.", .verbatim(id.rawValue))
        case .noUpdateSource(let name):
            return HostText("%@ declares no Update Source.", .verbatim(name))
        case .offline:
            return HostText("Spinnet could not reach GitHub. Check your connection and try again.")
        case .timedOut:
            return HostText("GitHub did not answer in time. Try again later.")
        case .rateLimited(let reset):
            return Self.rateLimitText(resetsAt: reset, resetTime: resetTime)
        case .repositoryNotFound(let source):
            return HostText("GitHub has no public repository %@.", .verbatim(source.github))
        case .unexpectedStatus(let status):
            return HostText("GitHub answered with status %@.", .verbatim(String(status)))
        case .unreadableAnswer(let detail):
            return HostText("GitHub's release tags could not be read: %@", detail)
        case .tagListTooLarge:
            return HostText("GitHub's release tags could not be read: %@", PluginUpdater.tooLarge)
        case .changedSinceCheck(let detail):
            return HostText("The update no longer applies: %@ Check again.", detail)
        }
    }

    public var errorDescription: String? { text(resetTime: Self.systemResetTime).english }

    static func rateLimitText(resetsAt reset: Date?, resetTime: (Date) -> String) -> HostText {
        guard let reset else { return HostText("GitHub's limit on update checks is reached. Try again later.") }
        return HostText("GitHub's limit on update checks is reached. Try again after %@.", .verbatim(resetTime(reset)))
    }

    /// A reset time as the system's region writes it, for SpinnetCore's English.
    static func systemResetTime(_ reset: Date) -> String {
        DateFormatter.localizedString(from: reset, dateStyle: .none, timeStyle: .short)
    }
}

/// Checks a Plugin's Update Source and applies a Plugin Update through the
/// same install-and-replace path as a Library install, so Plugin Storage,
/// Plugin Settings, Menu Items and Capability decisions are kept and newly
/// requested Capabilities are left for the user. Nothing installs unless the
/// caller applies an offer.
///
/// A check lists the Plugin's release tags by prefix, so other Plugins
/// sharing the repository never hide its versions, then looks up releases
/// newest version first. A published package is accepted only when it came
/// over HTTPS from a release asset of the declared repository on github.com,
/// has the same Plugin identity, declares the same Update Source, has a
/// strictly greater SemVer version than the installed one and satisfies Host
/// Compatibility. The highest accepted version wins.
public final class PluginUpdater {
    private let store: PluginInstallationStore
    private let registry: PluginRegistry
    private let transport: HTTPSTransport
    private let downloads: URL

    /// `downloads` holds unpacked offers until their Plugin is updated, so a
    /// later check never removes one the user is reviewing. Whatever an
    /// earlier updater left there is removed.
    public init(store: PluginInstallationStore, registry: PluginRegistry, transport: HTTPSTransport, downloads: URL) {
        self.store = store
        self.registry = registry
        self.transport = transport
        self.downloads = downloads
        try? FileManager.default.removeItem(at: downloads)
    }

    private func installedManifest(_ pluginID: PluginID) throws -> PluginManifest {
        guard let manifest = registry.package(for: pluginID)?.manifest ?? registry.refusedPlugin(pluginID)?.manifest else {
            throw PluginUpdateError.notInstalled(pluginID)
        }
        return manifest
    }

    private func workspace(for pluginID: PluginID) -> URL {
        downloads.appendingPathComponent(pluginID.rawValue, isDirectory: true)
    }

    /// Asks the Update Source for newer versions. Each newer version is
    /// looked up and fetched, highest first and within the published
    /// bounds, until one is accepted.
    public func check(_ pluginID: PluginID) throws -> PluginUpdateCheck {
        let installed = try installedManifest(pluginID)
        guard let source = installed.updateSource else { throw PluginUpdateError.noUpdateSource(installed.name) }
        let tags = try listTags(of: source, prefix: Self.tagPrefix(of: pluginID))
        return try check(installed, source: source, tags: tags)
    }

    /// Looks up the newest acceptable version of a Plugin that is not
    /// installed at `source`, under the same acceptance rules and bounds as a
    /// check, where any version is newer than none. Nothing is installed: the
    /// offer goes through the normal installation review.
    public func newestRelease(of pluginID: PluginID, named name: String,
                              from source: PluginUpdateSource,
                              cancellation: HostFetchedSections.Cancellation? = nil) throws -> PluginReleaseLookup {
        let tags = try listTags(of: source, prefix: Self.tagPrefix(of: pluginID), cancellation: cancellation)
        return try lookUp(Target(id: pluginID, name: name, version: nil), source: source, tags: tags,
                          cancellation: cancellation)
    }

    /// Checks each Plugin as `check` does, within the same per-Plugin bounds,
    /// listing the tags of Plugins that share an Update Source once, by
    /// their common prefix. Being offline, timing out or reaching GitHub's
    /// limit stops the run: every Plugin not yet checked reports that error
    /// and nothing more is asked. `isCancelled` is asked before each
    /// repository and each Plugin; once it answers true nothing more is
    /// asked and the Plugins not yet checked have no result.
    public func checkAll(_ pluginIDs: [PluginID], isCancelled: () -> Bool = { false }) -> PluginUpdateRun {
        var seen: Set<PluginID> = []
        let pluginIDs = pluginIDs.filter { seen.insert($0).inserted }
        var results: [PluginID: Result<PluginUpdateCheck, Error>] = [:]
        var groups: [(source: PluginUpdateSource, plugins: [PluginManifest])] = []
        for pluginID in pluginIDs {
            do {
                let installed = try installedManifest(pluginID)
                guard let source = installed.updateSource else { throw PluginUpdateError.noUpdateSource(installed.name) }
                if let index = groups.firstIndex(where: { $0.source.isSame(as: source) }) {
                    groups[index].plugins.append(installed)
                } else {
                    groups.append((source, [installed]))
                }
            } catch {
                results[pluginID] = .failure(error)
            }
        }

        var stoppedBy: PluginUpdateError?
        var cancelled = false
        func record(_ pluginID: PluginID, _ check: () throws -> PluginUpdateCheck) {
            if let stoppedBy { results[pluginID] = .failure(stoppedBy); return }
            guard !cancelled, !isCancelled() else { cancelled = true; return }
            let result = Result(catching: check)
            if case .failure(let error as PluginUpdateError) = result, error.stopsRun { stoppedBy = error }
            results[pluginID] = result
        }
        for (source, plugins) in groups {
            if stoppedBy == nil, cancelled || isCancelled() {
                cancelled = true
                break
            }
            guard plugins.count > 1 else {
                record(plugins[0].id) { try check(plugins[0].id) }
                continue
            }
            let prefix = Self.commonPrefix(plugins.map { Self.tagPrefix(of: $0.id) })
            let shared: Result<[String], Error> = stoppedBy.map { .failure($0) }
                ?? Result { try listTags(of: source, prefix: prefix) }
            for installed in plugins {
                switch shared {
                case .success(let tags):
                    let own = Self.tagPrefix(of: installed.id)
                    record(installed.id) { try check(installed, source: source, tags: tags.filter { $0.hasPrefix(own) }) }
                case .failure(PluginUpdateError.tagListTooLarge):
                    // Too many tags share the prefix: ask for each Plugin's own.
                    record(installed.id) { try check(installed.id) }
                case .failure(let error):
                    record(installed.id) { throw error }
                }
            }
        }
        return PluginUpdateRun(results: pluginIDs.compactMap { id in results[id].map { (id, $0) } },
                               stoppedBy: stoppedBy, cancelled: cancelled)
    }

    private static func tagPrefix(of pluginID: PluginID) -> String {
        PluginUpdateSource.releaseTag(for: pluginID, version: "")
    }

    private static func commonPrefix(_ strings: [String]) -> String {
        guard var prefix = strings.first.map(Array.init) else { return "" }
        for string in strings.dropFirst() {
            prefix = Array(zip(prefix, string).prefix { $0 == $1 }.map(\.0))
        }
        return String(prefix)
    }

    /// The Plugin a check or lookup is for: an installed one, or one not
    /// installed, which has no version.
    private struct Target {
        let id: PluginID
        let name: String
        let version: PluginVersion?
    }

    private func check(_ installed: PluginManifest, source: PluginUpdateSource, tags: [String]) throws -> PluginUpdateCheck {
        let target = Target(id: installed.id, name: installed.name, version: try PluginVersion(installed.version))
        let found = try lookUp(target, source: source, tags: tags)
        return PluginUpdateCheck(pluginID: installed.id, installedVersion: installed.version,
                                 update: found.offer, refusals: found.refusals)
    }

    private func lookUp(_ target: Target, source: PluginUpdateSource, tags: [String],
                        cancellation: HostFetchedSections.Cancellation? = nil) throws -> PluginReleaseLookup {
        if cancellation?.isCancelled == true { throw HTTPSTransportError.cancelled }
        let pluginID = target.id
        let prefix = Self.tagPrefix(of: pluginID)

        var refusals: [PluginUpdateRefusal] = []
        var newer: [(version: PluginVersion, tag: String)] = []
        for tag in tags {
            let written = String(tag.dropFirst(prefix.count))
            guard let version = try? PluginVersion(written) else {
                refusals.append(.init(tag: tag, version: written, reason: HostText("The release tag does not name a SemVer version.")))
                continue
            }
            if target.version.map({ version > $0 }) ?? true { newer.append((version, tag)) }
        }
        newer.sort { $0.version > $1.version }

        let generation = lock.withLock { generations[pluginID, default: 0] }
        let workspace = workspace(for: pluginID)
        var budget = Budget()
        for (version, tag) in newer {
            if cancellation?.isCancelled == true { throw HTTPSTransportError.cancelled }
            func refuse(_ reason: HostText) {
                refusals.append(.init(tag: tag, version: version.description, reason: reason))
            }
            guard budget.lookups < PluginUpdateBudgets.maximumReleaseLookups else {
                refuse(HostText("Not looked up: a check looks up at most %@ releases.",
                                .verbatim(String(PluginUpdateBudgets.maximumReleaseLookups))))
                continue
            }
            budget.lookups += 1
            let directory = workspace.appendingPathComponent(UUID().uuidString)
            do {
                // A draft, a tag without a release and a prerelease are not offered.
                guard let release = try lookUpRelease(tag, of: source, cancellation: cancellation),
                      release.draft != true, release.prerelease != true else {
                    continue
                }
                let (offer, accepted) = try accept(release, version: version, for: target, source: source,
                                                   into: directory, budget: &budget, cancellation: cancellation)
                if cancellation?.isCancelled == true { throw HTTPSTransportError.cancelled }
                let package = try keep(accepted, tag: release.tag, of: target, generation: generation)
                return PluginReleaseLookup(offer: PluginUpdateOffer(tag: offer.tag, manifest: offer.manifest, review: offer.review,
                                                                    packageURL: package ?? offer.packageURL),
                                           refusals: refusals)
            } catch HTTPSTransportError.cancelled {
                try? FileManager.default.removeItem(at: directory)
                throw HTTPSTransportError.cancelled
            } catch let error as PluginUpdateError {
                try? FileManager.default.removeItem(at: directory)
                throw error
            } catch let refusal as Refusal {
                try? FileManager.default.removeItem(at: directory)
                refuse(refusal.text)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                refuse(.verbatim(error.localizedDescription))
            }
        }
        if cancellation?.isCancelled == true { throw HTTPSTransportError.cancelled }
        _ = try keep(nil, tag: nil, of: target, generation: generation)
        return PluginReleaseLookup(offer: nil, refusals: refusals)
    }

    /// Installs an offer from `check` in place of the installed version,
    /// keeping what an update keeps, and removes its download. Returns the
    /// registered manifest.
    @discardableResult
    public func apply(_ offer: PluginUpdateOffer) throws -> PluginManifest {
        let installed = try installedManifest(offer.manifest.id)
        guard let source = installed.updateSource, offer.manifest.updateSource.map(source.isSame) == true,
              try PluginVersion(offer.manifest.version) > PluginVersion(installed.version) else {
            throw PluginUpdateError.changedSinceCheck(
                HostText("%@ %@ is installed now.", .verbatim(installed.name), .verbatim(installed.version)))
        }
        guard (try? PluginManifestLoader.load(packageAt: offer.packageURL).manifest) == offer.manifest else {
            throw PluginUpdateError.changedSinceCheck(HostText("The downloaded package changed."))
        }
        let manifest = try store.install(from: offer.packageURL, source: .github(source))
        // Every offer kept for the Plugin was made for the version it replaced.
        discardOffers(for: offer.manifest.id, also: offer.packageURL.deletingLastPathComponent())
        return manifest
    }

    /// Forgets and deletes every offer kept for the Plugin, as when it is
    /// removed. A check of it already under way keeps nothing either.
    public func discardOffers(for pluginID: PluginID) {
        discardOffers(for: pluginID, also: nil)
    }

    private func discardOffers(for pluginID: PluginID, also extra: URL?) {
        let discarded = lock.withLock { () -> [String: KeptOffer] in
            generations[pluginID, default: 0] += 1
            return kept.removeValue(forKey: pluginID) ?? [:]
        }
        for directory in Set(discarded.values.map(\.directory) + [extra].compactMap { $0 }) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// An accepted package kept unpacked until its Plugin is updated or
    /// removed, so a later check never removes an offer the user is
    /// reviewing. A later check that offers the same release from the same
    /// asset URL reuses it instead of downloading it again; it is still read,
    /// version-checked and reviewed again like a fresh download.
    private struct KeptOffer {
        let asset: URL
        let packageURL: URL
        /// The directory the check unpacked it into.
        let directory: URL
    }

    /// Guards `kept` and `generations`: checks run off the main thread while
    /// updates are applied on it.
    private let lock = NSLock()
    /// By Plugin, then by release tag. A check keeps only the offer it
    /// returns, so at most one per Plugin outlives a check.
    private var kept: [PluginID: [String: KeptOffer]] = [:]
    /// Counts each Plugin's updates and removals, so a check that began
    /// before one keeps nothing for a version no longer installed.
    private var generations: [PluginID: Int] = [:]

    /// Settles what is kept for the Plugin once a check of it returns: only
    /// `accepted`, under `tag`, or nothing. When another check kept the same
    /// release from the same asset meanwhile, that copy is offered and this
    /// one deleted. Returns the package to offer.
    private func keep(_ accepted: KeptOffer?, tag: String?, of target: Target,
                      generation: Int) throws -> URL? {
        var discarded: [URL] = []
        defer { for directory in Set(discarded) { try? FileManager.default.removeItem(at: directory) } }
        return try lock.withLock { () throws -> URL? in
            var offers = kept[target.id] ?? [:]
            guard generations[target.id, default: 0] == generation else {
                // Updated or removed during the check: the offer is for a
                // version no longer installed.
                guard let accepted else { return nil }
                if !offers.values.contains(where: { $0.directory == accepted.directory }) {
                    discarded.append(accepted.directory)
                }
                throw PluginUpdateError.changedSinceCheck(HostText("%@ changed during the check.", .verbatim(target.name)))
            }
            var package: URL?
            if let accepted, let tag {
                if let existing = offers[tag], existing.directory != accepted.directory, existing.asset == accepted.asset,
                   FileManager.default.fileExists(atPath: existing.packageURL.path) {
                    discarded.append(accepted.directory)
                    package = existing.packageURL
                } else {
                    if let existing = offers[tag], existing.directory != accepted.directory {
                        discarded.append(existing.directory)
                    }
                    guard FileManager.default.fileExists(atPath: accepted.packageURL.path) else {
                        throw PluginUpdateError.changedSinceCheck(HostText("The downloaded package changed."))
                    }
                    offers[tag] = accepted
                    package = accepted.packageURL
                }
            }
            for (other, offer) in offers where other != tag {
                discarded.append(offer.directory)
                offers[other] = nil
            }
            kept[target.id] = offers.isEmpty ? nil : offers
            return package
        }
    }

    // MARK: - Acceptance

    static let tooLarge = HostText("GitHub's answer is larger than Spinnet reads.")

    private struct Refusal: Error, LocalizedError {
        let text: HostText
        /// The answer exceeded its bound.
        var tooLarge = false
        init(_ text: HostText, tooLarge: Bool = false) {
            self.text = text
            self.tooLarge = tooLarge
        }
        var errorDescription: String? { text.english }
    }

    /// What one check has spent of its published bounds.
    private struct Budget {
        var lookups = 0
        var downloads = 0
    }

    private func accept(_ release: Release, version: PluginVersion, for target: Target,
                        source: PluginUpdateSource, into directory: URL,
                        budget: inout Budget,
                        cancellation: HostFetchedSections.Cancellation?) throws -> (PluginUpdateOffer, KeptOffer) {
        let name = PluginUpdateSource.assetName(for: target.id)
        guard let asset = release.assets.first(where: { $0.name == name }) else {
            throw Refusal(HostText("The release has no asset named %@.", .verbatim(name)))
        }
        guard let url = URL(string: asset.downloadURL), Self.isReleaseAsset(url, of: source, tag: release.tag, named: name) else {
            throw Refusal(HostText("The package is not a release asset of %@ on github.com over HTTPS.", .verbatim(source.github)))
        }
        let package: URL
        let keptAs: KeptOffer
        // An offer kept from the same asset URL is reused rather than
        // downloaded again; it is read, version-checked and reviewed below
        // like a fresh download.
        let previous = lock.withLock { kept[target.id]?[release.tag] }
        if let previous, previous.asset == url, FileManager.default.fileExists(atPath: previous.packageURL.path) {
            package = previous.packageURL
            keptAs = previous
        } else {
            guard budget.downloads < PluginUpdateBudgets.maximumDownloads else {
                throw Refusal(HostText("Not downloaded: a check downloads at most %@ packages.",
                                      .verbatim(String(PluginUpdateBudgets.maximumDownloads))))
            }
            budget.downloads += 1
            do {
                package = try PluginPackageArchive.unpack(download(url, cancellation: cancellation), into: directory)
            } catch let refusal as PluginPackageArchive.Refusal {
                throw Refusal(.verbatim(refusal.reason + "."))
            }
            keptAs = KeptOffer(asset: url, packageURL: package, directory: directory)
        }
        let manifest: PluginManifest
        do {
            manifest = try PluginManifestLoader.load(packageAt: package).manifest
        } catch {
            throw Refusal(HostText("The package cannot be read: %@", .verbatim(error.localizedDescription)))
        }
        guard manifest.id == target.id else {
            throw Refusal(HostText("The package is a different Plugin, %@.", .verbatim(manifest.id.rawValue)))
        }
        guard let declared = manifest.updateSource, declared.isSame(as: source) else {
            guard let declared = manifest.updateSource else {
                throw Refusal(HostText("The package declares no Update Source, not %@.", .verbatim(source.github)))
            }
            throw Refusal(HostText("The package declares the Update Source %@, not %@.",
                                   .verbatim(declared.github), .verbatim(source.github)))
        }
        guard let packageVersion = try? PluginVersion(manifest.version), packageVersion == version else {
            throw Refusal(HostText("The package is version %@, not the %@ its release tag names.",
                                  .verbatim(manifest.version), .verbatim(version.description)))
        }
        // The same checks as any install, Host Compatibility included.
        let review: PluginInstallationReview
        do {
            review = try store.review(package)
        } catch {
            throw Refusal(.verbatim(error.localizedDescription))
        }
        return (PluginUpdateOffer(tag: release.tag, manifest: manifest, review: review, packageURL: package), keptAs)
    }

    /// `https://github.com/<owner>/<repo>/releases/download/<tag>/<name>`,
    /// for the release's own tag.
    static func isReleaseAsset(_ url: URL, of source: PluginUpdateSource, tag: String, named name: String) -> Bool {
        guard url.scheme == "https", url.host?.lowercased() == "github.com", url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil else { return false }
        let components = url.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
        guard components.count >= 6, !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              components[0].lowercased() == source.owner.lowercased(),
              components[1].lowercased() == source.repository.lowercased(),
              components[2] == "releases", components[3] == "download", components.last == name,
              components[4..<(components.count - 1)].joined(separator: "/") == tag else { return false }
        return true
    }

    // MARK: - GitHub

    private struct Reference: Decodable {
        let ref: String
    }

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let downloadURL: String
            enum CodingKeys: String, CodingKey {
                case name
                case downloadURL = "browser_download_url"
            }
        }
        let tag: String
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]
        enum CodingKeys: String, CodingKey {
            case tag = "tag_name", draft, prerelease, assets
        }
    }

    private func send(_ url: URL, accept: String, timeout: TimeInterval, limit: Int,
                      cancellation: HostFetchedSections.Cancellation? = nil) throws -> HTTPSTransportResponse {
        let request = HTTPSTransportRequest(method: "GET", url: url, headers: [
            "Accept": accept, "X-GitHub-Api-Version": "2022-11-28"
        ], body: nil, timeout: timeout, maximumResponseBytes: limit)
        do {
            if let cancellation { return try transport.send(request, cancellation: cancellation) }
            return try transport.send(request)
        } catch HTTPSTransportError.cancelled {
            throw HTTPSTransportError.cancelled
        } catch HTTPSTransportError.timedOut {
            throw PluginUpdateError.timedOut
        } catch HTTPSTransportError.responseTooLarge {
            throw Refusal(Self.tooLarge, tooLarge: true)
        } catch {
            throw PluginUpdateError.offline
        }
    }

    private func askAPI(_ path: String, cancellation: HostFetchedSections.Cancellation? = nil) throws -> HTTPSTransportResponse {
        let response = try send(URL(string: "https://api.github.com/" + path)!, accept: "application/vnd.github+json",
                                timeout: PluginUpdateBudgets.answerTimeout, limit: PluginUpdateBudgets.maximumAnswerBytes,
                                cancellation: cancellation)
        if response.status == 429 || (response.status == 403 && response.headers["x-ratelimit-remaining"] == "0") {
            let reset = response.headers["x-ratelimit-reset"].flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
            throw PluginUpdateError.rateLimited(resetsAt: reset)
        }
        return response
    }

    /// Every tag starting with `prefix`, however many releases the
    /// repository has.
    private func listTags(of source: PluginUpdateSource, prefix: String,
                          cancellation: HostFetchedSections.Cancellation? = nil) throws -> [String] {
        let response: HTTPSTransportResponse
        do {
            response = try askAPI("repos/\(source.owner)/\(source.repository)/git/matching-refs/tags/\(prefix)",
                                  cancellation: cancellation)
        } catch let refusal as Refusal {
            throw refusal.tooLarge ? PluginUpdateError.tagListTooLarge : PluginUpdateError.unreadableAnswer(refusal.text)
        }
        switch response.status {
        case 200:
            break
        case 404:
            throw PluginUpdateError.repositoryNotFound(source)
        default:
            throw PluginUpdateError.unexpectedStatus(response.status)
        }
        let references: [Reference]
        do {
            references = try JSONDecoder().decode([Reference].self, from: response.body)
        } catch {
            throw PluginUpdateError.unreadableAnswer(HostText("it is not a list of tags."))
        }
        let tagPrefix = "refs/tags/" + prefix
        return references.map(\.ref).filter { $0.hasPrefix(tagPrefix) }.map { String($0.dropFirst("refs/tags/".count)) }
    }

    /// The release published under `tag`, or nil when GitHub shows none.
    private func lookUpRelease(_ tag: String, of source: PluginUpdateSource,
                               cancellation: HostFetchedSections.Cancellation?) throws -> Release? {
        let response = try askAPI("repos/\(source.owner)/\(source.repository)/releases/tags/\(tag)",
                                  cancellation: cancellation)
        switch response.status {
        case 200:
            break
        case 404:
            return nil
        default:
            throw Refusal(HostText("GitHub answered the release lookup with status %@.", .verbatim(String(response.status))))
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: response.body), release.tag == tag else {
            throw Refusal(HostText("GitHub's answer is not the release %@.", .verbatim(tag)))
        }
        return release
    }

    /// Follows GitHub's redirects to its download storage, and nowhere else.
    private func download(_ asset: URL, cancellation: HostFetchedSections.Cancellation?) throws -> Data {
        var url = asset
        for _ in 0...PluginUpdateBudgets.maximumRedirects {
            let response = try send(url, accept: "application/octet-stream", timeout: PluginUpdateBudgets.downloadTimeout,
                                    limit: PluginUpdateBudgets.maximumPackageBytes, cancellation: cancellation)
            switch response.status {
            case 200:
                return response.body
            case 301, 302, 303, 307, 308:
                guard let location = response.headers["location"], let next = URL(string: location, relativeTo: url)?.absoluteURL,
                      next.scheme == "https", let host = next.host?.lowercased(),
                      PluginUpdateBudgets.downloadHosts.contains(host), next.user == nil, next.port == nil else {
                    throw Refusal(HostText("The release asset redirects away from GitHub's download storage."))
                }
                url = next
            case 404:
                throw Refusal(HostText("GitHub has no file for this release asset."))
            default:
                throw Refusal(HostText("GitHub answered the download with status %@.", .verbatim(String(response.status))))
            }
        }
        throw Refusal(HostText("The release asset redirects more than %@ times.",
                          .verbatim(String(PluginUpdateBudgets.maximumRedirects))))
    }
}
