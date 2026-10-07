import Foundation
import XCTest
@testable import SpinnetCore
import SpinnetPluginTestKit

/// The App in front as Plugin API Level 2 publishes it (#83): the
/// `fixtures/apps/` results and inputs against `namespaces.schema.json` and
/// the Host's reading of `apps.quit`'s input, App Targets' lifetime and
/// bound, and which Apps the Host protects.
final class AppTargetsContractTests: XCTestCase {
    private static let pluginAPI = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("PluginAPI")
    private static let fixtures = pluginAPI.appendingPathComponent("fixtures/apps")

    private struct Fixture: Decodable {
        let file: String
        let definition: String
        let valid: Bool
        let note: String
    }

    private func fixtures() throws -> [Fixture] {
        struct Index: Decodable { let fixtures: [Fixture] }
        return try JSONDecoder().decode(Index.self, from: Data(contentsOf: Self.fixtures.appendingPathComponent("index.json")))
            .fixtures
    }

    private func value(_ file: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: Self.fixtures.appendingPathComponent(file)))
    }

    func testThePublishedFixturesFollowTheSchemaAndTheHostReadsInputsAlike() throws {
        let schema = Self.pluginAPI.appendingPathComponent("schemas/namespaces.schema.json")
        for fixture in try fixtures() {
            let validator = try JSONSchemaSubsetValidator(definition: fixture.definition, inSchemaAt: schema)
            let errors = validator.errors(for: try value(fixture.file))
            XCTAssertEqual(errors.isEmpty, fixture.valid, "\(fixture.file): \(fixture.note) \(errors)")
            if fixture.definition == "apps.quit.input" {
                XCTAssertEqual((try? AppQuitRequest(input: value(fixture.file))) != nil, fixture.valid, fixture.file)
            }
        }
        XCTAssertTrue(try fixtures().contains { $0.definition == "apps.frontmost.result" })
    }

    func testTheReadmeLinksTheFixturesAndReference() throws {
        let readme = try String(contentsOf: Self.pluginAPI.appendingPathComponent("README.md"), encoding: .utf8)
        XCTAssertTrue(readme.contains("(fixtures/apps/index.json)"))
        XCTAssertTrue(readme.contains("(reference/apps.md)"))
        let reference = try String(contentsOf: Self.pluginAPI.appendingPathComponent("reference/apps.md"), encoding: .utf8)
        XCTAssertTrue(reference.contains("| App Targets per Plugin | \(AppTargets.maximumPerPlugin) |"))
        XCTAssertTrue(reference.contains("| Host Confirmation unanswered before `expired` | \(Int(HostConfirmation.expiry)) s |"))
        for bundle in AppExitPolicy.systemBundleIdentifiers.union(AppExitPolicy.forceQuitProtectedBundleIdentifiers)
        where bundle != "com.apple.finder" {
            XCTAssertTrue(reference.contains("`\(bundle)`"), "reference/apps.md does not list \(bundle)")
        }
    }

    // MARK: App Targets

    private func app(_ pid: Int32, _ bundle: String = "com.example.a", launched: TimeInterval = 1) -> InsertionTargetApp {
        InsertionTargetApp(processIdentifier: pid, bundleIdentifier: bundle,
                           launchDate: Date(timeIntervalSince1970: launched), name: "A")
    }

    func testATargetNamesOneAppForOnePluginOnly() {
        let targets = AppTargets()
        let one = PluginID("one"), two = PluginID("two")
        let target = targets.target(naming: app(1), for: one)
        XCTAssertTrue(AppTargets.isWellFormed(target))
        XCTAssertFalse(target.contains("1") && target == "app_1", "Never the process ID")
        XCTAssertEqual(targets.target(naming: app(1), for: one), target, "The same App gives the same target")
        XCTAssertEqual(targets.app(for: target, of: one), app(1))
        XCTAssertNil(targets.app(for: target, of: two), "Another Plugin's target names nothing")
        XCTAssertNotEqual(targets.target(naming: app(1, launched: 2), for: one), target,
                          "A relaunch reusing the process ID is another App")

        targets.forget(app(1))
        XCTAssertNil(targets.app(for: target, of: one))
        let again = targets.target(naming: app(5), for: one)
        targets.forget(one)
        XCTAssertNil(targets.app(for: again, of: one))
    }

    func testAPluginHoldsAtMostSixteenForgettingTheLeastRecent() {
        let targets = AppTargets()
        let plugin = PluginID("one")
        let first = targets.target(naming: app(1), for: plugin)
        let second = targets.target(naming: app(2), for: plugin)
        for pid in 3...Int32(AppTargets.maximumPerPlugin) { _ = targets.target(naming: app(pid), for: plugin) }
        _ = targets.target(naming: app(1), for: plugin)  // read again: now the most recent
        _ = targets.target(naming: app(99), for: plugin)
        XCTAssertEqual(targets.count(for: plugin), AppTargets.maximumPerPlugin)
        XCTAssertEqual(targets.app(for: first, of: plugin), app(1))
        XCTAssertNil(targets.app(for: second, of: plugin))
    }

    // MARK: Protection

    func testTheHostProtectsItselfMacOSAndAgentsAndNeverForceQuitsFinder() {
        let own: Int32 = 7
        func exits(_ bundle: String?, pid: Int32 = 1, regular: Bool = true) -> [AppExit] {
            AppExitPolicy.exits(for: RunningAppFacts(app: InsertionTargetApp(processIdentifier: pid, bundleIdentifier: bundle,
                                                                             launchDate: nil, name: "X"),
                                                     isRegular: regular), ownProcessIdentifier: own)
        }
        XCTAssertEqual(exits("com.apple.TextEdit"), [.quit, .forceQuit])
        XCTAssertEqual(exits(nil), [.quit, .forceQuit])
        XCTAssertEqual(exits("com.apple.finder"), [.quit])
        XCTAssertEqual(exits("com.apple.dock"), [])
        XCTAssertEqual(exits("com.apple.loginwindow"), [])
        XCTAssertEqual(exits("com.example.agent", regular: false), [])
        XCTAssertEqual(exits("com.vulpsecula.Spinnet", pid: own), [])
    }

    // MARK: Capabilities

    func testTheCapabilitiesAreLevelTwosAndDisclosedSeparately() {
        XCTAssertEqual(PluginCapability.readFrontmostApp.apiLevel, 2)
        XCTAssertEqual(PluginCapability.quitFrontmostApp.apiLevel, 2)
        XCTAssertEqual(PluginCapability.readFrontmostApp.consentGroup, .reads)
        XCTAssertEqual(PluginCapability.quitFrontmostApp.consentGroup, .controls)
        XCTAssertEqual(HostServiceCatalogue.operation("apps.frontmost")?.capabilities, [.readFrontmostApp])
        XCTAssertEqual(HostServiceCatalogue.operation("apps.quit")?.capabilities, [.quitFrontmostApp])
        XCTAssertFalse(HostServiceCatalogue.operation("apps.quit")!.isOffered(at: .call), "No synchronous kill")
    }
}
