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
    public let reason: String

    public init(tag: String, version: String, reason: String) {
        self.tag = tag
        self.version = version
        self.reason = reason
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

/// The outcome of checking several installed Plugins at once.
public struct PluginUpdateRun {
    /// Each Plugin's check, or why it could not be made, in the order asked.
    public let results: [(pluginID: PluginID, result: Result<PluginUpdateCheck, Error>)]
    /// Why the run stopped before checking every Plugin, if it did.
    public let stoppedBy: PluginUpdateError?
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
    case unreadableAnswer(String)
    case changedSinceCheck(String)

    /// Whether asking GitHub about another Plugin now would fail the same way.
    public var stopsRun: Bool {
        switch self {
        case .offline, .timedOut, .rateLimited: return true
        default: return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let id):
            return "\(id.rawValue) is not installed."
        case .noUpdateSource(let name):
            return "\(name) declares no Update Source."
        case .offline:
            return "Spinnet could not reach GitHub. Check your connection and try again."
        case .timedOut:
            return "GitHub did not answer in time. Try again later."
        case .rateLimited(let reset):
            guard let reset else { return "GitHub's limit on update checks is reached. Try again later." }
            let time = DateFormatter.localizedString(from: reset, dateStyle: .none, timeStyle: .short)
            return "GitHub's limit on update checks is reached. Try again after \(time)."
        case .repositoryNotFound(let source):
            return "GitHub has no public repository \(source.github)."
        case .unexpectedStatus(let status):
            return "GitHub answered with status \(status)."
        case .unreadableAnswer(let detail):
            return "GitHub's release tags could not be read: \(detail)"
        case .changedSinceCheck(let detail):
            return "The update no longer applies: \(detail) Check again."
        }
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

    /// Checks each Plugin as `check` does, within the same per-Plugin bounds,
    /// listing the tags of Plugins that share an Update Source once, by
    /// their common prefix. Being offline, timing out or reaching GitHub's
    /// limit stops the run: every Plugin not yet checked reports that error
    /// and nothing more is asked.
    public func checkAll(_ pluginIDs: [PluginID]) -> PluginUpdateRun {
        var results: [PluginID: Result<PluginUpdateCheck, Error>] = [:]
        var groups: [(source: PluginUpdateSource, plugins: [PluginManifest])] = []
        for pluginID in pluginIDs where results[pluginID] == nil {
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
        func record(_ pluginID: PluginID, _ check: () throws -> PluginUpdateCheck) {
            if let stoppedBy { results[pluginID] = .failure(stoppedBy); return }
            let result = Result(catching: check)
            if case .failure(let error as PluginUpdateError) = result, error.stopsRun { stoppedBy = error }
            results[pluginID] = result
        }
        for (source, plugins) in groups {
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
                case .failure(PluginUpdateError.unreadableAnswer(Self.tooLarge)):
                    // Too many tags share the prefix: ask for each Plugin's own.
                    record(installed.id) { try check(installed.id) }
                case .failure(let error):
                    record(installed.id) { throw error }
                }
            }
        }
        return PluginUpdateRun(results: pluginIDs.compactMap { id in results[id].map { (id, $0) } }, stoppedBy: stoppedBy)
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

    private func check(_ installed: PluginManifest, source: PluginUpdateSource, tags: [String]) throws -> PluginUpdateCheck {
        let pluginID = installed.id
        let current = try PluginVersion(installed.version)
        let prefix = Self.tagPrefix(of: pluginID)

        var refusals: [PluginUpdateRefusal] = []
        var newer: [(version: PluginVersion, tag: String)] = []
        for tag in tags {
            let written = String(tag.dropFirst(prefix.count))
            guard let version = try? PluginVersion(written) else {
                refusals.append(.init(tag: tag, version: written, reason: "The release tag does not name a SemVer version."))
                continue
            }
            if version > current { newer.append((version, tag)) }
        }
        newer.sort { $0.version > $1.version }

        let workspace = workspace(for: pluginID)
        var budget = Budget()
        for (version, tag) in newer {
            func refuse(_ reason: String) {
                refusals.append(.init(tag: tag, version: version.description, reason: reason))
            }
            guard budget.lookups < PluginUpdateBudgets.maximumReleaseLookups else {
                refuse("Not looked up: a check looks up at most \(PluginUpdateBudgets.maximumReleaseLookups) releases.")
                continue
            }
            budget.lookups += 1
            let directory = workspace.appendingPathComponent(UUID().uuidString)
            do {
                // A draft, a tag without a release and a prerelease are not offered.
                guard let release = try lookUpRelease(tag, of: source), release.draft != true, release.prerelease != true else {
                    continue
                }
                let offer = try accept(release, version: version, replacing: installed, source: source,
                                       into: directory, budget: &budget)
                return PluginUpdateCheck(pluginID: pluginID, installedVersion: installed.version,
                                         update: offer, refusals: refusals)
            } catch let error as PluginUpdateError {
                try? FileManager.default.removeItem(at: directory)
                throw error
            } catch {
                try? FileManager.default.removeItem(at: directory)
                refuse(error.localizedDescription)
            }
        }
        return PluginUpdateCheck(pluginID: pluginID, installedVersion: installed.version, update: nil, refusals: refusals)
    }

    /// Installs an offer from `check` in place of the installed version,
    /// keeping what an update keeps, and removes its download. Returns the
    /// registered manifest.
    @discardableResult
    public func apply(_ offer: PluginUpdateOffer) throws -> PluginManifest {
        let installed = try installedManifest(offer.manifest.id)
        guard let source = installed.updateSource, offer.manifest.updateSource.map(source.isSame) == true,
              try PluginVersion(offer.manifest.version) > PluginVersion(installed.version) else {
            throw PluginUpdateError.changedSinceCheck("\(installed.name) \(installed.version) is installed now.")
        }
        guard (try? PluginManifestLoader.load(packageAt: offer.packageURL).manifest) == offer.manifest else {
            throw PluginUpdateError.changedSinceCheck("The downloaded package changed.")
        }
        let manifest = try store.install(from: offer.packageURL)
        // Every offer kept for the Plugin was made for the version it replaced.
        let discarded = lock.withLock { kept.removeValue(forKey: offer.manifest.id) ?? [:] }
        for directory in Set(discarded.values.map(\.directory) + [offer.packageURL.deletingLastPathComponent()]) {
            try? FileManager.default.removeItem(at: directory)
        }
        return manifest
    }

    /// An accepted package kept unpacked until its Plugin is updated, so a
    /// later check never removes an offer the user is reviewing and accepts
    /// the same release again without downloading it.
    private struct KeptOffer {
        let asset: URL
        let packageURL: URL
        /// The directory the check unpacked it into.
        let directory: URL
    }

    private let lock = NSLock()
    /// By Plugin, then by release tag.
    private var kept: [PluginID: [String: KeptOffer]] = [:]

    // MARK: - Acceptance

    private static let tooLarge = "GitHub's answer is larger than Spinnet reads."

    private struct Refusal: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// What one check has spent of its published bounds.
    private struct Budget {
        var lookups = 0
        var downloads = 0
    }

    private func accept(_ release: Release, version: PluginVersion, replacing installed: PluginManifest,
                        source: PluginUpdateSource, into directory: URL, budget: inout Budget) throws -> PluginUpdateOffer {
        let name = PluginUpdateSource.assetName(for: installed.id)
        guard let asset = release.assets.first(where: { $0.name == name }) else {
            throw Refusal(reason: "The release has no asset named \(name).")
        }
        guard let url = URL(string: asset.downloadURL), Self.isReleaseAsset(url, of: source, tag: release.tag, named: name) else {
            throw Refusal(reason: "The package is not a release asset of \(source.github) on github.com over HTTPS.")
        }
        let package: URL
        let previous = lock.withLock { kept[installed.id]?[release.tag] }
        if let previous, previous.asset == url, FileManager.default.fileExists(atPath: previous.packageURL.path) {
            package = previous.packageURL
        } else {
            guard budget.downloads < PluginUpdateBudgets.maximumDownloads else {
                throw Refusal(reason: "Not downloaded: a check downloads at most \(PluginUpdateBudgets.maximumDownloads) packages.")
            }
            budget.downloads += 1
            do {
                package = try PluginPackageArchive.unpack(download(url), into: directory)
            } catch let refusal as PluginPackageArchive.Refusal {
                throw Refusal(reason: refusal.reason + ".")
            }
        }
        let manifest: PluginManifest
        do {
            manifest = try PluginManifestLoader.load(packageAt: package).manifest
        } catch {
            throw Refusal(reason: "The package cannot be read: \(error.localizedDescription)")
        }
        guard manifest.id == installed.id else {
            throw Refusal(reason: "The package is a different Plugin, \(manifest.id.rawValue).")
        }
        guard let declared = manifest.updateSource, declared.isSame(as: source) else {
            let named = manifest.updateSource.map { "declares the Update Source \($0.github)" } ?? "declares no Update Source"
            throw Refusal(reason: "The package \(named), not \(source.github).")
        }
        guard let packageVersion = try? PluginVersion(manifest.version), packageVersion == version else {
            throw Refusal(reason: "The package is version \(manifest.version), not the \(version) its release tag names.")
        }
        // The same checks as any install, Host Compatibility included.
        let review: PluginInstallationReview
        do {
            review = try store.review(package)
        } catch {
            throw Refusal(reason: error.localizedDescription)
        }
        if previous?.packageURL != package {
            lock.withLock {
                kept[installed.id, default: [:]][release.tag] = KeptOffer(asset: url, packageURL: package, directory: directory)
            }
        }
        return PluginUpdateOffer(tag: release.tag, manifest: manifest, review: review, packageURL: package)
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

    private func send(_ url: URL, accept: String, timeout: TimeInterval, limit: Int) throws -> HTTPSTransportResponse {
        let request = HTTPSTransportRequest(method: "GET", url: url, headers: [
            "Accept": accept, "X-GitHub-Api-Version": "2022-11-28"
        ], body: nil, timeout: timeout, maximumResponseBytes: limit)
        do {
            return try transport.send(request)
        } catch HTTPSTransportError.timedOut {
            throw PluginUpdateError.timedOut
        } catch HTTPSTransportError.responseTooLarge {
            throw Refusal(reason: Self.tooLarge)
        } catch {
            throw PluginUpdateError.offline
        }
    }

    private func askAPI(_ path: String) throws -> HTTPSTransportResponse {
        let response = try send(URL(string: "https://api.github.com/" + path)!, accept: "application/vnd.github+json",
                                timeout: PluginUpdateBudgets.answerTimeout, limit: PluginUpdateBudgets.maximumAnswerBytes)
        if response.status == 429 || (response.status == 403 && response.headers["x-ratelimit-remaining"] == "0") {
            let reset = response.headers["x-ratelimit-reset"].flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
            throw PluginUpdateError.rateLimited(resetsAt: reset)
        }
        return response
    }

    /// Every tag starting with `prefix`, however many releases the
    /// repository has.
    private func listTags(of source: PluginUpdateSource, prefix: String) throws -> [String] {
        let response: HTTPSTransportResponse
        do {
            response = try askAPI("repos/\(source.owner)/\(source.repository)/git/matching-refs/tags/\(prefix)")
        } catch let refusal as Refusal {
            throw PluginUpdateError.unreadableAnswer(refusal.reason)
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
            throw PluginUpdateError.unreadableAnswer("it is not a list of tags.")
        }
        let tagPrefix = "refs/tags/" + prefix
        return references.map(\.ref).filter { $0.hasPrefix(tagPrefix) }.map { String($0.dropFirst("refs/tags/".count)) }
    }

    /// The release published under `tag`, or nil when GitHub shows none.
    private func lookUpRelease(_ tag: String, of source: PluginUpdateSource) throws -> Release? {
        let response = try askAPI("repos/\(source.owner)/\(source.repository)/releases/tags/\(tag)")
        switch response.status {
        case 200:
            break
        case 404:
            return nil
        default:
            throw Refusal(reason: "GitHub answered the release lookup with status \(response.status).")
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: response.body), release.tag == tag else {
            throw Refusal(reason: "GitHub's answer is not the release \(tag).")
        }
        return release
    }

    /// Follows GitHub's redirects to its download storage, and nowhere else.
    private func download(_ asset: URL) throws -> Data {
        var url = asset
        for _ in 0...PluginUpdateBudgets.maximumRedirects {
            let response = try send(url, accept: "application/octet-stream", timeout: PluginUpdateBudgets.downloadTimeout,
                                    limit: PluginUpdateBudgets.maximumPackageBytes)
            switch response.status {
            case 200:
                return response.body
            case 301, 302, 303, 307, 308:
                guard let location = response.headers["location"], let next = URL(string: location, relativeTo: url)?.absoluteURL,
                      next.scheme == "https", let host = next.host?.lowercased(),
                      PluginUpdateBudgets.downloadHosts.contains(host), next.user == nil, next.port == nil else {
                    throw Refusal(reason: "The release asset redirects away from GitHub's download storage.")
                }
                url = next
            case 404:
                throw Refusal(reason: "GitHub has no file for this release asset.")
            default:
                throw Refusal(reason: "GitHub answered the download with status \(response.status).")
            }
        }
        throw Refusal(reason: "The release asset redirects more than \(PluginUpdateBudgets.maximumRedirects) times.")
    }
}
