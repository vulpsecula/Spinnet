import SpinnetTestSupport
import XCTest
import SpinnetCore
@testable import SpinnetReviewedTools
import SpinnetPluginTestKit

final class HomebrewAutoremoveContractTests: XCTestCase {
    private let preview: JSONValue = .object(["tool": .string("homebrew"), "operation": .string("previewAutoremove")])
    private let task: JSONValue = .object(["tool": .string("homebrew"), "operation": .string("autoremove")])
    private func manifest() throws -> PluginManifest {
        try PluginManifest(id: .init("test.autoremove"), name: "Autoremove", version: "1.0", commands: [
            .init(id: .init("open"), title: "Open", execution: .javascript, script: "open.js")])
    }

    func testMissingCurrentMembersRefuseCallsSourcesRequestsAndStandardActions() throws {
        let stable = try manifest()
        let restricted = PluginInterfaceContracts(members: PluginInterfaceContracts.currentMembers.subtracting(HomebrewAutoremove.members))
        let permits = restricted.permitting(stable)
        let call = PluginRuntimeHostServiceCall(invocationID: "run", actionID: ActionID("open"), requestID: "r", name: "tools.read", input: preview)
        if case .success = try restricted.resolve(call, declaredBy: stable) { XCTFail("An unavailable feature reached the call entry point") }
        XCTAssertThrowsError(try PluginPageSource(parsing: .object(["id": .string("preview"), "perform": .string("tools.read"), "input": preview]), permits: permits))
        XCTAssertThrowsError(try RequestedHostOperation(parsing: .object(["perform": .string("tools.startTask"), "input": task]), permits: permits))
        let page: JSONValue = .object(["id": .string("test"), "title": .string("Test"), "content": .array([.object(["kind": .string("actions"), "id": .string("actions"), "actions": .array([.object(["id": .string("remove"), "title": .string("Remove"), "perform": .string("tools.startTask"), "input": task])])])])])
        XCTAssertThrowsError(try PluginPage(parsing: page, permits: permits))
    }
}

extension HomebrewAutoremoveContractTests {
    func testCurrentContractSupportsEveryEntryAndRefusesAnIncompatibleHost() throws {
        let exact = try manifest(), contracts = PluginInterfaceContracts.host, permits = contracts.permitting(exact)
        try contracts.check(exact)
        let registry = PluginRegistry(); try registry.register(.init(rootURL: URL(fileURLWithPath: "/tmp/autoremove"), manifest: exact))
        XCTAssertThrowsError(try PluginInterfaceContracts(hostVersion: try HostVersion("0.9.0")).check(exact))
        XCTAssertNoThrow(try contracts.check(exact))
        _ = try PluginPageSource(parsing: .object(["id": .string("preview"), "perform": .string("tools.read"), "input": preview]), permits: permits)
        _ = try RequestedHostOperation(parsing: .object(["perform": .string("tools.startTask"), "input": task]), permits: permits)
        let call = PluginRuntimeHostServiceCall(invocationID: "run", actionID: ActionID("open"), name: "tools.read", input: preview)
        if case .failure(let error) = try contracts.resolve(call, declaredBy: exact) { XCTFail("Current feature refused: \(error)") }
        // Existing typed reads retain their entry points alongside autoremove.
        _ = try PluginPageSource(parsing: .object(["id": .string("installed"), "perform": .string("tools.read"), "input": .object(["tool": .string("homebrew"), "operation": .string("installed")])]), permits: contracts.permitting(manifest()))
    }

    func testCurrentFixturesPreserveTypedSelectorBoundaries() throws {
        let api = TestRepository.root.appendingPathComponent("PluginAPI")
        let folder = api.appendingPathComponent("fixtures/homebrew-autoremove")
        struct Entry: Decodable { let file: String; let definition: String; let valid: Bool }
        struct Index: Decodable { let fixtures: [Entry] }
        for entry in try JSONDecoder().decode(Index.self, from: Data(contentsOf: folder.appendingPathComponent("index.json"))).fixtures {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: folder.appendingPathComponent(entry.file)))
            let schema = try JSONSchemaSubsetValidator(definition: entry.definition, inSchemaAt: api.appendingPathComponent("schemas/homebrew-autoremove.schema.json"))
            XCTAssertEqual(schema.errors(for: value).isEmpty, entry.valid, entry.file)
        }
        XCTAssertFalse(try JSONSchemaSubsetValidator(definition: "input", inSchemaAt: api.appendingPathComponent("schemas/homebrew-management-reads.schema.json")).errors(for: preview).isEmpty)
        XCTAssertFalse(try JSONSchemaSubsetValidator(definition: "tools.startTask.input", inSchemaAt: api.appendingPathComponent("schemas/reviewed-tools.schema.json")).errors(for: task).isEmpty)
    }
}

