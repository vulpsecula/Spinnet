import Foundation

/// A published Spinnet release newer than the running one.
public struct SpinnetRelease: Equatable, Sendable {
    public let version: String
    /// The release's page on GitHub. A check only links to it; nothing is
    /// downloaded or installed.
    public let page: URL

    public init(version: String, page: URL) {
        self.version = version
        self.page = page
    }
}

/// The outcome of one Spinnet release check.
public enum SpinnetReleaseCheck: Equatable, Sendable {
    case newer(SpinnetRelease)
    /// The running version is the newest; `latest` is the newest published
    /// version, or nil when the repository has published none.
    case upToDate(latest: String?)
}

/// Why a Spinnet release check could not be completed.
public enum SpinnetReleaseCheckError: Error, Equatable, LocalizedError {
    case offline
    case timedOut
    case rateLimited(resetsAt: Date?)
    case unexpectedStatus(Int)
    case unreadableAnswer(HostText)
    /// The running Spinnet's own version is not SemVer, so no release can be
    /// compared with it.
    case runningVersionNotSemVer(String)

    /// What the Host shows, in the interface language. A reset time is
    /// written as whoever shows it writes times.
    public func text(resetTime: (Date) -> String) -> HostText {
        switch self {
        case .offline:
            return HostText("Spinnet could not reach GitHub. Check your connection and try again.")
        case .timedOut:
            return HostText("GitHub did not answer in time. Try again later.")
        case .rateLimited(let reset):
            return PluginUpdateError.rateLimitText(resetsAt: reset, resetTime: resetTime)
        case .unexpectedStatus(let status):
            return HostText("GitHub answered with status %@.", .verbatim(String(status)))
        case .unreadableAnswer(let detail):
            return HostText("GitHub's newest Spinnet release could not be read: %@", detail)
        case .runningVersionNotSemVer(let version):
            return HostText("This Spinnet's version, %@, is not a SemVer version, so it cannot be compared.",
                            .verbatim(version))
        }
    }

    public var errorDescription: String? { text(resetTime: PluginUpdateError.systemResetTime).english }
}

/// Asks GitHub for the Spinnet repository's newest release that is neither a
/// draft nor a prerelease and compares its version by SemVer with the
/// running one. It sends one request and never downloads a release.
public final class SpinnetReleaseChecker {
    /// The repository Spinnet releases are published from.
    public static let repository = try! PluginUpdateSource(github: "vulpsecula/Spinnet")
    public static let maximumAnswerBytes = 1024 * 1024
    public static let answerTimeout: TimeInterval = 15

    private let transport: HTTPSTransport
    private let repository: PluginUpdateSource
    private let runningVersion: String

    public init(transport: HTTPSTransport, repository: PluginUpdateSource = SpinnetReleaseChecker.repository,
                runningVersion: String = HostVersion.currentString) {
        self.transport = transport
        self.repository = repository
        self.runningVersion = runningVersion
    }

    private struct Release: Decodable {
        let tag: String
        let draft: Bool?
        let prerelease: Bool?
        enum CodingKeys: String, CodingKey {
            case tag = "tag_name", draft, prerelease
        }
    }

    public func check() throws -> SpinnetReleaseCheck {
        let url = URL(string: "https://api.github.com/repos/\(repository.owner)/\(repository.repository)/releases/latest")!
        let request = HTTPSTransportRequest(method: "GET", url: url, headers: [
            "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"
        ], body: nil, timeout: Self.answerTimeout, maximumResponseBytes: Self.maximumAnswerBytes)
        let response: HTTPSTransportResponse
        do {
            response = try transport.send(request)
        } catch HTTPSTransportError.timedOut {
            throw SpinnetReleaseCheckError.timedOut
        } catch HTTPSTransportError.responseTooLarge {
            throw SpinnetReleaseCheckError.unreadableAnswer(HostText("it is too large."))
        } catch {
            throw SpinnetReleaseCheckError.offline
        }
        if response.status == 429 || (response.status == 403 && response.headers["x-ratelimit-remaining"] == "0") {
            let reset = response.headers["x-ratelimit-reset"].flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
            throw SpinnetReleaseCheckError.rateLimited(resetsAt: reset)
        }
        switch response.status {
        case 200:
            break
        case 404:
            // GitHub answers so when no release is published yet.
            return .upToDate(latest: nil)
        default:
            throw SpinnetReleaseCheckError.unexpectedStatus(response.status)
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: response.body) else {
            throw SpinnetReleaseCheckError.unreadableAnswer(HostText("it is not a release."))
        }
        guard release.draft != true, release.prerelease != true else {
            throw SpinnetReleaseCheckError.unreadableAnswer(HostText("it is a draft or a prerelease."))
        }
        let written = release.tag.hasPrefix("v") ? String(release.tag.dropFirst()) : release.tag
        guard let latest = try? PluginVersion(written) else {
            throw SpinnetReleaseCheckError.unreadableAnswer(
                HostText("its tag %@ does not name a SemVer version.", .verbatim(release.tag)))
        }
        guard let running = try? PluginVersion(runningVersion) else {
            throw SpinnetReleaseCheckError.runningVersionNotSemVer(runningVersion)
        }
        guard latest > running else { return .upToDate(latest: written) }
        return .newer(SpinnetRelease(version: written, page: page(of: release.tag)))
    }

    /// The release page, made from the tag rather than taken from the answer,
    /// so it always lies in the Spinnet repository on github.com.
    private func page(of tag: String) -> URL {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        let encoded = tag.addingPercentEncoding(withAllowedCharacters: allowed) ?? tag
        return URL(string: "https://github.com/\(repository.github)/releases/tag/\(encoded)")!
    }
}
