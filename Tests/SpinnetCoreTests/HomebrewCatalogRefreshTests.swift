import XCTest
@testable import SpinnetCore
@testable import SpinnetReviewedTools

final class HomebrewCatalogRefreshTests: XCTestCase {
    private let refresh: JSONValue = .object(["tool": .string("homebrew"), "operation": .string("refreshCatalog")])
    private func answer(_ input: JSONValue) -> JSONValue {
        .object(["page": .object(["id": .string("catalog"), "title": .string("Updating Catalog"), "content": .array([
            .object(["kind": .string("text"), "id": .string("status"), "text": .string("Updating…")])])]),
                 "operation": .object(["perform": .string("tools.startTask"), "input": input, "id": .string("catalog"), "notify": .bool(true)])])
    }
    func testAutomaticRefreshHasOneFixedCommandAndItsOwnGlobalScope() throws {
        let input = try HomebrewTaskInput(refresh)
        XCTAssertEqual(input.arguments, ["update"]); XCTAssertEqual(input.kind, "both")
        for extra: [String: JSONValue] in [["name": .string("wget")], ["kind": .string("formula")], ["argv": .array([])], ["force": .bool(true)]] {
            guard case .object(let base) = refresh else { return XCTFail() }
            XCTAssertThrowsError(try HomebrewTaskInput(.object(base.merging(extra) { _, new in new })))
        }
        func scope(_ operations: [String], _ kinds: [String]) -> PluginCapabilityScope {
            .init(capability: .runReviewedToolTasks, commandIDs: [.init("show")], reviewedTools: [.init(tool: "homebrew", operations: operations, kinds: kinds)])
        }
        XCTAssertThrowsError(try input.authorize(in: scope(["update"], ["formula", "cask"])))
        XCTAssertThrowsError(try input.authorize(in: scope(["refreshCatalog"], ["formula"])))
        XCTAssertNoThrow(try input.authorize(in: scope(["refreshCatalog"], ["formula", "cask"])))
    }
    func testOnlyEntryAndForegroundPageGesturesMayStartTheOptedInRefresh() throws {
        let member = PluginInterfaceMember.behaviour("homebrew_catalog_refresh")
        let foreground: [PluginViewEvent?] = [nil, .called, .pageFieldChanged(page: "catalog", field: "section", values: .object(["section": .string("search")])), .pageActionChosen(page: "catalog", action: "retry", values: .object([:]), selection: .null)]
        for event in foreground {
            XCTAssertNoThrow(try PluginScriptAnswer(parsing: answer(refresh), answering: event, permits: { _ in true }))
            XCTAssertThrowsError(try PluginScriptAnswer(parsing: answer(refresh), answering: event, permits: { $0 != member }))
        }
        let background: [PluginViewEvent] = [
            .sourceDelivered(page: "catalog", source: "timer", sequence: 1, result: .null, failure: nil),
            .operationFinished(id: "catalog", perform: "tools.startTask", outcome: .succeeded),
            .loadRange(page: "catalog", collection: "rows", start: 0, count: 10)
        ]
        for event in background {
            XCTAssertThrowsError(try PluginScriptAnswer(parsing: answer(refresh), answering: event, permits: { _ in true }))
        }
        for operation in ["update", "upgradeAll"] {
            XCTAssertThrowsError(try PluginScriptAnswer(parsing: answer(.object(["tool": .string("homebrew"), "operation": .string(operation)])), answering: nil, permits: { _ in true }))
        }
    }
    private final class Confirmation: HostConfirming {
        var shown = 0
        func confirm(_ confirmation: HostConfirmation, for action: ActionConfiguration, answer: @escaping (HostConfirmationAnswer) -> Void) -> () -> Void {
            shown += 1; return {}
        }
    }
    func testAutomaticScopeSkipsOnlyItsTaskConfirmationAndRevalidatesAuthority() throws {
        for operation in ["refreshCatalog", "update"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let owner = PluginID("catalog.fixture"), command = CommandDeclaration(id: .init("show"), title: "Show", execution: .javascript, script: "show.js")
            let scope = PluginCapabilityScope(capability: .runReviewedToolTasks, commandIDs: [command.id], reviewedTools: [.init(tool: "homebrew", operations: [operation], kinds: ["formula", "cask"])])
            let manifest = try PluginManifest(id: owner, name: "Catalog", version: "1", capabilities: [.runReviewedToolTasks], capabilityScopes: [scope], commands: [command])
            let registry = PluginRegistry(); try registry.register(.init(rootURL: root, manifest: manifest))
            let action = try ActionConfiguration(id: .init("show"), pluginID: owner, command: command, input: .null)
            var reviews = 0, authorizations = 0
            let tasks = HostReviewedToolTasks(activities: HostActivities(), journal: root.appendingPathComponent("tasks"), runnerURL: URL(fileURLWithPath: "/usr/bin/true"),
                executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, preflight: { _ in reviews += 1; return .object([:]) }, trustedTaps: { [] }, nativeInspection: nil)
            let confirmation = Confirmation()
            let performer = ReviewedTaskOperationPerformer(tasks: tasks, confirmations: confirmation, registry: registry, background: { $0() }, executor: { $0() }, schedule: { _, _ in })
            var outcomes: [HostOperationOutcome] = []
            let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string(operation)]))
            performer.perform(input, for: action, accepted: performer.accept(owner: owner), authorize: { authorizations += 1 }, completion: { outcomes.append($0.outcome) })
            if operation == "refreshCatalog" {
                XCTAssertEqual(confirmation.shown, 0); XCTAssertEqual(outcomes, [.succeeded])
                XCTAssertGreaterThanOrEqual(reviews, 2, "Launch must reload the prepared input")
                XCTAssertGreaterThanOrEqual(authorizations, 3)
            } else {
                XCTAssertEqual(confirmation.shown, 1); XCTAssertTrue(outcomes.isEmpty)
            }
            performer.abandon(owner, because: .viewClosed)
        }
    }
    func testCurrentRefreshScopeDoesNotExpandPreviousGrants() throws {
        let command = CommandDeclaration(id: .init("show"), title: "Show", execution: .javascript, script: "show.js")
        func manifest(_ version: Int, operation: String) throws -> PluginManifest {
            try .init(id: .init("catalog.fixture"), name: "Catalog", version: "\(version)", capabilities: [.runReviewedToolTasks],
                      capabilityScopes: [.init(capability: .runReviewedToolTasks, commandIDs: [command.id], reviewedTools: [.init(tool: "homebrew", operations: [operation], kinds: ["formula", "cask"])])], commands: [command])
        }
        XCTAssertNoThrow(try manifest(6, operation: "refreshCatalog"))
        let old = try manifest(6, operation: "update"), new = try manifest(7, operation: "refreshCatalog")
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(.granted, for: old.id, pluginVersion: old.version, capability: .runReviewedToolTasks, scope: old.scope(for: .runReviewedToolTasks))
        grants.prepareInstallation(of: new, replacing: old)
        XCTAssertEqual(grants.decision(for: new.id, pluginVersion: new.version, capability: .runReviewedToolTasks, scope: new.scope(for: .runReviewedToolTasks)), .notDetermined)
        XCTAssertTrue(PluginInterfaceContracts.host.permits(HomebrewCatalogRefresh.member, declaredBy: new))
        XCTAssertTrue(PluginInterfaceContracts.host.permits(HomebrewCatalogRefresh.member, declaredBy: old))

    }

}
