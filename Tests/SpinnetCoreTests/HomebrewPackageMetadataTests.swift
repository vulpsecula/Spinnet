import XCTest
import SpinnetCore
import SpinnetTestSupport
@testable import SpinnetReviewedTools

final class HomebrewPackageMetadataTests: XCTestCase {
    func testInstalledOutdatedAndInfoReturnOnlyTheFirstInstalledAppsBundleIdentifier() throws {
        let prefix = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: prefix) }
        let applications = prefix.appendingPathComponent("Applications")
        let userApplications = prefix.appendingPathComponent("user/Applications")
        let renamed = userApplications.appendingPathComponent("Renamed Browser.app")
        try writeApp(renamed, identifier: "org.example.Browser-beta")
        try writeApp(applications.appendingPathComponent("Renamed Browser.app"), identifier: "org.example.other-copy")
        try writeApp(userApplications.appendingPathComponent("Second.app"), identifier: "org.example.second")
        let casks: [[String: Any]] = [[
            "token": "example", "full_token": "owner/tap/example", "installed": "1",
            "bundle_id": "org.example.not-from-brew",
            "artifacts": [
                ["pkg": ["Installer.pkg"]],
                ["app": ["Folder/Original.app", ["target": "Renamed Browser.app"]], "target": renamed.path],
                ["app": ["Second.app"]]
            ]
        ]]
        let inventory = try JSONSerialization.data(withJSONObject: ["casks": casks])
        for token in ["example", "stale"] {
            let history = prefix.appendingPathComponent("Caskroom/\(token)/.metadata")
            try FileManager.default.createDirectory(at: history.appendingPathComponent("1/20261124000000.000"),
                                                    withIntermediateDirectories: true)
            let receipt = try JSONSerialization.data(withJSONObject: [
                "source": ["tap": "owner/tap", "version": "1"],
                "uninstall_artifacts": try XCTUnwrap(casks[0]["artifacts"])
            ])
            try receipt.write(to: history.appendingPathComponent("INSTALL_RECEIPT.json"))
        }
        var commands: [[String]] = []
        let profile = HomebrewReadProfile(executable: { prefix.appendingPathComponent("bin/brew") }, execute: { _, args, _, _ in
            commands.append(args)
            switch args {
            case ["info", "--json=v2", "--installed", "--cask"], ["info", "--json=v2", "--cask", "--", "owner/tap/example"]:
                return HomebrewReadOutput(status: 0, stdout: inventory)
            case ["outdated", "--json=v2"]:
                return HomebrewReadOutput(status: 1, stdout: Data("""
                    {"formulae":[],"casks":[
                      {"name":"owner/tap/example","installed_versions":["1"],"current_version":"2"},
                      {"name":"owner/tap/stale","installed_versions":["2"],"current_version":"3"}
                    ]}
                    """.utf8))
            case ["search", "--cask", "--", "example"]:
                return HomebrewReadOutput(status: 0, stdout: Data("owner/tap/example\n".utf8))
            default:
                XCTFail("Unexpected arguments \(args)")
                return HomebrewReadOutput(status: 2, stdout: Data())
            }
        }, applicationDirectories: [applications, userApplications])
        let schema = try JSONSchemaSubsetValidator(definition: "tools.read.result", inSchemaAt:
            TestRepository.root.appendingPathComponent("PluginAPI/schemas/reviewed-tools.schema.json"))
        for operation in ["installed", "outdated", "info", "search"] {
            var request: [String: JSONValue] = ["tool": .string("homebrew"), "operation": .string(operation), "kind": .string("cask")]
            if operation == "outdated" { request.removeValue(forKey: "kind") }
            if operation == "info" { request["names"] = .array([.string("owner/tap/example")]) }
            if operation == "search" { request["query"] = .string("example") }
            commands.removeAll()
            let result = try profile.read(.object(request), owner: PluginID("bundle-metadata"))
            XCTAssertEqual(schema.errors(for: result), [], operation)
            if operation == "outdated" {
                XCTAssertEqual(commands, [["outdated", "--json=v2"]])
                XCTAssertEqual(result.value(atPointer: "/packages/1/name"), .string("owner/tap/stale"))
                XCTAssertNil(result.value(atPointer: "/packages/1/bundle_id"))
            }
            if operation == "search" {
                XCTAssertEqual(result.value(atPointer: "/packages/0"), .object(["kind": .string("cask"), "name": .string("owner/tap/example")]))
            } else {
                XCTAssertEqual(result.value(atPointer: "/packages/0/bundle_id"), .string("org.example.Browser-beta"), operation)
                let encoded = try JSONEncoder().encode(result)
                XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(".app"), operation)
            }
        }
    }

    func testSchemaRefusesBundleMetadataOnFormulaeAndSearchResults() throws {
        let schema = try JSONSchemaSubsetValidator(definition: "tools.read.result", inSchemaAt:
            TestRepository.root.appendingPathComponent("PluginAPI/schemas/reviewed-tools.schema.json"))
        for (operation, kind) in [("installed", "formula"), ("search", "cask")] {
            let result: JSONValue = .object([
                "tool": .string("homebrew"), "operation": .string(operation),
                "packages": .array([.object([
                    "kind": .string(kind), "name": .string("example"),
                    "installed_version": .string("1"), "bundle_id": .string("org.example.app")
                ])])
            ])
            XCTAssertFalse(schema.errors(for: result).isEmpty)
        }
    }

    func testAppBundleIdentifierOmitsUnsafePathsAndInvalidPlists() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let applications = root.appendingPathComponent("Applications")
        let outside = root.appendingPathComponent("Outside.app")
        try writeApp(outside, identifier: "org.example.outside")
        try writeApp(applications.appendingPathComponent("Second.app"), identifier: "org.example.second")
        let symlink = applications.appendingPathComponent("Symlink.app")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
        let linkedPlist = applications.appendingPathComponent("Linked Plist.app/Contents")
        try FileManager.default.createDirectory(at: linkedPlist, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedPlist.appendingPathComponent("Info.plist"),
                                                  withDestinationURL: outside.appendingPathComponent("Contents/Info.plist"))
        try writeApp(applications.appendingPathComponent("Invalid.app"), identifier: "not-a-bundle-id")
        let large = applications.appendingPathComponent("Large.app")
        try writeApp(large, identifier: "org.example.large")
        try Data(repeating: 0, count: 256 * 1024 + 1).write(to: large.appendingPathComponent("Contents/Info.plist"))
        let first: [[String: Any]] = [
            ["app": ["Original.app", ["target": "../Outside.app"]]],
            ["app": ["Original.app"], "target": outside.path],
            ["app": ["Symlink.app"]],
            ["app": ["Linked Plist.app"]],
            ["app": ["Invalid.app"]],
            ["app": ["Large.app"]],
            ["app": ["Missing.app"]]
        ]
        for artifact in first {
            XCTAssertNil(HomebrewCaskApp.bundleIdentifier(in: [
                "installed": "1", "artifacts": [artifact, ["app": ["Second.app"]]]
            ], applicationDirectories: [applications]), "\(artifact)")
        }
        XCTAssertNil(HomebrewCaskApp.bundleIdentifier(in: [
            "artifacts": [["app": ["Second.app"]]]
        ], applicationDirectories: [applications]))
        XCTAssertEqual(HomebrewCaskApp.bundleIdentifier(in: [
            "installed": ["1"], "artifacts": [["app": ["Folder/Original.app", ["target": "Second.app"]]]]
        ], applicationDirectories: [applications]), "org.example.second")
    }

    private func writeApp(_ app: URL, identifier: String) throws {
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier], format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }

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
