import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import SpinnetCore

/// Pictures the Host loads for `image` components (#81), at the seams that
/// carry their authority and bounds: the broker that reads a source with
/// the handler's authority, the decoder that holds a picture to
/// `PageImageBudgets`, and the engine that schedules, keeps and lets go of
/// pictures for open pages.
enum PageImageSamples {
    /// A PNG or JPEG of `width` × `height` pixels.
    static func image(_ width: Int, _ height: Int, type: UTType = .png) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }
}

final class PageImageBrokerTests: XCTestCase {
    private var manifest: PluginManifest!
    private var registry: PluginRegistry!
    private var grants: PluginCapabilityGrantStore!
    private var credentials: InMemoryPluginCredentialStore!
    private var transport: RoutedHTTPSTransport!
    private var root: URL!

    override func setUpWithError() throws {
        manifest = try NetworkPluginFixture.manifest(hosts: ["api.example.com"])
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("art"), withIntermediateDirectories: true)
        try PageImageSamples.image(8, 8).write(to: root.appendingPathComponent("art/cover.png"))
        grants = PluginCapabilityGrantStore()
        for capability in manifest.capabilities {
            grants.setDecision(.granted, for: manifest.id, pluginVersion: manifest.version,
                               capability: capability, scope: manifest.scope(for: capability))
        }
        registry = PluginRegistry()
        try registry.register(PluginPackage(rootURL: root, manifest: manifest))
        credentials = InMemoryPluginCredentialStore()
        try credentials.setSecret("s3cret", for: manifest.id, reference: "key")
        transport = RoutedHTTPSTransport(["api.example.com": .init(response: HTTPSTransportResponse(
            status: 200, headers: ["content-type": "image/png"], body: PageImageSamples.image(4, 4)))])
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private var broker: CapabilityCheckedHostServiceBroker {
        CapabilityCheckedHostServiceBroker(
            grantStore: grants, systemPermissionCheck: { _ in true },
            selectedTextProvider: { _ in "" }, clipboardWriter: { _ in },
            httpsTransport: transport, credentialStore: credentials, responseCache: FetchedResponseCache()
        )
    }

    private func load(_ source: PluginImageSource, from commandID: String = "fetch") throws -> Data {
        let command = try XCTUnwrap(manifest.commands.first { $0.id.rawValue == commandID })
        let action = try ActionConfiguration(id: ActionID(commandID), pluginID: manifest.id, command: command, input: .null)
        return try broker.loadPageImage(source, for: action, using: registry, cancellation: .init())
    }

    private func url(_ address: String) -> PluginImageSource { .url(URL(string: address)!) }

