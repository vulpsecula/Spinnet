import Foundation
import XCTest
@testable import SpinnetCore

/// Component Styles, columns, icons, images and progress, as `PluginAPI/`
/// publishes them and the Host reads them. Parser membership is enforced,
/// semantic page rules explain refusals, and public artifacts list each member.
final class PagePresentationContractTests: XCTestCase {
    private static let pluginAPI = PagesContractTests.pluginAPI

    private func text(_ path: String) throws -> String {
        try String(contentsOf: Self.pluginAPI.appendingPathComponent(path), encoding: .utf8)
    }

    private func answer(_ file: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf:
            Self.pluginAPI.appendingPathComponent("fixtures/pages").appendingPathComponent(file)))
    }

    func testPresentationMembersArePublishedAndCanBeDenied() {
        let current = CollectionsFixtures.permits, denied = CollectionsFixtures.denied
        for member in PagePresentation.members {
            XCTAssertTrue(current(member), "\(member)")
            XCTAssertFalse(denied(member), "\(member)")
        }
        XCTAssertEqual(Set(PagePresentation.componentKinds + CollectionsContract.componentKinds + ["activity_list", "adaptive"]),
                       Set(PluginPageComponent.Kind.allCases.filter { PluginInterfaceContracts.currentMembers.contains(.viewComponent($0.rawValue)) }.map(\.rawValue)))
    }

    /// A Plugin the addition is not offered to, such as one pinned to the
    /// first published members, has none of it.
    func testWithoutTheAdditionAStyleOrColumnIsUnknown() throws {
        let withoutPresentation = Set(CollectionsContract.members + HostOperationsContract.members
                                + HostServiceCatalogue.members)
        let permits: (PluginInterfaceMember) -> Bool = { withoutPresentation.contains($0) }
        XCTAssertThrowsError(try PluginScriptAnswer(parsing: answer("answers/spotify-track.json"), permits: permits)) {
            XCTAssertEqual($0 as? PluginRuntimeError, .protocolViolation("The image component is not offered to this Plugin"))
        }
        let styled = JSONValue.object(["page": .object(["id": .string("p"), "title": .string("P"), "content": .array([
            .object(["kind": .string("text"), "id": .string("t"), "text": .string("x"),
                     "style": .object(["font_size": .number(12)])])])])])
        XCTAssertThrowsError(try PluginScriptAnswer(parsing: styled, permits: permits)) {
            XCTAssertEqual($0 as? PluginRuntimeError, .protocolViolation("The text t has unknown member style"))
        }
        XCTAssertNoThrow(try PluginScriptAnswer(parsing: styled, permits: CollectionsFixtures.permits))
    }

    /// What the page rules refuse, by the message the Plugin's author reads.
    func testThePageRulesNameWhatIsWrong() throws {
        let expected: [String: String] = [
            "answers/image-without-size.json": "gives its width and height",
            "answers/image-file-url.json": "url must be an https address",
            "answers/image-http-url.json": "url must be an https address",
            "answers/image-resource-escapes.json": "resource must be a relative path inside the package",
            "answers/image-source-symbol.json": "has unknown member symbol",
            "answers/style-member-not-for-kind.json": "style has unknown member font_size",
            "answers/style-bad-color.json": "color must be #RRGGBB",
            "answers/style-font-too-large.json": "font_size is not a number from 9 to 40",
            "answers/column-in-column.json": "A column holds no column",
            "answers/progress-unknown-stage.json": "stage names install, which is not one of its stages",
            "answers/progress-cancel-duplicates-button.json": "has two buttons with the ID back",
            "answers/item-symbol-and-icon.json": "has both a symbol and an icon",
            "answers/containers-too-deep.json": "nest at most 3 deep",
            "answers/too-many-images.json": "has more than 8 images"
        ]
        for (file, words) in expected {
            XCTAssertThrowsError(try PluginScriptAnswer(parsing: answer(file), permits: CollectionsFixtures.permits), file) {
                guard case .protocolViolation(let message)? = $0 as? PluginRuntimeError else { return XCTFail("\(file): \($0)") }
                XCTAssertTrue(message.contains(words), "\(file): \(message)")
            }
        }
    }

    /// A colour reads as the Host draws it.
    func testColoursReadAsTheHostDrawsThem() throws {
        let page = try XCTUnwrap(try PluginScriptAnswer(parsing: answer("answers/spotify-track.json"),
                                                        permits: CollectionsFixtures.permits).page)
        guard case .progress(let position)? = page.component("position") else { return XCTFail("No progress") }
        XCTAssertEqual(position.style?.color, .rgb(red: 0x1D / 255.0, green: 0xB9 / 255.0, blue: 0x54 / 255.0, alpha: 1))
        guard case .image(let artwork)? = page.component("artwork") else { return XCTFail("No image") }
        XCTAssertEqual(artwork.style?.background, .named(.secondary))
        XCTAssertEqual(page.imageRequests, [artwork.request])
    }

    /// The types, reference, SDK and catalogue name every kind and style
    /// member.
    func testTheTypesReferenceSDKAndCatalogueNameEveryMember() throws {
        let types = try text("sdk/spinnet.d.ts"), reference = try text("reference/pages.md")
        let sdk = try text("sdk/spinnet.js"), catalogue = try text("catalogue.json")
        for kind in PagePresentation.componentKinds {
            XCTAssertTrue(types.contains("kind: \"\(kind)\""), "spinnet.d.ts has no \(kind)")
            XCTAssertTrue(reference.contains("`\(kind)`"), "pages.md does not name \(kind)")
            XCTAssertTrue(sdk.contains("kind: \"\(kind)\""), "spinnet.js does not build \(kind)")
            XCTAssertTrue(catalogue.contains("\"ui.components.\(kind)\""), "catalogue.json lists no \(kind) builder")
        }
        XCTAssertFalse(catalogue.contains("#81 measures and adds"), "No builder of #81 is still reserved")
        for member in PluginPageStyle.Member.allCases.map(\.rawValue) {
            XCTAssertTrue(types.contains("\(member)?:"), "spinnet.d.ts has no style \(member)")
            XCTAssertTrue(reference.contains("`\(member)`"), "pages.md does not name \(member)")
            XCTAssertTrue(sdk.contains("\(member): o."), "spinnet.js does not build \(member)")
        }
        for state in PluginPageProgress.State.allCases.map(\.rawValue) {
            XCTAssertTrue(types.contains("\"\(state)\""), state)
            XCTAssertTrue(reference.contains("`\(state)`"), state)
        }
        for name in PluginPageColor.Name.allCases.map(\.rawValue) {
            XCTAssertTrue(types.contains("\"\(name)\""), name)
            XCTAssertTrue(reference.contains("`\(name)`"), name)
        }
    }
}
