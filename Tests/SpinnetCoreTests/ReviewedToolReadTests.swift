import XCTest
@testable import SpinnetCore

final class ReviewedToolReadTests: XCTestCase {
    func testQualifiedInstalledCaskSelectionCannotBorrowAnotherTapsSameTokenHistory() throws {
        let prefix = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: prefix) }
        let metadata = prefix.appendingPathComponent("Caskroom/example/.metadata")
        let definition = metadata.appendingPathComponent("1/20261011000000/Casks/example.json")
        try FileManager.default.createDirectory(at: definition.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: definition)
        try Data("{\"source\":{\"version\":\"1\",\"tap\":\"other/tap\"},\"uninstall_artifacts\":[{\"uninstall\":[{\"pkgutil\":\"org.example.pkg\"}]}]}".utf8).write(to: metadata.appendingPathComponent("INSTALL_RECEIPT.json"))
        XCTAssertNoThrow(try HomebrewInstalledUninstall.read(name: "other/tap/example", prefix: prefix.path))
        XCTAssertThrowsError(try HomebrewInstalledUninstall.read(name: "official/tap/example", prefix: prefix.path)) {
            XCTAssertEqual($0 as? PluginHostServiceError, .tool(.sourceNotAllowed))
        }
    }
    func testCaskInfoDetectsPrivilegedInstalledPredecessorEvenWhenCurrentCatalogDropsItsUninstall() throws {
        let prefix = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: prefix) }
        let metadata = prefix.appendingPathComponent("Caskroom/example/.metadata")
        let definition = metadata.appendingPathComponent("1/20261011000000/Casks/example.json")
        try FileManager.default.createDirectory(at: definition.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: definition)
        let tab = "{\"source\":{\"version\":\"1\",\"tap\":\"homebrew/cask\"},\"uninstall_flight_blocks\":false,\"uninstall_artifacts\":[{\"uninstall\":[{\"pkgutil\":\"org.example.pkg\",\"quit\":\"org.example.app\"}]}]}"
        try Data(tab.utf8).write(to: metadata.appendingPathComponent("INSTALL_RECEIPT.json"))
        let profile = HomebrewReadProfile(executable: { prefix.appendingPathComponent("bin/brew") }) { _, _, _, _ in
            HomebrewReadOutput(status: 0, stdout: Data("{\"casks\":[{\"token\":\"example\",\"version\":\"2\",\"installed\":[\"1\"],\"artifacts\":[{\"app\":[\"Example.app\"]}]}]}".utf8))
        }
        let value = try profile.read(.object(["tool": .string("homebrew"), "operation": .string("info"), "kind": .string("cask"), "names": .array([.string("example")])]), owner: PluginID("reader"))
        XCTAssertEqual(value.value(atPointer: "/packages/0/uninstall_needs_privileges"), .bool(true))
        XCTAssertEqual(value.value(atPointer: "/packages/0/quits_app"), .bool(true))
    }
    func testInstalledProjectionKeepsTrustedTapAndRemovesPrivateFields() throws {
        let profile = HomebrewReadProfile(executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }) { _, arguments, environment, _ in
            XCTAssertEqual(arguments, ["info", "--json=v2", "--installed"])
            XCTAssertEqual(environment["HOMEBREW_NO_AUTO_UPDATE"], "1")
            XCTAssertNil(environment["SSH_AUTH_SOCK"])
            return HomebrewReadOutput(status: 0, stdout: Data(#"{"formulae":[{"name":"terraform","full_name":"hashicorp/tap/terraform","tap":"hashicorp/tap","desc":"Infrastructure\u0001","versions":{"stable":"1.9"},"installed":[{"version":"1.8"}],"outdated":true,"caveats":"secret /Users/me"}],"casks":[]}"#.utf8))
        }
        let result = try profile.read(.object(["tool": .string("homebrew"), "operation": .string("installed")]), owner: PluginID("probe"))
        XCTAssertEqual(result, .object(["tool": .string("homebrew"), "operation": .string("installed"), "packages": .array([.object(["kind": .string("formula"), "name": .string("hashicorp/tap/terraform"), "tap": .string("hashicorp/tap"), "description": .string("Infrastructure"), "version": .string("1.9"), "installed_version": .string("1.8"), "outdated": .bool(true)])])]))
    }
    func testOutdatedCasksExposeCurrentInstalledVersionsAndOutdatedFlag() throws {
        let profile = HomebrewReadProfile(executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }) { _, arguments, _, _ in
            XCTAssertEqual(arguments, ["outdated", "--json=v2", "--cask", "--greedy"])
            return HomebrewReadOutput(status: 0, stdout: Data(#"{"formulae":[],"casks":[{"name":"surge","installed_versions":["6.6"],"current_version":"6.9","pinned":true}]}"#.utf8))
        }
        let result = try profile.read(.object(["tool": .string("homebrew"), "operation": .string("outdated"), "kind": .string("cask"), "greedy": .bool(true)]), owner: PluginID("probe"))
        XCTAssertEqual(result, .object(["tool": .string("homebrew"), "operation": .string("outdated"), "packages": .array([.object(["kind": .string("cask"), "name": .string("surge"), "version": .string("6.9"), "installed_version": .string("6.6"), "outdated": .bool(true), "pinned": .bool(true)])])]))
    }

    func testUnsupportedInputsCannotLaunchTheTool() throws {
        var launched = false
        let profile = HomebrewReadProfile(executable: { launched = true; return URL(fileURLWithPath: "/opt/homebrew/bin/brew") }) { _, _, _, _ in
            launched = true; return HomebrewReadOutput(status: 0, stdout: Data())
        }
        for input in [
            JSONValue.object(["tool": .string("homebrew"), "operation": .string("install")]),
            .object(["tool": .string("homebrew"), "operation": .string("info"), "kind": .string("formula"), "names": .array([.string("/opt/homebrew/terraform")])]),
            .object(["tool": .string("homebrew"), "operation": .string("search"), "query": .string("/regex/")]),
            .object(["tool": .string("homebrew"), "operation": .string("installed"), "argv": .array([.string("update")])])
        ] { XCTAssertThrowsError(try profile.read(input, owner: PluginID("probe"))) }
        XCTAssertFalse(launched)
    }

    func testExactInfoReportsMissingNamesWithoutLeakingStderr() throws {
        var call = 0
        let profile = HomebrewReadProfile(executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }) { _, arguments, _, _ in
            call += 1
            if call == 1 {
                XCTAssertEqual(arguments, ["info", "--json=v2", "--formula", "--", "wget", "unknown"])
                return HomebrewReadOutput(status: 1, stdout: Data(), stderr: Data("Error: No available formula with the name \"unknown\".\n".utf8))
            }
            XCTAssertEqual(arguments, ["info", "--json=v2", "--formula", "--", "wget"])
            return HomebrewReadOutput(status: 0, stdout: Data(#"{"formulae":[{"name":"wget","tap":"homebrew/core","versions":{"stable":"1.25"}}],"casks":[]}"#.utf8), stderr: Data("secret error /Users/me".utf8))
        }
        let result = try profile.read(.object(["tool": .string("homebrew"), "operation": .string("info"), "kind": .string("formula"), "names": .array([.string("wget"), .string("unknown")])]), owner: PluginID("probe"))
        XCTAssertEqual(result, .object(["tool": .string("homebrew"), "operation": .string("info"), "not_found": .array([.string("unknown")]), "packages": .array([.object(["kind": .string("formula"), "name": .string("wget"), "tap": .string("homebrew/core"), "official": .bool(true), "version": .string("1.25")])])]))
    }

    func testReadScopeRefusesUndeclaredKindsAndOperations() throws {
        let scope = PluginCapabilityScope(capability: .readReviewedTools, commandIDs: [CommandID("read")], reviewedTools: [.init(tool: "homebrew", operations: ["installed"], kinds: ["formula"])])
        XCTAssertNoThrow(try HomebrewReadInput(.object(["tool": .string("homebrew"), "operation": .string("installed"), "kind": .string("formula")])).authorize(in: scope))
        XCTAssertThrowsError(try HomebrewReadInput(.object(["tool": .string("homebrew"), "operation": .string("installed")])).authorize(in: scope))
        XCTAssertThrowsError(try HomebrewReadInput(.object(["tool": .string("homebrew"), "operation": .string("search"), "kind": .string("formula"), "query": .string("wget")])).authorize(in: scope))
    }

    func testReadOutputOverflowIsTypedAndNeverReturnsRawData() throws {
        let profile = HomebrewReadProfile(executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }) { _, _, _, _ in
            HomebrewReadOutput(status: 0, stdout: Data(repeating: 65, count: ReviewedToolReads.stdoutBytes + 1))
        }
        XCTAssertThrowsError(try profile.read(.object(["tool": .string("homebrew"), "operation": .string("installed")]), owner: PluginID("probe"))) { XCTAssertEqual($0 as? PluginHostServiceError, .tool(.outputTooLarge)) }
    }

    func testProcessGroupDeadlineStopsChildAfterLeaderExited() throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        XCTAssertThrowsError(try HomebrewReadProfile.execute(URL(fileURLWithPath: "/bin/sh"), ["-c", "(sleep 0.5; echo survivor > \"$1\") & exit 0", "read-fixture", marker.path], HomebrewReadProfile.environment, Date().addingTimeInterval(0.15))) { XCTAssertEqual($0 as? PluginHostServiceError, .tool(.timedOut)) }
        Thread.sleep(forTimeInterval: 0.55)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testSourceCancellationStopsAChildAfterItsLeaderExited() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = directory.appendingPathComponent("started"), survivor = directory.appendingPathComponent("survivor")
        let cancellation = HostFetchedSections.Cancellation()
        let finished = expectation(description: "cancelled process group was reaped")
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            do {
                _ = try HomebrewReadProfile.executeCancellable(URL(fileURLWithPath: "/bin/sh"),
                    ["-c", "(sleep 0.5; echo survivor > \"$2\") & echo started > \"$1\"; exit 0", "source-fixture", started.path, survivor.path],
                    HomebrewReadProfile.environment, Date().addingTimeInterval(15), cancellation)
                XCTFail("The cancelled read returned an answer")
            } catch { XCTAssertEqual(error as? PluginHostServiceError, .unavailable("The reviewed read was cancelled")) }
        }
        let deadline = Date().addingTimeInterval(1)
        while !FileManager.default.fileExists(atPath: started.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.002) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path))
        cancellation.cancel()
        wait(for: [finished], timeout: 1)
        Thread.sleep(forTimeInterval: 0.55)
        XCTAssertFalse(FileManager.default.fileExists(atPath: survivor.path), "Cancellation must stop children, not just discard the read")
    }

    func testPublishedReadProtocolFixturesMatchTheirSchemasAndHostInputRules() throws {
        struct Index: Decodable { let fixtures: [Fixture] }
        struct Fixture: Decodable { let file: String; let definition: String; let valid: Bool }
        let api = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("PluginAPI")
        let fixtures = api.appendingPathComponent("fixtures/reviewed-tools")
        let index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: fixtures.appendingPathComponent("index.json")))
        for fixture in index.fixtures {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: fixtures.appendingPathComponent(fixture.file)))
            let validator = try JSONSchemaSubsetValidator(definition: fixture.definition, inSchemaAt: api.appendingPathComponent("schemas/reviewed-tools.schema.json"))
            XCTAssertEqual(validator.errors(for: value).isEmpty, fixture.valid, fixture.file)
            if fixture.definition == "tools.read.input" { XCTAssertEqual((try? HomebrewReadInput(value)) != nil, fixture.valid, fixture.file) }
        }
    }
}


extension ReviewedToolReadTests {
    func testCaskArrayUninstallDirectivesDiscloseAppQuitAndPrivilegedUninstall() throws {
        let profile = HomebrewReadProfile(executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }) { _, _, _, _ in
            HomebrewReadOutput(status: 0, stdout: Data(#"{"casks":[{"token":"example","version":"2","artifacts":[{"app":["Example.app"]},{"uninstall":[{"quit":"org.example.app","launchctl":"org.example.daemon"}]}]}]}"#.utf8))
        }
        let result = try profile.read(.object(["tool": .string("homebrew"), "operation": .string("info"), "kind": .string("cask"), "names": .array([.string("example")])]), owner: PluginID("read"))
        XCTAssertEqual(result.value(atPointer: "/packages/0/quits_app"), .bool(true))
        XCTAssertEqual(result.value(atPointer: "/packages/0/uninstall_needs_privileges"), .bool(true))
        XCTAssertNil(result.value(atPointer: "/packages/0/needs_privileges"), "Installing an App artifact need not elevate its future uninstall")
    }
}
