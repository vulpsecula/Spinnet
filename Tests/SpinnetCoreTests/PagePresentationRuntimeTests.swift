import Foundation
import XCTest
@testable import SpinnetCore
import SpinnetPluginTestKit

/// `Tests/Fixtures/MediaPages.spinnetplugin`, an external Plugin declaring
/// Plugin API Level 2, composes a Spotify-shaped track and System
/// Monitor-shaped metric cards from Component Styles, columns, icons,
/// images and progress (#81). It runs as its author runs it: through the
/// public test kit's `PluginTestPage` and the real helper.
final class PagePresentationRuntimeTests: XCTestCase {
    static let media = NamespacesProbeFixture.fixtures.appendingPathComponent("MediaPages.spinnetplugin", isDirectory: true)

    private var helpers: [PluginTestHelper] = []

    override func tearDown() {
        helpers.forEach { $0.shutdown() }
        helpers = []
    }

    private func page(_ command: String, input: JSONValue = .null) throws -> PluginTestPage {
        let helper = try PluginTestHelper(contracts: .host)
        helpers.append(helper)
        return PluginTestPage(command, of: try PluginUnderTest(packageAt: Self.media), helper: helper, input: input)
    }

    private func text(_ id: String, in page: PluginTestPage) throws -> PluginPageText {
        guard case .text(let text)? = page.page?.component(id) else { throw PluginTestPageError.noComponent(id) }
        return text
    }

    /// The track: artwork from the HTTPS host its Command declares, beside
    /// a column of title, artist and album in their own styles, and the
    /// position the Plugin knows as a value.
    func testTheTrackComposesArtworkStyledTextAndItsPosition() throws {
        let track = try page("media.track")
        try track.open()
        let page = try XCTUnwrap(track.page)
        let schema = PagesContractTests.pluginAPI.appendingPathComponent("schemas/pages.schema.json")
        XCTAssertEqual(try JSONSchemaSubsetValidator(definition: "page", inSchemaAt: schema)
            .errors(for: try XCTUnwrap(track.pageJSON)), [], "The SDK builds what the published schema holds")
        XCTAssertEqual(page.components.map(\.kind), [.row, .image, .column, .text, .text, .text, .progress, .actions])
        guard case .image(let artwork)? = page.component("artwork") else { return XCTFail("No artwork") }
        XCTAssertEqual(artwork.source.host, "i.scdn.co")
        XCTAssertEqual(artwork.request.maximumPixelSize, 192, "Decoded at twice its 96 points")
        XCTAssertEqual(artwork.fit, .fill)
        XCTAssertEqual(track.images()["artwork"], .loading, "Its Command may contact i.scdn.co once granted")

        let title = try text("title", in: track)
        XCTAssertEqual(title.style?.fontSize, 17)
        XCTAssertEqual(title.style?.fontWeight, .semibold)
        XCTAssertEqual(try text("artist", in: track).style?.color, .named(.secondary))
        let light: PluginPageColor = .rgb(red: 26.0 / 255, green: 127.0 / 255, blue: 55.0 / 255, alpha: 1)
        let dark: PluginPageColor = .rgb(red: 30.0 / 255, green: 215.0 / 255, blue: 96.0 / 255, alpha: 1)
        XCTAssertEqual(try text("album", in: track).style?.color, .appearance(light: light, dark: dark))
        guard case .progress(let position)? = page.component("position") else { return XCTFail("No position") }
        XCTAssertEqual(try XCTUnwrap(position.value), 133.0 / 485.0, accuracy: 0.0001)
        XCTAssertEqual(position.status, "2:13 of 8:05")
        XCTAssertNil(position.cancel)

        // A refresh of the same page keeps it; the Host keeps the picture,
        // since the request is unchanged.
        try track.click("toggle")
        XCTAssertEqual(track.page?.id, "track")
        XCTAssertEqual(track.page?.imageRequests, page.imageRequests)
        try track.click("next")
        XCTAssertNotEqual(track.page?.imageRequests, page.imageRequests, "Another track names another picture")
    }

