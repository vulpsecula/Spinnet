import Foundation
import SpinnetCore

/// Answers recorded GitHub responses by exact URL and records what the Host
/// asked for, so no test reaches the network. An unrecorded URL fails as if
/// the Mac were offline, and an answer larger than the request reads fails
/// as the real transport does.
public final class RecordedGitHubTransport: HTTPSTransport {
    private let lock = NSLock()
    private var answers: [String: HTTPSTransportResponse] = [:]
    private var sent: [HTTPSTransportRequest] = []

    public init() {}

    public var requests: [HTTPSTransportRequest] { lock.withLock { sent } }
    public var requestedURLs: [String] { requests.map(\.url.absoluteString) }

    public func answer(_ url: String, status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
        lock.withLock { answers[url] = HTTPSTransportResponse(status: status, headers: headers, body: body) }
    }

    public func send(_ request: HTTPSTransportRequest) throws -> HTTPSTransportResponse {
        let answer = lock.withLock { () -> HTTPSTransportResponse? in
            sent.append(request)
            return answers[request.url.absoluteString]
        }
        guard let answer else { throw HTTPSTransportError.connectionFailed }
        guard answer.body.count <= request.maximumResponseBytes else { throw HTTPSTransportError.responseTooLarge }
        return answer
    }
}

/// Packages and GitHub answers as SpinnetPlugins would publish them.
public enum PluginReleaseFixture {
    public static let pluginID = PluginID("com.example.updatable")
    public static let repository = "example-org/plugins"
    /// The Plugin's release tags, matched by prefix.
    public static let tagsURL = "https://api.github.com/repos/example-org/plugins/git/matching-refs/tags/com.example.updatable/v"

    /// The release published under `tag`.
    public static func releaseURL(tag: String) -> String {
        "https://api.github.com/repos/example-org/plugins/releases/tags/\(tag)"
    }

    public static func manifest(id: String = pluginID.rawValue, version: String,
                         updateSource: String? = repository, engines: String = "^1.0.0",
                         capabilities: [String] = ["write_clipboard"]) -> [String: Any] {
        var manifest: [String: Any] = [
            "protocol_version": "1.0", "engines": ["spinnet": engines],
            "id": id, "name": "Updatable", "version": version,
            "capabilities": capabilities,
            "commands": [["id": "updatable.run", "title": "Run", "execution": "javascript", "script": "run.js"]]
        ]
        if let updateSource { manifest["update_source"] = ["github": updateSource] }
        return manifest
    }

    /// A package directory on disk.
    public static func package(_ manifest: [String: Any], in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("Updatable.spinnetplugin")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: manifest).write(to: url.appendingPathComponent("manifest.json"))
        try Data("spinnet.answer(null)".utf8).write(to: url.appendingPathComponent("run.js"))
        return url
    }

    /// The package zipped the way Finder or `ditto` zips a folder.
    public static func zipped(_ manifest: [String: Any], in directory: URL) throws -> Data {
        let package = try package(manifest, in: directory)
        let archive = package.deletingLastPathComponent().appendingPathComponent("package.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", package.path, archive.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        return try Data(contentsOf: archive)
    }

    public static func assetURL(tag: String, name: String = assetName, repository: String = repository) -> String {
        "https://github.com/\(repository)/releases/download/\(tag)/\(name)"
    }

    public static var assetName: String { "\(pluginID.rawValue).spinnetplugin.zip" }

    public struct Release {
        public var tag: String
        public var assets: [(name: String, url: String)]
        public var prerelease = false
        /// GitHub answers a draft, or a tag with no release, as not found.
        public var draft = false

        public init(tag: String, assets: [(name: String, url: String)]? = nil, prerelease: Bool = false, draft: Bool = false) {
            self.tag = tag
            self.assets = assets ?? [(PluginReleaseFixture.assetName, PluginReleaseFixture.assetURL(tag: tag))]
            self.prerelease = prerelease
            self.draft = draft
        }
    }

    /// Records the repository's answers for `releases`: the tags under the
    /// Plugin's prefix, as GitHub matches them, and each release.
    public static func publish(_ releases: [Release], on transport: RecordedGitHubTransport) throws {
        let prefix = "\(pluginID.rawValue)/v"
        transport.answer(tagsURL, body: try tagList(releases.map(\.tag).filter { $0.hasPrefix(prefix) }))
        for release in releases {
            guard !release.draft else {
                transport.answer(releaseURL(tag: release.tag), status: 404, body: Data(#"{"message": "Not Found"}"#.utf8))
                continue
            }
            transport.answer(releaseURL(tag: release.tag), body: try JSONSerialization.data(withJSONObject: [
                "id": 1, "tag_name": release.tag, "name": release.tag, "body": "Notes",
                "draft": false, "prerelease": release.prerelease,
                "assets": release.assets.enumerated().map { index, asset in
                    ["id": index, "name": asset.name, "browser_download_url": asset.url,
                     "content_type": "application/zip", "size": 1]
                }
            ] as [String: Any]))
        }
    }

    /// GitHub's matching-refs answer listing `tags`.
    public static func tagList(_ tags: [String]) throws -> Data {
        try JSONSerialization.data(withJSONObject: tags.map { tag in
            [
                "ref": "refs/tags/\(tag)", "node_id": "REF",
                "url": "https://api.github.com/repos/\(repository)/git/refs/tags/\(tag)",
                "object": ["sha": String(repeating: "0", count: 40), "type": "commit",
                           "url": "https://api.github.com/repos/\(repository)/git/commits/0"]
            ] as [String: Any]
        })
    }
}
