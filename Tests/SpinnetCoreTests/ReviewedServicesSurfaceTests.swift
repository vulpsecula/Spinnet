import Foundation
import XCTest
import SpinnetCore

final class ReviewedServicesSurfaceTests: XCTestCase {
    func testSurfaceStopsHiddenReadsAndRefusesForeignServices() throws {
        var reads = 0, mutations: [(String,String)] = [], allowed = true
        var work: [() -> Void] = [], finishes: [() -> Void] = [], timers: [() -> Void] = []
        let surface = ReviewedServicesSurface(authorizeRead: { if !allowed { throw PluginHostServiceError.capabilityDenied(.readReviewedTools) } },
            read: { _ in reads += 1; return .object(["services": .array([.object(["name": .string("postgresql@16"), "status": .string("started"), "user_owned": .bool(true)]), .object(["name": .string("redis"), "status": .string("started"), "user_owned": .bool(false)])])]) },
            authorizeControl: { _, _ in }, control: { op, name, done in mutations.append((op,name)); done(nil) },
            background: { work.append($0) }, executor: { finishes.append($0) }, schedule: { _, task in timers.append(task) })
        surface.setVisible(true); XCTAssertEqual(work.count, 1)
        work.removeFirst()(); finishes.removeFirst()()
        XCTAssertEqual(surface.rows.count, 2)
        XCTAssertThrowsError(try surface.choose(.stop, name: "redis"))
        XCTAssertTrue(mutations.isEmpty)
        try surface.choose(.restart, name: "postgresql@16")
        XCTAssertEqual(mutations.first?.0, "serviceRestart")
        XCTAssertEqual(mutations.first?.1, "postgresql@16")
        surface.setVisible(false)
        for timer in timers { timer() }
        XCTAssertEqual(reads, 1)
        allowed = false; surface.setVisible(true)
        if !work.isEmpty { work.removeFirst()() }
        if !finishes.isEmpty { finishes.removeFirst()() }
        XCTAssertThrowsError(try surface.choose(.stop, name: "postgresql@16"))
        surface.close()
        XCTAssertTrue(surface.rows.isEmpty)
    }
}

extension ReviewedServicesSurfaceTests {
    func testPublicSurfaceOperationRequiresExactReviewedInputAndScope() throws {
        let good: JSONValue = .object(["tool": .string("homebrew")])
        XCTAssertNoThrow(try ReviewedServicesAddition.validate(good))
        XCTAssertThrowsError(try ReviewedServicesAddition.validate(.object(["tool": .string("homebrew"), "command": .string("launchctl")])) )
        let scope = PluginCapabilityScope(capability: .readReviewedTools, commandIDs: [CommandID("services")], reviewedTools: [.init(tool: "homebrew", operations: ["services"], kinds: ["formula"])])
        XCTAssertNoThrow(try ReviewedServicesAddition.authorize(in: scope))
        XCTAssertThrowsError(try ReviewedServicesAddition.authorize(in: .init(capability: .readReviewedTools, commandIDs: [CommandID("services")], reviewedTools: [.init(tool: "homebrew", operations: ["installed"], kinds: ["formula"])])))
        let request = try RequestedHostOperation(parsing: .object(["perform": .string("tools.showServices"), "input": good]), permits: { PluginInterfaceContracts.levelTwoMembers.contains($0) })
        XCTAssertEqual(try request.implementation()?.service, .showReviewedServices)
        XCTAssertFalse(PluginHostService.showReviewedServices.isLevelOne)
        XCTAssertFalse(HostServiceCatalogue.operation("tools.showServices")!.isOffered(at: .call))
    }
}

