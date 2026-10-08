import Foundation
import XCTest
@testable import SpinnetCore
import SpinnetPluginTestKit

/// The App in front as Plugin API Level 2 publishes it (#83): the
/// `fixtures/apps/` results and inputs against `namespaces.schema.json` and
/// the Host's reading of `apps.quit`'s and `apps.close`'s input, App
/// Targets' lifetime and bound, and which exits the Host offers: Close and
/// Quit only as the App's own menu does, Force Quit for any regular App but
/// Spinnet, with no rule naming an App.
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
            for id in CurrentAppAddition.exitIDs where fixture.definition == "\(id).input" {
                XCTAssertEqual((try? AppExitRequest(perform: id, input: value(fixture.file))) != nil, fixture.valid,
                               fixture.file)
            }
        }
        let definitions = Set(try fixtures().map(\.definition))
        XCTAssertTrue(definitions.isSuperset(of: ["apps.frontmost.result", "apps.quit.input", "apps.close.input"]))
    }

    func testTheReadmeLinksTheFixturesAndReference() throws {
        let readme = try String(contentsOf: Self.pluginAPI.appendingPathComponent("README.md"), encoding: .utf8)
        XCTAssertTrue(readme.contains("(fixtures/apps/index.json)"))
        XCTAssertTrue(readme.contains("(reference/apps.md)"))
        let reference = try String(contentsOf: Self.pluginAPI.appendingPathComponent("reference/apps.md"), encoding: .utf8)
        XCTAssertTrue(reference.contains("| App Targets per Plugin | \(AppTargets.maximumPerPlugin) |"))
        XCTAssertTrue(reference.contains("| Host Confirmation unanswered before `expired` | \(Int(HostConfirmation.expiry)) s |"))
        XCTAssertFalse(reference.contains("com.apple.finder"), "No rule names an App")
    }

    // MARK: App Targets

    private func app(_ pid: Int32, _ bundle: String = "com.example.a", launched: TimeInterval = 1) -> RunningAppIdentity {
        RunningAppIdentity(processIdentifier: pid, bundleIdentifier: bundle,
                           launchDate: Date(timeIntervalSince1970: launched), name: "A")
    }

    func testATargetNamesOneAppForOnePluginOnly() throws {
        let targets = AppTargets()
        let one = PluginID("one"), two = PluginID("two")
        let target = try XCTUnwrap(targets.target(naming: app(1), for: one))
        XCTAssertTrue(AppTargets.isWellFormed(target))
        XCTAssertFalse(target.contains("1") && target == "app_1", "Never the process ID")
        XCTAssertEqual(targets.target(naming: app(1), for: one), target, "The same App gives the same target")
        XCTAssertEqual(targets.app(for: target, of: one), app(1))
        XCTAssertNil(targets.app(for: target, of: two), "Another Plugin's target names nothing")
        XCTAssertNotEqual(targets.target(naming: app(1, launched: 2), for: one), target,
                          "A relaunch reusing the process ID is another App")

        targets.forget(app(1))
        XCTAssertNil(targets.app(for: target, of: one))
        let again = try XCTUnwrap(targets.target(naming: app(5), for: one))
        targets.forget(one)
        XCTAssertNil(targets.app(for: again, of: one))
    }

    /// Without a launch date, a process that later reuses the ID could not
    /// be told apart, so the Host neither names nor ends such an App.
    func testAnAppWithoutALaunchDateIsNoAppTheHostNamesOrQuits() {
        let unlaunched = RunningAppIdentity(processIdentifier: 1, bundleIdentifier: nil, launchDate: nil, name: "Tool")
        XCTAssertFalse(unlaunched.isSameApp(as: unlaunched))
        let targets = AppTargets()
        XCTAssertNil(targets.target(naming: unlaunched, for: PluginID("one")))

        let apps = OneRunningApp(unlaunched)
        XCTAssertEqual(targets.identifyFrontmost(of: apps, for: PluginID("one")), .null)
        XCTAssertEqual(targets.count(for: PluginID("one")), 0)

        let exits = AppExitPerformer(apps: apps, targets: targets, confirmations: HeldConfirmations(),
                                     schedule: { _, _ in })
        var result: HostOperationResult?
        let action = try! ActionConfiguration(id: ActionID("a"), pluginID: PluginID("one"),
                                              command: CommandDeclaration(id: CommandID("c"), title: "C",
                                                                          execution: .javascript, script: "c.js"),
                                              input: .null)
        exits.perform(AppExitRequest(), accepted: exits.accept(AppExitRequest()), for: action, pluginName: "One",
                      authorize: {}) { result = $0 }
        XCTAssertEqual(result?.outcome, .refused(.noTarget))
        XCTAssertEqual(apps.exits, 0)
    }

    /// The Host forgets an App's targets as it quits, not when a Plugin next
    /// names it.
    func testAnAppThatQuitsLosesItsTargetsAtOnce() throws {
        let apps = RecordedApps(front: .textEdit, running: [.safari])
        let plugin = PluginID("one")
        _ = apps.targets.identifyFrontmost(of: apps, for: plugin)
        apps.bringToFront(.safari)
        _ = apps.targets.identifyFrontmost(of: apps, for: plugin)
        XCTAssertEqual(apps.targets.count(for: plugin), 2)
        apps.quit(.textEdit)
        XCTAssertEqual(apps.targets.count(for: plugin), 1)
    }

    func testAPluginHoldsAtMostSixteenForgettingTheLeastRecent() throws {
        let targets = AppTargets()
        let plugin = PluginID("one")
        let first = try XCTUnwrap(targets.target(naming: app(1), for: plugin))
        let second = try XCTUnwrap(targets.target(naming: app(2), for: plugin))
        for pid in 3...Int32(AppTargets.maximumPerPlugin) { _ = targets.target(naming: app(pid), for: plugin) }
        _ = targets.target(naming: app(1), for: plugin)  // read again: now the most recent
        _ = targets.target(naming: app(99), for: plugin)
        XCTAssertEqual(targets.count(for: plugin), AppTargets.maximumPerPlugin)
        XCTAssertEqual(targets.app(for: first, of: plugin), app(1))
        XCTAssertNil(targets.app(for: second, of: plugin))
    }

    // MARK: Protection

    /// Close and Quit are the App's own: offered exactly when its menu has
    /// an enabled ⌘W or ⌘Q item, so an App without ⌘Q, such as Finder, has
    /// no Quit by what its menu says, not by its name. Force Quit is offered
    /// for every regular App but Spinnet. An agent or background process,
    /// which is how the parts of macOS that run as Apps run, has none.
    func testTheExitsFollowTheAppsOwnMenuAndNoRuleNamesAnApp() {
        let own: Int32 = 7
        func exits(_ bundle: String?, pid: Int32 = 1, regular: Bool = true, menu: Set<AppExit>) -> [AppExit] {
            AppExitPolicy.exits(for: RunningAppFacts(identity: RunningAppIdentity(processIdentifier: pid, bundleIdentifier: bundle,
                                                                             launchDate: nil, name: "X"),
                                                     isRegular: regular),
                                menu: menu, ownProcessIdentifier: own)
        }
        XCTAssertEqual(exits("com.apple.TextEdit", menu: [.close, .quit]), [.close, .quit, .forceQuit])
        XCTAssertEqual(exits(nil, menu: [.quit]), [.quit, .forceQuit])
        XCTAssertEqual(exits("com.apple.finder", menu: [.close]), [.close, .forceQuit])
        XCTAssertEqual(exits("com.apple.finder", menu: []), [.forceQuit])
        XCTAssertEqual(exits("com.example.agent", regular: false, menu: [.close, .quit]), [])
        XCTAssertEqual(exits("com.vulpsecula.Spinnet", pid: own, menu: [.close, .quit]), [])
        XCTAssertEqual(exits("com.example.any", menu: [.forceQuit]), [.forceQuit], "A menu offers no Force Quit")
        XCTAssertEqual(AppExit.allCases.map(\.rawValue), ["close", "quit", "force_quit"])
    }

    // MARK: Capabilities

    func testTheCapabilitiesAreLevelTwosAndDisclosedSeparately() {
        XCTAssertEqual(PluginCapability.readFrontmostApp.apiLevel, 2)
        XCTAssertEqual(PluginCapability.quitFrontmostApp.apiLevel, 2)
        XCTAssertEqual(PluginCapability.readFrontmostApp.consentGroup, .reads)
        XCTAssertEqual(PluginCapability.quitFrontmostApp.consentGroup, .controls)
        XCTAssertEqual(HostServiceCatalogue.operation("apps.frontmost")?.capabilities, [.readFrontmostApp])
        XCTAssertEqual(HostServiceCatalogue.operation("apps.quit")?.capabilities, [.quitFrontmostApp])
        XCTAssertEqual(HostServiceCatalogue.operation("apps.close")?.capabilities, [.quitFrontmostApp])
        XCTAssertFalse(HostServiceCatalogue.operation("apps.quit")!.isOffered(at: .call), "No synchronous kill")
        XCTAssertFalse(HostServiceCatalogue.operation("apps.close")!.isOffered(at: .call))
        // Close always presses a menu item through Accessibility; Quit does
        // too, but Force Quit, under the same ID, does not need it.
        XCTAssertEqual(HostServiceCatalogue.operation("apps.close")?.systemPermission, .accessibility)
        XCTAssertNil(HostServiceCatalogue.operation("apps.quit")?.systemPermission)
        XCTAssertTrue(HostServiceCatalogue.operation("apps.quit")!.failures.contains(.systemPermissionDenied))
        for id in CurrentAppAddition.exitIDs {
            XCTAssertTrue(PluginInterfaceContracts.levelTwoMembers.contains(.request(id)), id)
            XCTAssertTrue(PluginInterfaceContracts.levelTwoMembers.contains(.standardAction(id)), id)
        }
    }
}

/// One regular App in front, which the Host would find again only by an
/// identity that matches it.
private final class OneRunningApp: RunningApps {
    let app: RunningAppIdentity
    private(set) var exits = 0
    let ownProcessIdentifier: Int32 = 100

    init(_ app: RunningAppIdentity) { self.app = app }

    func frontmost() -> RunningAppFacts? { RunningAppFacts(identity: app, isRegular: true) }

    func facts(of other: RunningAppIdentity) -> RunningAppFacts? {
        other.isSameApp(as: app) ? RunningAppFacts(identity: app, isRegular: true) : nil
    }

    func menuExits(of other: RunningAppIdentity) throws -> Set<AppExit> { [.close, .quit] }

    func perform(_ exit: AppExit, on other: RunningAppIdentity) throws -> AppExitDelivery {
        exits += 1
        return .delivered
    }

    func observeTerminations(_ terminated: @escaping (RunningAppIdentity) -> Void) {}
}