    /// Offline, the artwork is the package's own resource, which the Host
    /// reads and decodes to the size it is drawn at.
    func testOfflineArtworkIsThePackagesResource() throws {
        let track = try page("media.track", input: .object(["offline": .bool(true)]))
        try track.open()
        guard case .loaded(let image)? = track.images()["artwork"] else {
            return XCTFail("\(track.images())")
        }
        XCTAssertEqual(max(image.width, image.height), 192)
    }

    /// The metric cards: styled columns in rows, each with a system icon,
    /// a large value in monospaced digits and a bar of the measured
    /// fraction; a refresh changes the values and keeps the page.
    func testTheMetricsComposeCardsOfIconsValuesAndBars() throws {
        let metrics = try page("media.metrics")
        try metrics.open()
        let page = try XCTUnwrap(metrics.page)
        let schema = PagesContractTests.pluginAPI.appendingPathComponent("schemas/pages.schema.json")
        XCTAssertEqual(try JSONSchemaSubsetValidator(definition: "page", inSchemaAt: schema)
            .errors(for: try XCTUnwrap(metrics.pageJSON)), [])
        guard case .column(let cpu)? = page.component("cpu") else { return XCTFail("No CPU card") }
        XCTAssertEqual(cpu.style?.padding, 10)
        XCTAssertEqual(cpu.style?.cornerRadius, 8)
        XCTAssertNotNil(cpu.style?.background)
        guard case .icon(let icon)? = page.component("cpu-icon") else { return XCTFail("No icon") }
        XCTAssertEqual(icon.symbol.name, "cpu")
        XCTAssertNil(icon.label, "Decoration: the card's title says what it is")
        let value = try text("cpu-value", in: metrics)
        XCTAssertEqual(value.text, "23%")
        XCTAssertEqual(value.style?.monospacedDigits, true)
        XCTAssertEqual(value.style?.fontSize, 28)
        guard case .progress(let bar)? = page.component("cpu-bar") else { return XCTFail("No bar") }
        XCTAssertEqual(bar.value, 0.23)
        XCTAssertEqual(bar.accessibilityValue, "All cores, 23 percent")
        XCTAssertTrue(metrics.images().isEmpty, "Icons are symbols the Host draws; nothing is loaded")

        try metrics.click("refresh")
        XCTAssertEqual(try text("cpu-value", in: metrics).text, "71%")
        guard case .icon(let battery)? = metrics.page?.component("battery-icon") else { return XCTFail("No battery") }
        XCTAssertEqual(battery.symbol.name, "battery.100.bolt")
    }

    /// An Image Source grants nothing: a Command that does not declare
    /// `contact_https` could not load an HTTPS picture, nor any Command one
    /// from a host it does not declare or the user did not add.
    func testAnImageSourceHasNoAuthorityOfItsOwn() throws {
        let manifest = try PluginManifestLoader.load(packageAt: Self.media).manifest
        let artwork = PluginImageSource.url(URL(string: "https://i.scdn.co/image/a")!)
        XCTAssertNil(manifest.refusal(toLoad: artwork, for: CommandID("media.track")))
        XCTAssertEqual(manifest.refusal(toLoad: artwork, for: CommandID("media.metrics")),
                       "Network access is not granted to this Plugin")
        let elsewhere = PluginImageSource.url(URL(string: "https://images.example.com/a.png")!)
        XCTAssertEqual(manifest.refusal(toLoad: elsewhere, for: CommandID("media.track")),
                       "Media Pages may not contact images.example.com until it is allowed in its Plugin Settings")
        XCTAssertNil(manifest.refusal(toLoad: elsewhere, for: CommandID("media.track"), consentedHosts: ["images.example.com"]))
        XCTAssertNil(manifest.refusal(toLoad: .resource("artwork/offline.png"), for: CommandID("media.metrics")))
    }
}
