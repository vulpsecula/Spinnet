import XCTest
import SpinnetCore
@testable import SpinnetReviewedTools

final class HomebrewPackageMetadataTests: XCTestCase {
    func testInstalledFormulaDirectoryComesFromDiscoveredPrefixNotReturnedArbitraryPaths() throws {
        let prefix = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let installed = prefix.appendingPathComponent("Cellar/example/1.0")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: prefix) }
        let profile = HomebrewReadProfile(executable: { prefix.appendingPathComponent("bin/brew") }, execute: { _, args, _, _ in
            XCTAssertEqual(args, ["info", "--json=v2", "--formula", "--", "owner/tap/example"])
            return HomebrewReadOutput(status: 0, stdout: Data(#"{"formulae":[{"name":"example","full_name":"owner/tap/example","versions":{"stable":"1.0"},"installed":[{"version":"1.0"}],"linked_keg":"1.0","keg_only":false,"prefix":"/private/arbitrary","installed_path":"/private/arbitrary"}],"casks":[]}"#.utf8))
        })
        let result = try profile.read(.object(["tool": .string("homebrew"), "operation": .string("info"), "kind": .string("formula"), "names": .array([.string("owner/tap/example")])]), owner: PluginID("metadata"))
        XCTAssertEqual(result.value(atPointer: "/packages/0/installed_path"), .string(installed.path))
        XCTAssertEqual(result.value(atPointer: "/packages/0/linked"), .bool(true))
        XCTAssertEqual(result.value(atPointer: "/packages/0/linkable"), .bool(true))
        XCTAssertNil(result.value(atPointer: "/not_found"))
    }

    func testInstalledCaskExposesLanguagesSavedSelectionAndOwnedSymlinkState() throws {
        let prefix = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = prefix.appendingPathComponent("Caskroom/example/2.0,42")
        let metadata = prefix.appendingPathComponent("Caskroom/example/.metadata")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try Data(#"{"explicit":{"languages":["zh-Hans-CN"]},"default":{"languages":["en-US"]}}"#.utf8).write(to: metadata.appendingPathComponent("config.json"))
        try Data().write(to: directory.appendingPathComponent("example"))
        let link = prefix.appendingPathComponent("bin/example")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory.appendingPathComponent("example"))
        defer { try? FileManager.default.removeItem(at: prefix) }
        let raw: [String: Any] = ["casks": [["token": "example", "installed": "2.0,42", "languages": ["en", "zh-Hans", "../../bad"], "artifacts": [["binary": ["example"], "target": link.path]], "url": "https://example.org/example.dmg"]]]
        let data = try JSONSerialization.data(withJSONObject: raw)
        let profile = HomebrewReadProfile(executable: { prefix.appendingPathComponent("bin/brew") }, execute: { _, _, _, _ in HomebrewReadOutput(status: 0, stdout: data) })
        let input: JSONValue = .object(["tool": .string("homebrew"), "operation": .string("info"), "kind": .string("cask"), "names": .array([.string("example")])])
        let result = try profile.read(input, owner: PluginID("metadata"))
        XCTAssertEqual(result.value(atPointer: "/packages/0/installed_path"), .string(directory.path))
        XCTAssertEqual(result.value(atPointer: "/packages/0/languages"), .array([.string("en"), .string("zh-Hans")]))
        XCTAssertEqual(result.value(atPointer: "/packages/0/selected_language"), .string("zh-Hans"))
        XCTAssertEqual(result.value(atPointer: "/packages/0/download_url"), .string("https://example.org/example.dmg"))
        XCTAssertEqual(result.value(atPointer: "/packages/0/linkable"), .bool(true))
        XCTAssertEqual(result.value(atPointer: "/packages/0/linked"), .bool(true))
        try FileManager.default.removeItem(at: link)
        let unlinked = try profile.read(input, owner: PluginID("metadata"))
        XCTAssertEqual(unlinked.value(atPointer: "/packages/0/linked"), .bool(false))
    }

    func testApplicationCaskIsNotLinkableAndEscapedDirectoryIsNeverPublished() throws {
        let prefix = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let external = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("Caskroom/example"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: prefix.appendingPathComponent("Caskroom/example/1.0"), withDestinationURL: external)
        defer { try? FileManager.default.removeItem(at: prefix); try? FileManager.default.removeItem(at: external) }
        let data = Data(#"{"casks":[{"token":"example","installed":"1.0","artifacts":[{"app":["Example.app"]}],"languages":["en"]}]}"#.utf8)
        let profile = HomebrewReadProfile(executable: { prefix.appendingPathComponent("bin/brew") }, execute: { _, _, _, _ in HomebrewReadOutput(status: 0, stdout: data) })
        let result = try profile.read(.object(["tool": .string("homebrew"), "operation": .string("info"), "kind": .string("cask"), "names": .array([.string("example")])]), owner: PluginID("metadata"))
        XCTAssertNil(result.value(atPointer: "/packages/0/installed_path"))
        XCTAssertEqual(result.value(atPointer: "/packages/0/linkable"), .bool(false))
        XCTAssertNil(result.value(atPointer: "/packages/0/selected_language"))
    }
}
