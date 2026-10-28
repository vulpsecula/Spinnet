import Foundation

/// The bounds of one Plugin Update check. They are published in the Plugin
/// API's Update Source reference.
public enum PluginUpdateBudgets {
    /// Releases read from one Update Source: GitHub's most recent page.
    public static let maximumReleases = 100
    /// Largest release listing the Host reads.
    public static let maximumListingBytes = 4 * 1024 * 1024
    /// Largest zipped package the Host downloads.
    public static let maximumPackageBytes = 16 * 1024 * 1024
    /// Largest total a package archive may unpack to.
    public static let maximumUnpackedBytes = PluginPackageArchive.maximumUnpackedBytes
    /// Most entries a package archive may hold.
    public static let maximumArchiveEntries = PluginPackageArchive.maximumEntries
    /// Redirects followed from a release asset to GitHub's download storage.
    public static let maximumRedirects = 3
    public static let listingTimeout: TimeInterval = 15
    public static let downloadTimeout: TimeInterval = 60
    /// Hosts a release asset download may be redirected to, all GitHub's.
    public static let downloadHosts: Set<String> = [
        "github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"
    ]
}

/// Why one published version was not accepted as a Plugin Update.
public struct PluginUpdateRefusal: Equatable, Sendable {
    /// The release tag it was published under.
    public let tag: String
    public let reason: String

    public init(tag: String, reason: String) {
        self.tag = tag
        self.reason = reason
    }
}

/// A newer version that passed every acceptance rule, unpacked and reviewed,
/// waiting for the user to apply it.
public struct PluginUpdateCandidate: Equatable {
    public let tag: String
    public let manifest: PluginManifest
    /// What installing it would do, including the Capabilities it newly asks for.
    public let review: PluginInstallationReview
    /// The unpacked package the update installs.
    public let packageURL: URL
}

/// The outcome of checking one installed Plugin's Update Source.
public struct PluginUpdateCheck: Equatable {
    public let pluginID: PluginID
    public let installedVersion: String
    /// The highest accepted newer version, if any.
    public let update: PluginUpdateCandidate?
    /// Newer versions that were refused, with why, highest first.
    public let refusals: [PluginUpdateRefusal]
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
    case malformedReleases(String)
    case changedSinceCheck(String)

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
        case .malformedReleases(let detail):
            return "GitHub's release list could not be read: \(detail)"
        case .changedSinceCheck(let detail):
            return "The update no longer applies: \(detail) Check again."
        }
    }
}

/// Checks a Plugin's Update Source and applies a Plugin Update through the
/// same install-and-replace path as a Library install, so Plugin Storage,
/// Plugin Settings, Menu Items and Capability decisions are kept and newly
/// requested Capabilities are left for the user. Nothing installs unless the
/// caller applies a candidate.
///
/// A published package is accepted only when it came over HTTPS from a
/// release asset of the declared repository on github.com, has the same
/// Plugin identity, declares the same Update Source, has a strictly greater
/// SemVer version than the installed one and satisfies Host Compatibility.
/// The highest accepted version wins.
public final class PluginUpdater {
    private let store: PluginInstallationStore
    private let registry: PluginRegistry
    private let transport: HTTPSTransport
    private let downloads: URL

    /// `downloads` holds unpacked candidates until they are applied or the
    /// next check of the same Plugin replaces them.
    public init(store: PluginInstallationStore, registry: PluginRegistry, transport: HTTPSTransport, downloads: URL) {
        self.store = store
        self.registry = registry
        self.transport = transport
        self.downloads = downloads
    }

    private func installedManifest(_ pluginID: PluginID) throws -> PluginManifest {
        guard let manifest = registry.package(for: pluginID)?.manifest ?? registry.refusedPlugin(pluginID)?.manifest else {
            throw PluginUpdateError.notInstalled(pluginID)
        }
        return manifest
    }

    /// Asks the Update Source for newer versions. Each newer version is
    /// fetched, highest first, until one is accepted.
    public func check(_ pluginID: PluginID) throws -> PluginUpdateCheck {
        let installed = try installedManifest(pluginID)
        guard let source = installed.updateSource else { throw PluginUpdateError.noUpdateSource(installed.name) }
        let current = try PluginVersion(installed.version)
        let releases = try listReleases(of: source)

        let prefix = PluginUpdateSource.releaseTag(for: pluginID, version: "")
        var refusals: [PluginUpdateRefusal] = []
        var newer: [(version: PluginVersion, release: Release)] = []
        for release in releases where release.draft != true && release.prerelease != true && release.tag.hasPrefix(prefix) {
            guard let version = try? PluginVersion(String(release.tag.dropFirst(prefix.count))) else {
                refusals.append(.init(tag: release.tag, reason: "The release tag does not name a SemVer version."))
                continue
            }
            if version > current { newer.append((version, release)) }
        }
        newer.sort { $0.version > $1.version }

        let workspace = downloads.appendingPathComponent(pluginID.rawValue, isDirectory: true)
        try? FileManager.default.removeItem(at: workspace)
        for (version, release) in newer {
            do {
                let candidate = try accept(release, version: version, replacing: installed, source: source,
                                           into: workspace.appendingPathComponent(UUID().uuidString))
                return PluginUpdateCheck(pluginID: pluginID, installedVersion: installed.version,
                                         update: candidate, refusals: refusals)
            } catch let error as PluginUpdateError where error == .offline || error == .timedOut {
                throw error
            } catch {
                refusals.append(.init(tag: release.tag, reason: error.localizedDescription))
            }
        }
        return PluginUpdateCheck(pluginID: pluginID, installedVersion: installed.version, update: nil, refusals: refusals)
    }

