import Foundation

/// One Plugin advertised by a repository's published releases. Its title is
/// supplied by the release, not the package's manifest; installation checks
/// the package before accepting it.
public struct PublishedPlugin: Equatable, Sendable, Identifiable {
    public let id: PluginID
    public let releaseTitle: String
    public let version: String

    public init(id: PluginID, releaseTitle: String, version: String) {
        self.id = id
        self.releaseTitle = releaseTitle
        self.version = version
    }
}

public struct PluginRepositoryListing: Equatable, Sendable {
    public let plugins: [PublishedPlugin]
    /// More releases may exist beyond the pages read for this listing.
    public let isTruncated: Bool

    public init(plugins: [PublishedPlugin], isTruncated: Bool) {
        self.plugins = plugins
        self.isTruncated = isTruncated
    }
}

public enum PluginRepositoryError: Error, Equatable, LocalizedError {
    case unreadableAnswer(HostText)
    case rateLimited(resetsAt: Date?)

    public func text(resetTime: (Date) -> String) -> HostText {
        switch self {
        case .unreadableAnswer(let detail):
            return HostText("GitHub's Plugin releases could not be read: %@", detail)
        case .rateLimited(let reset):
            guard let reset else { return HostText("GitHub's request limit is reached. Try again later.") }
            return HostText("GitHub's request limit is reached. Try again after %@.", .verbatim(resetTime(reset)))
        }
    }

    public var errorDescription: String? { text(resetTime: PluginUpdateError.systemResetTime).english }
}

/// Lists the published Plugin releases of a public GitHub repository without
/// downloading packages. Installing a result still goes through PluginUpdater.
public final class PluginRepositoryBrowser {
    public static let releasesPerPage = 100
    public static let maximumPages = 10

    private let transport: HTTPSTransport

    public init(transport: HTTPSTransport) { self.transport = transport }

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
        let name: String?
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]
        enum CodingKeys: String, CodingKey {
            case tag = "tag_name", name, draft, prerelease, assets
        }
    }

    public func list(_ source: PluginUpdateSource,
                     cancellation: HostFetchedSections.Cancellation = .init()) throws -> PluginRepositoryListing {
        var found: [PluginID: (version: PluginVersion, plugin: PublishedPlugin)] = [:]
        for page in 1...Self.maximumPages {
            let releases = try releases(in: source, page: page, cancellation: cancellation)
            for release in releases {
                guard release.draft != true, release.prerelease != true,
                      let separator = release.tag.range(of: "/v") else { continue }
                let id = PluginID(String(release.tag[..<separator.lowerBound]))
                let writtenVersion = String(release.tag[separator.upperBound...])
                guard PluginUpdateSource.isTagSafe(id), let version = try? PluginVersion(writtenVersion),
                      let asset = release.assets.first(where: { $0.name == PluginUpdateSource.assetName(for: id) }),
                      let url = URL(string: asset.downloadURL),
                      PluginUpdater.isReleaseAsset(url, of: source, tag: release.tag, named: asset.name) else { continue }
                if let current = found[id], current.version >= version { continue }
                let suppliedName = release.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let title = suppliedName.isEmpty ? id.rawValue : String(suppliedName.prefix(120))
                found[id] = (version, PublishedPlugin(id: id, releaseTitle: title, version: writtenVersion))
            }
            if releases.count < Self.releasesPerPage {
                return listing(found, isTruncated: false)
            }
        }
        return listing(found, isTruncated: true)
    }

    private func listing(_ found: [PluginID: (version: PluginVersion, plugin: PublishedPlugin)],
                         isTruncated: Bool) -> PluginRepositoryListing {
        let plugins = found.values.map(\.plugin).sorted {
            let order = $0.releaseTitle.localizedCaseInsensitiveCompare($1.releaseTitle)
            return order == .orderedSame ? $0.id.rawValue < $1.id.rawValue : order == .orderedAscending
        }
        return PluginRepositoryListing(plugins: plugins, isTruncated: isTruncated)
    }

    private func releases(in source: PluginUpdateSource, page: Int,
                          cancellation: HostFetchedSections.Cancellation) throws -> [Release] {
        let url = URL(string: "https://api.github.com/repos/\(source.github)/releases?per_page=\(Self.releasesPerPage)&page=\(page)")!
        let request = HTTPSTransportRequest(method: "GET", url: url, headers: [
            "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"
        ], body: nil, timeout: PluginUpdateBudgets.answerTimeout,
            maximumResponseBytes: PluginUpdateBudgets.maximumAnswerBytes)
        let response: HTTPSTransportResponse
        do {
            response = try transport.send(request, cancellation: cancellation)
        } catch HTTPSTransportError.cancelled {
            throw HTTPSTransportError.cancelled
        } catch HTTPSTransportError.timedOut {
            throw PluginUpdateError.timedOut
        } catch HTTPSTransportError.responseTooLarge {
            throw PluginRepositoryError.unreadableAnswer(PluginUpdater.tooLarge)
        } catch {
            throw PluginUpdateError.offline
        }
        if response.status == 429 || (response.status == 403 && response.headers["x-ratelimit-remaining"] == "0") {
            let reset = response.headers["x-ratelimit-reset"].flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
            throw PluginRepositoryError.rateLimited(resetsAt: reset)
        }
        switch response.status {
        case 200: break
        case 404: throw PluginUpdateError.repositoryNotFound(source)
        default: throw PluginUpdateError.unexpectedStatus(response.status)
        }
        guard let releases = try? JSONDecoder().decode([Release].self, from: response.body) else {
            throw PluginRepositoryError.unreadableAnswer(HostText("it is not a list of releases."))
        }
        return releases
    }
}
