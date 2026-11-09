import Foundation
import XCTest
import SpinnetCore
import SpinnetPluginTestKit

/// A Plugin author's tests load the package's Plugin Tags the way the Host
/// admits them, and see the same refusal the Host gives invalid ones.
final class PluginTagAdmissionTests: XCTestCase {
    private func package(tags: String?) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("Tagged.spinnetplugin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try Data("""
        {"protocol_version": "1.0", "engines": {"spinnet": "^1.0.0"}, "id": "com.example.tagged",
         "name": "Tagged", "version": "1.0.0"\(tags.map { ", \"tags\": \($0)" } ?? ""),
         "commands": [{"id": "run", "title": "Run", "execution": "javascript", "script": "run.js"}]}
        """.utf8).write(to: root.appendingPathComponent("manifest.json"))
        try Data("null".utf8).write(to: root.appendingPathComponent("run.js"))
        return root
    }

    private func assertRefused(_ tags: String, mentioning words: [String] = [], file: StaticString = #filePath,
                               line: UInt = #line) throws {
        let url = try package(tags: tags)
        XCTAssertThrowsError(try PluginUnderTest(packageAt: url), file: file, line: line) { error in
            let reason = String(describing: error)
            XCTAssertTrue(reason.contains("tags"), reason, file: file, line: line)
            for word in words { XCTAssertTrue(reason.contains(word), "\(word): \(reason)", file: file, line: line) }
        }
    }

    func testDeclaredTagsLoadInOrderAsTheHostAdmitsThem() throws {
        let plugin = try PluginUnderTest(packageAt: package(tags: #"["window", "apps"]"#))
        XCTAssertEqual(plugin.manifest.tags, ["window", "apps"])
        XCTAssertEqual(plugin.manifest.vocabularyTags, [.window, .apps])
    }

    func testAPluginWithoutTagsHasNone() throws {
        let plugin = try PluginUnderTest(packageAt: package(tags: nil))
        XCTAssertEqual(plugin.manifest.tags, [])
        XCTAssertEqual(plugin.manifest.vocabularyTags, [])
    }

    /// A Plugin written for a newer vocabulary still installs: the unknown
    /// tag is kept but is no Library filter.
    func testAnUnknownTagIsAdmittedAndKeptButIsNotInTheVocabulary() throws {
        let plugin = try PluginUnderTest(packageAt: package(tags: #"["media", "spatial-audio"]"#))
        XCTAssertEqual(plugin.manifest.tags, ["media", "spatial-audio"])
        XCTAssertEqual(plugin.manifest.vocabularyTags, [.media])
    }

    func testDuplicateTagsRefuseThePackage() throws {
        try assertRefused(#"["text", "text"]"#, mentioning: ["more than once"])
    }

    func testTooManyTagsRefuseThePackage() throws {
        let most = PluginTag.maximumDeclaredTags
        XCTAssertNoThrow(try PluginUnderTest(packageAt: package(
            tags: "[" + PluginTag.allCases.prefix(most).map { "\"\($0.rawValue)\"" }.joined(separator: ", ") + "]")))
        try assertRefused("[" + PluginTag.allCases.prefix(most + 1).map { "\"\($0.rawValue)\"" }
            .joined(separator: ", ") + "]", mentioning: ["at most \(most)"])
    }

    func testMalformedTagsRefuseThePackage() throws {
        for tags in [#""window""#, "null", "[1]", #"["Window"]"#, #"[""]"#, #"["-window"]"#, #"["a b"]"#,
                     "[\"" + String(repeating: "a", count: PluginTag.maximumLength + 1) + "\"]"] {
            try assertRefused(tags)
        }
    }
}