    /// A picture is a bare GET: no header of the Plugin's, no Credential
    /// Use, though the Plugin stores one, within the image's byte budget and
    /// a Host-Fetched Section's time.
    func testAnHTTPSPictureIsABareGetWithinItsBudgets() throws {
        let data = try load(url("https://api.example.com/cover.png"))
        XCTAssertEqual(data, PageImageSamples.image(4, 4))
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.headers, ["Accept": "image/png, image/jpeg"])
        XCTAssertNil(request.body)
        XCTAssertEqual(request.maximumResponseBytes, PageImageBudgets.maximumImageBytes)
        XCTAssertLessThanOrEqual(request.timeout, PageImageBudgets.loadDeadline)
    }

    /// The source grants nothing: the grant, the Command's declaration and
    /// the hosts are read afresh for every picture, redirects included.
    func testAPictureNeedsTheHandlersOwnHTTPSAuthority() throws {
        XCTAssertThrowsError(try load(url("https://api.example.com/a.png"), from: "copy")) {
            XCTAssertEqual($0 as? PluginHostServiceError, .capabilityDenied(.contactHTTPS))
        }
        XCTAssertThrowsError(try load(url("https://elsewhere.example.com/a.png"))) {
            XCTAssertEqual($0 as? PluginHostServiceError, .failed(
                "Network Example may not contact elsewhere.example.com until it is allowed in its Plugin Settings"))
        }
        transport.answer("api.example.com", with: .init(response: HTTPSTransportResponse(
            status: 302, headers: ["location": "https://elsewhere.example.com/a.png"], body: Data())))
        XCTAssertThrowsError(try load(url("https://api.example.com/a.png"))) {
            XCTAssertEqual($0 as? PluginHostServiceError, .failed(
                "The server redirected to elsewhere.example.com, which is outside the consented hosts"))
        }
        transport.answer("api.example.com", with: .init(response: HTTPSTransportResponse(status: 404, headers: [:], body: Data())))
        XCTAssertThrowsError(try load(url("https://api.example.com/a.png"))) {
            XCTAssertEqual($0 as? PluginHostServiceError, .failed("The image's server answered 404"))
        }
        grants.setDecision(.denied, for: manifest.id, pluginVersion: manifest.version,
                           capability: .contactHTTPS, scope: manifest.scope(for: .contactHTTPS))
        let sent = transport.requests.count
        XCTAssertThrowsError(try load(url("https://api.example.com/a.png"))) {
            XCTAssertEqual($0 as? PluginHostServiceError, .capabilityDenied(.contactHTTPS))
        }
        XCTAssertEqual(transport.requests.count, sent, "A revoked grant sends nothing")
    }

    /// A resource is read from the package and nowhere else, links
    /// followed; it needs no Capability.
    func testAResourceStaysInsideThePackage() throws {
        XCTAssertEqual(try load(.resource("art/cover.png"), from: "copy"), PageImageSamples.image(8, 8))
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        try PageImageSamples.image(2, 2).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("art/escape.png"), withDestinationURL: outside)
        XCTAssertThrowsError(try load(.resource("art/escape.png"))) {
            XCTAssertEqual($0 as? PluginHostServiceError, .failed("The image resource art/escape.png leads outside the package"))
        }
        XCTAssertThrowsError(try load(.resource("art/missing.png"))) {
            XCTAssertEqual($0 as? PluginHostServiceError, .failed("The image resource art/missing.png is not in the package"))
        }
        XCTAssertThrowsError(try PluginPackageResource.read("../etc/x.png", in: root))
    }
}

final class PageImageDecoderTests: XCTestCase {
    /// Decoding scales down to the size drawn, never up, and refuses what
    /// passes the budgets or is not a PNG or JPEG.
    func testDecodingHoldsAPictureToTheBudgets() throws {
        let photo = try PageImageDecoder.decode(PageImageSamples.image(1000, 500, type: .jpeg), maximumPixelSize: 192)
        XCTAssertEqual([photo.width, photo.height], [192, 96])
        let small = try PageImageDecoder.decode(PageImageSamples.image(40, 40), maximumPixelSize: 192)
        XCTAssertEqual(small.width, 40)
        XCTAssertLessThanOrEqual(PageImageDecoder.cost(of: photo), 192 * 96 * 4 + 64 * 96)

        let tooMany = PageImageSamples.image(2049, 2048)
        XCTAssertLessThan(tooMany.count, PageImageBudgets.maximumImageBytes)
        XCTAssertThrowsError(try PageImageDecoder.decode(tooMany, maximumPixelSize: 192))
        XCTAssertNoThrow(try PageImageDecoder.decode(PageImageSamples.image(4096, 1024), maximumPixelSize: 192))
        XCTAssertThrowsError(try PageImageDecoder.decode(PageImageSamples.image(4097, 100), maximumPixelSize: 192))
        XCTAssertThrowsError(try PageImageDecoder.decode(PageImageSamples.image(8, 8, type: .tiff), maximumPixelSize: 16)) {
            XCTAssertEqual($0 as? PluginHostServiceError, .failed("The image is not a PNG or JPEG"))
        }
        XCTAssertThrowsError(try PageImageDecoder.decode(Data(count: PageImageBudgets.maximumImageBytes + 1), maximumPixelSize: 16))
    }
}

final class PluginPageImagesTests: XCTestCase {
    private let plugin = PluginID("com.example.network")
    private var pending: [() -> Void] = []
    private var changes = 0

    private func engine(maximum: Int = 2, cacheBytes: Int = PageImageBudgets.cacheBytes,
                        failing: Set<String> = []) -> PluginPageImages {
        let images = PluginPageImages(
            load: { _, source, _ in
                if case .url(let url) = source, failing.contains(url.path) {
                    throw PluginHostServiceError.failed("The image's server answered 500")
                }
                return PageImageSamples.image(64, 64)
            },
            // Each load waits until the test lets it run.
            background: { [unowned self] work in pending.append(work) },
            executor: { $0() }, maximumConcurrentLoads: maximum, cacheBytes: cacheBytes)
        images.onChange = { [unowned self] _ in changes += 1 }
        return images
    }