extension HomebrewAutoremoveContractTests {
    func testMissingAuthorityRefusesReadsSourcesAndTasksBeforePreparation() throws {
        let manifest = try manifest(), package = PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/autoremove"), manifest: manifest)
        let action = try ActionConfiguration(id: .init("open"), pluginID: manifest.id, command: manifest.commands[0], input: .null)
        let registry = PluginRegistry(); try registry.register(package)
        var reads = 0, preparations = 0, authorizations = 0
        let profile = HomebrewReadProfile(executable: { reads += 1; return URL(fileURLWithPath: "/missing") })
        let broker = CapabilityCheckedHostServiceBroker(
            grantStore: .init(),
            systemPermissionCheck: { _ in true },
            clipboard: .init(selectedTextProvider: { _ in "" }, clipboardWriter: { _ in }),
            tools: .init(reader: profile)
        )
        let request = PluginRuntimeHostServiceRequest(invocationID: "run", actionID: action.id, service: .reviewedToolRead, input: preview)
        func scopeRefusal(_ error: Error) { XCTAssertEqual(error as? PluginHostServiceError, .capabilityScopeDenied(.readReviewedTools)) }
        XCTAssertThrowsError(try broker.execute(request: request, for: package, action: action)) { scopeRefusal($0) }
        // Parse against a permissive presentation context, then recheck the current owner at execution.
        let source = try PluginPageSource(parsing: .object(["id": .string("preview"), "perform": .string("tools.read"), "input": preview]), permits: { _ in true })
        let adapter = broker.reviewedToolSourceAdapter(using: registry)
        XCTAssertThrowsError(try adapter.authorize(action, source)) { scopeRefusal($0) }
        XCTAssertThrowsError(try adapter.sample(action, source, .init())) { scopeRefusal($0) }
        let journal = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: journal) }
        let tasks = HostReviewedToolTasks(activities: .init(), journal: journal, runnerURL: URL(fileURLWithPath: "/missing"), executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, preflight: { _ in preparations += 1; return .null })
        let performer = ReviewedTaskOperationPerformer(tasks: tasks, confirmations: NeverConfirm(), registry: registry, background: { $0() }, executor: { $0() }, schedule: { _, _ in })
        var result: HostOperationResult?
        performer.perform(try HomebrewTaskInput(task), for: action, accepted: performer.accept(owner: manifest.id), authorize: { authorizations += 1; throw PluginHostServiceError.capabilityDenied(.runReviewedToolTasks) }) { result = $0 }
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.outcome, .refused(.capabilityDenied))
        XCTAssertEqual(reads, 0); XCTAssertEqual(preparations, 0); XCTAssertEqual(authorizations, 1)
    }
    private final class NeverConfirm: HostConfirming {
        func confirm(_ confirmation: HostConfirmation, for action: ActionConfiguration, answer: @escaping (HostConfirmationAnswer) -> Void) -> () -> Void {
            XCTFail("Unauthorized task reached confirmation"); return {}
        }
    }

    func testHelperBuildsAllCurrentPreviewAndTaskEntryPoints() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("Test.spinnetplugin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let scripts = [
            "spinnet.tools.read({tool:'homebrew',operation:'previewAutoremove'}); return {toast:'done'};",
            "return spinnet.ui.showPage(spinnet.ui.page({id:'p',title:'Preview',content:[spinnet.ui.components.text({id:'status',text:'Preview'})],sources:[spinnet.ui.source('preview','tools.read',{tool:'homebrew',operation:'previewAutoremove'},{deliver:true})]}));",
            "return spinnet.ui.request(spinnet.tools.startTask.operation({tool:'homebrew',operation:'autoremove'}));",
            "return spinnet.ui.showPage(spinnet.ui.page({id:'p',title:'Remove',content:[spinnet.ui.components.actions({id:'actions',actions:[spinnet.tools.startTask.action({tool:'homebrew',operation:'autoremove'},{id:'remove',title:'Remove'})]})]}));"
        ]
        let manifest = try manifest()
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("manifest.json"))
        for (index, script) in scripts.enumerated() {
            try "(function(){\(script)})()".write(to: root.appendingPathComponent("open.js"), atomically: true, encoding: .utf8)
            let plugin = try PluginUnderTest(packageAt: root)
            let run = helper.run(.init("open", event: .pageActionChosen(page: "p", action: "remove", values: .null, selection: .null)), of: plugin, answering: PermissiveReads())
            _ = try run.answer()
            XCTAssertEqual(run.requests.count, index == 0 ? 1 : 0)
        }
    }

    private final class PermissiveReads: PluginHostServiceBroker {
        func execute(request: PluginRuntimeHostServiceRequest, for package: PluginPackage, action: ActionConfiguration) throws -> JSONValue { .object(["available": .bool(true)]) }
    }
}

extension HomebrewAutoremoveContractTests {
    func testCurrentScopesRegister() throws {
        let command = CommandDeclaration(id: .init("open"), title: "Open", execution: .javascript, script: "open.js")
        for (capability, operation) in [(PluginCapability.readReviewedTools, "previewAutoremove"), (.runReviewedToolTasks, "autoremove")] {
            let scope = PluginCapabilityScope(capability: capability, commandIDs: [command.id], reviewedTools: [.init(tool: "homebrew", operations: [operation], kinds: ["formula"])])
            let manifest = try PluginManifest(id: .init("test.scoped.autoremove"), name: "Scoped Autoremove", version: "1.0", capabilities: [capability], capabilityScopes: [scope], commands: [command])
            let package = PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/scoped-autoremove"), manifest: manifest)
            let registry = PluginRegistry()
            try registry.register(package)
        }
    }
}