    /// Installs a candidate from `check` in place of the installed version,
    /// keeping what an update keeps. Returns the registered manifest.
    @discardableResult
    public func apply(_ candidate: PluginUpdateCandidate) throws -> PluginManifest {
        let installed = try installedManifest(candidate.manifest.id)
        guard let source = installed.updateSource, candidate.manifest.updateSource.map(source.isSame) == true,
              try PluginVersion(candidate.manifest.version) > PluginVersion(installed.version) else {
            throw PluginUpdateError.changedSinceCheck("\(installed.name) \(installed.version) is installed now.")
        }
        guard (try? PluginManifestLoader.load(packageAt: candidate.packageURL).manifest) == candidate.manifest else {
            throw PluginUpdateError.changedSinceCheck("The downloaded package changed.")
        }
        let manifest = try store.install(from: candidate.packageURL)
        try? FileManager.default.removeItem(at: candidate.packageURL.deletingLastPathComponent())
        return manifest
    }

    // MARK: - Acceptance

    private struct Refusal: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    private func accept(_ release: Release, version: PluginVersion, replacing installed: PluginManifest,
                        source: PluginUpdateSource, into directory: URL) throws -> PluginUpdateCandidate {
        let name = PluginUpdateSource.assetName(for: installed.id)
        guard let asset = release.assets.first(where: { $0.name == name }) else {
            throw Refusal(reason: "The release has no asset named \(name).")
        }
        guard let url = URL(string: asset.downloadURL), Self.isReleaseAsset(url, of: source, named: name) else {
            throw Refusal(reason: "The package is not a release asset of \(source.github) on github.com over HTTPS.")
        }
        let archive = try download(url)
        let package: URL
        do {
            package = try PluginPackageArchive.unpack(archive, into: directory)
        } catch let refusal as PluginPackageArchive.Refusal {
            throw Refusal(reason: refusal.reason + ".")
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
        let review = try store.review(package)
        return PluginUpdateCandidate(tag: release.tag, manifest: manifest, review: review, packageURL: package)
    }

    /// `https://github.com/<owner>/<repo>/releases/download/<tag>/<name>`.
    static func isReleaseAsset(_ url: URL, of source: PluginUpdateSource, named name: String) -> Bool {
        guard url.scheme == "https", url.host?.lowercased() == "github.com", url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil else { return false }
        let components = url.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
        guard components.count >= 6, !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              components[0].lowercased() == source.owner.lowercased(),
              components[1].lowercased() == source.repository.lowercased(),
              components[2] == "releases", components[3] == "download", components.last == name else { return false }
        return true
    }

    // MARK: - GitHub

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
            throw Refusal(reason: "GitHub's answer is larger than Spinnet reads.")
        } catch {
            throw PluginUpdateError.offline
        }
    }

    private func listReleases(of source: PluginUpdateSource) throws -> [Release] {
        let url = URL(string: "https://api.github.com/repos/\(source.owner)/\(source.repository)/releases?per_page=\(PluginUpdateBudgets.maximumReleases)")!
        let response: HTTPSTransportResponse
        do {
            response = try send(url, accept: "application/vnd.github+json", timeout: PluginUpdateBudgets.listingTimeout,
                                limit: PluginUpdateBudgets.maximumListingBytes)
        } catch let refusal as Refusal {
            throw PluginUpdateError.malformedReleases(refusal.reason)
        }
        let limited = response.status == 429 || (response.status == 403 && response.headers["x-ratelimit-remaining"] == "0")
        switch response.status {
        case 200:
            break
        case _ where limited:
            let reset = response.headers["x-ratelimit-reset"].flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
            throw PluginUpdateError.rateLimited(resetsAt: reset)
        case 404:
            throw PluginUpdateError.repositoryNotFound(source)
        default:
            throw PluginUpdateError.unexpectedStatus(response.status)
        }
        do {
            return try JSONDecoder().decode([Release].self, from: response.body)
        } catch {
            throw PluginUpdateError.malformedReleases("it is not a list of releases.")
        }
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