    private func runPending() {
        while !pending.isEmpty { pending.removeFirst()() }
    }

    private func request(_ name: String, size: Int = 64) -> PageImageRequest {
        PageImageRequest(source: .url(URL(string: "https://api.example.com/\(name)")!), maximumPixelSize: size)
    }

    private func action(_ command: String = "fetch") throws -> ActionConfiguration {
        let manifest = try NetworkPluginFixture.manifest()
        let declared = try XCTUnwrap(manifest.commands.first { $0.id.rawValue == command })
        return try ActionConfiguration(id: ActionID(command), pluginID: manifest.id, command: declared, input: .null)
    }

    /// At most the budget's loads run at once; the others wait their turn.
    func testLoadsRunAtMostTheBudgetAtOnce() throws {
        let images = engine(maximum: 2)
        let requests = (0..<5).map { request("\($0).png") }
        images.present(requests, for: plugin, as: try action())
        XCTAssertEqual(images.runningLoads, 2)
        XCTAssertEqual(pending.count, 2)
        runPending()
        XCTAssertEqual(images.mostLoadsAtOnce, 2)
        for request in requests {
            guard case .loaded? = images.state(of: request, for: plugin) else { return XCTFail("\(request)") }
        }
    }

    /// An answer that shows the same picture again loads nothing; a failed
    /// one stays failed until the user tries again.
    func testAPictureIsKeptAcrossAnswersAndAFailureUntilRetried() throws {
        let images = engine(failing: ["/broken.png"])
        let cover = request("cover.png"), broken = request("broken.png")
        images.present([cover, broken], for: plugin, as: try action())
        runPending()
        XCTAssertEqual(images.state(of: broken, for: plugin), .failed("The image's server answered 500"))
        images.present([cover, broken], for: plugin, as: try action())
        XCTAssertTrue(pending.isEmpty, "Nothing is loaded again, a failure included")
        images.retry(broken, for: plugin, as: try action())
        XCTAssertEqual(images.state(of: broken, for: plugin), .loading)
        XCTAssertEqual(pending.count, 1)
        // Left out of the page and shown again: kept for the session.
        images.present([], for: plugin, as: try action())
        images.present([cover], for: plugin, as: try action())
        guard case .loaded? = images.state(of: cover, for: plugin) else { return XCTFail("Not kept") }
    }

    /// Another Command's handler never shows a picture loaded under the
    /// first one's authority: it loads it under its own.
    func testAnotherCommandLoadsUnderItsOwnAuthority() throws {
        let images = engine()
        let cover = request("cover.png")
        images.present([cover], for: plugin, as: try action("fetch"))
        runPending()
        images.present([cover], for: plugin, as: try action("copy"))
        XCTAssertEqual(images.state(of: cover, for: plugin), .loading)
        XCTAssertEqual(pending.count, 1)
    }

    /// Ending the session cancels its loads, drops what arrives later and
    /// lets its pictures go.
    func testEndingTheSessionCancelsAndLetsGo() throws {
        let images = engine()
        let cover = request("cover.png"), late = request("late.png")
        images.present([cover], for: plugin, as: try action())
        runPending()
        XCTAssertGreaterThan(images.cachedBytes, 0)
        images.present([cover, late], for: plugin, as: try action())
        images.end(plugin: plugin)
        XCTAssertEqual(images.cachedBytes, 0)
        runPending()
        XCTAssertNil(images.state(of: late, for: plugin), "A late reply finds no page")
        XCTAssertEqual(images.runningLoads, 0)
    }

    /// The kept pictures stay within the cache's bytes, the least recently
    /// shown going first.
    func testTheCacheStaysWithinItsBytes() throws {
        let one = 64 * 64 * 4
        let images = engine(maximum: 8, cacheBytes: one * 2)
        let requests = (0..<4).map { request("\($0).png") }
        images.present(requests, for: plugin, as: try action())
        runPending()
        XCTAssertLessThanOrEqual(images.cachedBytes, one * 2)
        images.present([], for: plugin, as: try action())
        images.present([requests[0]], for: plugin, as: try action())
        XCTAssertEqual(images.state(of: requests[0], for: plugin), .loading, "The oldest was let go")
    }
}