extension ReviewedServicesSurfaceTests {
    func testPublishedSurfaceRequestFixturesMatchHostAndSchemas() throws {
        let api = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("PluginAPI")
        struct Index: Decodable { struct Fixture: Decodable { let file: String; let definition: String; let schema: String?; let valid: Bool }; let fixtures: [Fixture] }
        let dir = api.appendingPathComponent("fixtures/services-surface")
        for fixture in try JSONDecoder().decode(Index.self, from: Data(contentsOf: dir.appendingPathComponent("index.json"))).fixtures {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: dir.appendingPathComponent(fixture.file)))
            let schema = try JSONSchemaSubsetValidator(definition: fixture.definition, inSchemaAt: api.appendingPathComponent("schemas/" + (fixture.schema ?? "namespaces.schema.json")))
            XCTAssertEqual(schema.errors(for: value).isEmpty, fixture.valid, fixture.file)
            if fixture.definition == "operation" { XCTAssertEqual((try? RequestedHostOperation(parsing: value, permits: { PluginInterfaceContracts.levelTwoMembers.contains($0) })) != nil, fixture.valid) }
        }
    }

    func testLateReadAndCloseNeverRestartOrPerformAServiceChange() throws {
        var work: [() -> Void] = [], finishes: [() -> Void] = [], timers: [() -> Void] = [], closed = 0
        let surface = ReviewedServicesSurface(authorizeRead: {}, read: { _ in .object(["services": .array([.object(["name": .string("redis"), "status": .string("started"), "user_owned": .bool(true)])])]) }, authorizeControl: { _, _ in },
            control: { _, _, _ in XCTFail("Closing cannot start a Task") }, closeControl: { closed += 1 },
            background: { work.append($0) }, executor: { finishes.append($0) }, schedule: { _, task in timers.append(task) })
        surface.setVisible(true); work.removeFirst()()
        surface.close(); finishes.removeFirst()()
        XCTAssertTrue(surface.rows.isEmpty)
        XCTAssertEqual(closed, 1)
        for timer in timers { timer() }
        XCTAssertTrue(work.isEmpty)
        XCTAssertThrowsError(try surface.choose(.restart, name: "redis"))
        surface.close(); XCTAssertEqual(closed, 1)
    }
}

extension ReviewedServicesSurfaceTests {
    func testBrokerOpensOnlyAnExactlyScopedAndCurrentlyGrantedSurface() throws {
        let command = CommandDeclaration(id: CommandID("services"), title: "Services", hostServiceID: ReviewedServicesAddition.id, fixedInput: .object(["tool": .string("homebrew")]))
        let scope = PluginCapabilityScope(capability: .readReviewedTools, commandIDs: [command.id], reviewedTools: [.init(tool: "homebrew", operations: ["services"], kinds: ["formula"])])
        let manifest = try PluginManifest(apiLevel: 2, id: PluginID("com.example.services"), name: "Services", version: "1.0", capabilities: [.readReviewedTools], capabilityScopes: [scope], commands: [command])
        let package = PluginPackage(rootURL: URL(fileURLWithPath: "/private/tmp/services-fixture"), manifest: manifest, origin: .installed)
        let action = try ActionConfiguration(id: ActionID("services"), pluginID: manifest.id, command: command, input: .null)
        let grants = PluginCapabilityGrantStore(); var shown = 0
        let broker = CapabilityCheckedHostServiceBroker(grantStore: grants, systemPermissionCheck: { _ in XCTFail("Services requires no System Permission"); return false }, selectedTextProvider: { _ in "" }, clipboardWriter: { _ in }, reviewedServicesPresenter: { _, _ in shown += 1 })
        let request = PluginRuntimeHostServiceRequest(invocationID: "surface", actionID: action.id, service: .showReviewedServices, input: .object(["tool": .string("homebrew")]), operation: ReviewedServicesAddition.id)
        XCTAssertThrowsError(try broker.execute(request: request, for: package, action: action))
        XCTAssertEqual(shown, 0)
        grants.setDecision(.granted, for: manifest.id, pluginVersion: manifest.version, capability: .readReviewedTools, scope: scope)
        XCTAssertEqual(try broker.execute(request: request, for: package, action: action), .null)
        XCTAssertEqual(shown, 1)
        grants.setDecision(.denied, for: manifest.id, pluginVersion: manifest.version, capability: .readReviewedTools, scope: scope)
        XCTAssertThrowsError(try broker.execute(request: request, for: package, action: action))
        XCTAssertEqual(shown, 1)
    }
}
