import Foundation
import SpinnetTestSupport
import XCTest
@testable import SpinnetCore

/// The Plugin Tag vocabulary the Host knows is the one PluginAPI publishes,
/// with the same English titles, and declared tags survive a round trip.
final class PluginTagVocabularyTests: XCTestCase {
    private struct Published: Decodable {
        struct Tag: Decodable { let id: String; let title: [String: String] }
        let tags: [Tag]
    }

    static func published() throws -> [(id: String, english: String, chinese: String)] {
        let url = TestRepository.root.appendingPathComponent("PluginAPI/plugin-tags.json")
        return try JSONDecoder().decode(Published.self, from: Data(contentsOf: url)).tags.map {
            ($0.id, $0.title["en"] ?? "", $0.title["zh-Hans"] ?? "")
        }
    }

    func testTheHostKnowsExactlyThePublishedVocabularyInItsOrder() throws {
        let published = try Self.published()
        XCTAssertEqual(published.map(\.id), PluginTag.allCases.map(\.rawValue))
        XCTAssertEqual(published.map(\.english), PluginTag.allCases.map(\.title))
        XCTAssertTrue(published.allSatisfy { !$0.chinese.isEmpty && PluginTag.isWellFormed($0.id) })
        XCTAssertEqual(published.map(\.id).prefix(3), ["window", "media", "apps"])
    }

    func testTagBoundsMatchThePublishedPage() {
        XCTAssertPublished("A Plugin declares at most 3 tags, each at most 32 characters", in: "reference/manifest.md")
        XCTAssertEqual(PluginTag.maximumDeclaredTags, 3)
        XCTAssertEqual(PluginTag.maximumLength, 32)
    }

    func testDeclaredTagsRoundTripAndAnAbsentListIsNotWritten() throws {
        let manifest = try PluginManifestLoader.decode(Data("""
        {"protocol_version": "1.0", "engines": {"spinnet": "^1.0.0"}, "id": "com.example.tagged",
         "name": "Tagged", "version": "1.0.0", "tags": ["text", "later-tag"],
         "commands": [{"id": "run", "title": "Run", "execution": "javascript", "script": "run.js"}]}
        """.utf8))
        let encoded = try JSONEncoder().encode(manifest)
        XCTAssertEqual(try PluginManifestLoader.decode(encoded).tags, ["text", "later-tag"])

        let plain = try PluginManifest(id: .init("com.example.plain"), name: "Plain", version: "1.0.0", commands: [
            .init(id: .init("run"), title: "Run", execution: .javascript, script: "run.js")
        ])
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any]
        XCTAssertNil(object?["tags"])
    }

    func testAManifestBuiltInCodeIsHeldToTheSameBounds() {
        XCTAssertThrowsError(try PluginManifest(id: .init("com.example.many"), name: "Many", version: "1.0.0",
                                                tags: ["text", "text"], commands: [
            .init(id: .init("run"), title: "Run", execution: .javascript, script: "run.js")
        ]))
    }
}
