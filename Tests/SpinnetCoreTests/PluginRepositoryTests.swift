import Foundation
import SpinnetTestSupport
import XCTest
@testable import SpinnetCore

final class PluginRepositoryTests: XCTestCase {
    private let repository = "example-org/plugins"
    private var source: PluginUpdateSource { try! PluginUpdateSource(github: repository) }
    private var transport: RecordedGitHubTransport!
    private var browser: PluginRepositoryBrowser!

    override func setUp() {
        transport = RecordedGitHubTransport()
        browser = PluginRepositoryBrowser(transport: transport)
    }

    private func url(_ page: Int) -> String {
        "https://api.github.com/repos/\(repository)/releases?per_page=100&page=\(page)"
    }

    private func release(_ id: String, _ version: String, name: String? = nil, draft: Bool = false,
                         prerelease: Bool = false, assetRepository: String? = nil) -> [String: Any] {
        let tag = "\(id)/v\(version)"
        let asset = "\(id).spinnetplugin.zip"
        return ["tag_name": tag, "name": name ?? id, "draft": draft, "prerelease": prerelease,
                "assets": [["name": asset,
                            "browser_download_url": "https://github.com/\(assetRepository ?? repository)/releases/download/\(tag)/\(asset)"]]]
    }

    private func answer(_ page: Int, _ releases: [[String: Any]]) throws {
        transport.answer(url(page), body: try JSONSerialization.data(withJSONObject: releases))
    }

    func testListsEveryPageAndUsesHighestPublishedVersionWithoutDownloading() throws {
        var first = [release("com.example.alpha", "1.0.0", name: "Alpha 1.0.0")]
        first += Array(repeating: release("com.example.invalid", "next"), count: 99)
        try answer(1, first)
        try answer(2, [release("com.example.alpha", "2.0.0", name: "Alpha 2.0.0"),
                       release("com.example.beta", "1.0.0", name: "Beta"),
                       release("com.example.draft", "1.0.0", draft: true),
                       release("com.example.preview", "1.0.0", prerelease: true),
                       release("com.example.foreign", "1.0.0", assetRepository: "other/repo"),
                       release("../bad", "1.0.0")])

        let result = try browser.list(source)

        XCTAssertEqual(result.plugins, [PublishedPlugin(id: PluginID("com.example.alpha"), releaseTitle: "Alpha 2.0.0", version: "2.0.0"),
                                        PublishedPlugin(id: PluginID("com.example.beta"), releaseTitle: "Beta", version: "1.0.0")])
        XCTAssertFalse(result.isTruncated)
        XCTAssertEqual(transport.requestedURLs, [url(1), url(2)])
    }

    func testReportsWhenTheBoundedListingMayOmitFurtherReleases() throws {
        let page = Array(repeating: release("com.example.alpha", "1.0.0"), count: 100)
        for number in 1...PluginRepositoryBrowser.maximumPages { try answer(number, page) }

        let result = try browser.list(source)

        XCTAssertEqual(result.plugins.count, 1)
        XCTAssertTrue(result.isTruncated)
        XCTAssertEqual(transport.requests.count, PluginRepositoryBrowser.maximumPages)
    }

    func testReportsMalformedResponsesAndGitHubRateLimits() throws {
        transport.answer(url(1), body: Data("{}".utf8))
        XCTAssertThrowsError(try browser.list(source)) {
            XCTAssertEqual($0 as? PluginRepositoryError, .unreadableAnswer(HostText("it is not a list of releases.")))
        }
        transport.answer(url(1), status: 403, headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "100"])
        XCTAssertThrowsError(try browser.list(source)) {
            XCTAssertEqual($0 as? PluginRepositoryError, .rateLimited(resetsAt: Date(timeIntervalSince1970: 100)))
        }
    }

    func testCancellationStopsBeforeAnotherPage() throws {
        try answer(1, Array(repeating: release("com.example.alpha", "1.0.0"), count: 100))
        let cancelling = CancellingRepositoryTransport(recorded: transport, cancelOn: url(1))
        let browser = PluginRepositoryBrowser(transport: cancelling)
        let cancellation = HostFetchedSections.Cancellation()

        XCTAssertThrowsError(try browser.list(source, cancellation: cancellation)) {
            XCTAssertEqual($0 as? HTTPSTransportError, .cancelled)
        }
        XCTAssertEqual(transport.requestedURLs, [url(1)])
    }

    func testCancellingThePackageDownloadStopsTheLookupWithoutTryingOlderReleases() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = PluginRegistry()
        let store = PluginInstallationStore(directory: directory.appendingPathComponent("Installed"), registry: registry,
                                            grants: PluginCapabilityGrantStore(), persistGrants: {})
        let newest = "com.example.updatable/v2.0.0"
        let older = "com.example.updatable/v1.0.0"
        try PluginReleaseFixture.publish([.init(tag: newest), .init(tag: older)], on: transport)
        let cancelling = CancellingRepositoryTransport(recorded: transport,
                                                        cancelOn: PluginReleaseFixture.assetURL(tag: newest))
        let updater = PluginUpdater(store: store, registry: registry, transport: cancelling,
                                    downloads: directory.appendingPathComponent("Downloads"))

        XCTAssertThrowsError(try updater.newestRelease(of: PluginReleaseFixture.pluginID, named: "Updatable",
                                                       from: source, cancellation: .init())) {
            XCTAssertEqual($0 as? HTTPSTransportError, .cancelled)
        }
        XCTAssertFalse(transport.requestedURLs.contains(PluginReleaseFixture.releaseURL(tag: older)))
        XCTAssertNil(registry.package(for: PluginReleaseFixture.pluginID))
    }
}

/// Cancels during a chosen request, standing in for a transport that aborts
/// its transfer when the browser closes.
private final class CancellingRepositoryTransport: HTTPSTransport {
    let recorded: RecordedGitHubTransport
    let cancelOn: String

    init(recorded: RecordedGitHubTransport, cancelOn: String) {
        self.recorded = recorded
        self.cancelOn = cancelOn
    }

    func send(_ request: HTTPSTransportRequest) throws -> HTTPSTransportResponse {
        try recorded.send(request)
    }

    func send(_ request: HTTPSTransportRequest,
              cancellation: HostFetchedSections.Cancellation) throws -> HTTPSTransportResponse {
        guard !cancellation.isCancelled else { throw HTTPSTransportError.cancelled }
        if request.url.absoluteString == cancelOn {
            if request.url.absoluteString.contains("/releases/download/") {
                cancellation.cancel()
                throw HTTPSTransportError.cancelled
            }
            let response = try recorded.send(request)
            cancellation.cancel()
            return response
        }
        return try recorded.send(request)
    }
}
