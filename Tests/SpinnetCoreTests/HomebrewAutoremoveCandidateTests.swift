import XCTest
import SpinnetCore
import SpinnetPluginTestKit

final class HomebrewAutoremoveCandidateTests: XCTestCase {
    private let preview: JSONValue = .object(["tool": .string("homebrew"), "operation": .string("previewAutoremove")])
    private let task: JSONValue = .object(["tool": .string("homebrew"), "operation": .string("autoremove")])
    private func manifest(_ revision: Int? = nil) throws -> PluginManifest {
        let candidate = revision == 2 ? ",\"candidate_contracts\":[{\"name\":\"homebrew_autoremove\",\"revision\":2}]" : ""
        return try PluginManifestLoader.decode(Data("""
        {"api_level":\(revision == 1 ? 3 : 2),"protocol_version":"1.0","id":"test.autoremove","name":"Autoremove","version":"1.0"\(candidate),"capabilities":[],"commands":[{"id":"open","title":"Open","execution":"javascript","script":"open.js"}]}
        """.utf8))
    }
    func testLevelTwoPluginCannotCreateAutoremoveCallsSourcesRequestsOrStandardActions() throws {
        let stable = try manifest(), permits = PluginInterfaceContracts.host.permitting(stable)
        let call = PluginRuntimeHostServiceCall(invocationID: "run", actionID: try ActionID("open"), requestID: "r", name: "tools.read", input: preview)
        if case .success = try PluginInterfaceContracts.host.resolve(call, declaredBy: stable) { XCTFail("Stable call admitted candidate operation") }
        XCTAssertThrowsError(try PluginPageSource(parsing: .object(["id": .string("preview"), "perform": .string("tools.read"), "input": preview]), permits: permits))
        XCTAssertThrowsError(try RequestedHostOperation(parsing: .object(["perform": .string("tools.startTask"), "input": task]), permits: permits))
        let page: JSONValue = .object(["id": .string("test"), "title": .string("Test"), "content": .array([.object(["kind": .string("actions"), "id": .string("actions"), "actions": .array([.object(["id": .string("remove"), "title": .string("Remove"), "perform": .string("tools.startTask"), "input": task])])])])])
        XCTAssertThrowsError(try PluginPage(parsing: page, permits: permits))
    }
}

extension HomebrewAutoremoveCandidateTests {
    func testLevelThreeCanCreateEverySupportedEntryAndRejectsOldHostAndUnknownRevision() throws {
        let exact = try manifest(1), contracts = PluginInterfaceContracts.host, permits = contracts.permitting(exact)
        try contracts.check(exact, origin: .installed)
        let registry = PluginRegistry(); try registry.register(.init(rootURL: URL(fileURLWithPath: "/tmp/autoremove"), manifest: exact))
        XCTAssertThrowsError(try PluginInterfaceContracts(levels: [1: PluginInterfaceContracts.levelOneMembers, 2: PluginInterfaceContracts.levelTwoMembers]).check(exact, origin: .installed))
        XCTAssertThrowsError(try contracts.check(manifest(2), origin: .installed))
        XCTAssertNoThrow(try contracts.check(exact, origin: .bundled))
        _ = try PluginPageSource(parsing: .object(["id": .string("preview"), "perform": .string("tools.read"), "input": preview]), permits: permits)
        _ = try RequestedHostOperation(parsing: .object(["perform": .string("tools.startTask"), "input": task]), permits: permits)
        let call = PluginRuntimeHostServiceCall(invocationID: "run", actionID: try ActionID("open"), name: "tools.read", input: preview)
        if case .failure(let error) = try contracts.resolve(call, declaredBy: exact) { XCTFail("Exact candidate refused: \(error)") }
        // Stable members retain their original entry points without declaring this candidate.
        _ = try PluginPageSource(parsing: .object(["id": .string("installed"), "perform": .string("tools.read"), "input": .object(["tool": .string("homebrew"), "operation": .string("installed")])]), permits: contracts.permitting(manifest()))
    }

    func testStableFixturesAndRetirementMetadataPreserveEarlierLevelBoundaries() throws {
        let api = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("PluginAPI")
        let folder = api.appendingPathComponent("fixtures/level-3/homebrew-autoremove")
        XCTAssertEqual(try JSONDecoder().decode(CandidateContract.self, from: Data(contentsOf: api.appendingPathComponent("candidates/homebrew_autoremove/r1/candidate.json"))).status, .retired(promotedToLevel: 3))
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

extension HomebrewAutoremoveCandidateTests {
    func testUndeclaredCandidateIsRefusedAtReadAndTaskExecutionBeforeAuthorityOrPreparation() throws {
        let manifest = try manifest(), package = PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/autoremove"), manifest: manifest)
        let action = try ActionConfiguration(id: .init("open"), pluginID: manifest.id, command: manifest.commands[0], input: .null)
        let registry = PluginRegistry(); try registry.register(package)
        var reads = 0, preparations = 0, authorizations = 0
        let profile = HomebrewReadProfile(executable: { reads += 1; return URL(fileURLWithPath: "/missing") })
        let broker = CapabilityCheckedHostServiceBroker(grantStore: .init(), systemPermissionCheck: { _ in true }, selectedTextProvider: { _ in "" }, clipboardWriter: { _ in }, reviewedTools: profile)
        let request = PluginRuntimeHostServiceRequest(invocationID: "run", actionID: action.id, service: .reviewedToolRead, input: preview)
        func candidateRefusal(_ error: Error) { XCTAssertEqual(error as? PluginHostServiceError, .unavailable("Homebrew autoremove requires Plugin API Level 3")) }
        XCTAssertThrowsError(try broker.execute(request: request, for: package, action: action)) { candidateRefusal($0) }
        // Parse against a permissive presentation context, then recheck the current owner at execution.
        let source = try PluginPageSource(parsing: .object(["id": .string("preview"), "perform": .string("tools.read"), "input": preview]), permits: { _ in true })
        let adapter = broker.reviewedToolSourceAdapter(using: registry)
        XCTAssertThrowsError(try adapter.authorize(action, source)) { candidateRefusal($0) }
        XCTAssertThrowsError(try adapter.sample(action, source, .init())) { candidateRefusal($0) }
        let journal = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: journal) }
        let tasks = HostReviewedToolTasks(activities: .init(), journal: journal, runnerURL: URL(fileURLWithPath: "/missing"), executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, preflight: { _ in preparations += 1; return .null })
        let performer = ReviewedTaskOperationPerformer(tasks: tasks, confirmations: NeverConfirm(), registry: registry, background: { $0() }, executor: { $0() }, schedule: { _, _ in })
        var result: HostOperationResult?
        performer.perform(try HomebrewTaskInput(task), for: action, accepted: performer.accept(owner: manifest.id), authorize: { authorizations += 1 }) { result = $0 }
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.message?.contains("Plugin API Level 3") == true)
        XCTAssertEqual(reads, 0); XCTAssertEqual(preparations, 0); XCTAssertEqual(authorizations, 0)
    }
    private final class NeverConfirm: HostConfirming {
        func confirm(_ confirmation: HostConfirmation, for action: ActionConfiguration, answer: @escaping (HostConfirmationAnswer) -> Void) -> () -> Void {
            XCTFail("Undeclared task reached confirmation"); return {}
        }
    }

    func testHelperForwardsCandidatePreviewButNeverUndeclaredPreviewOrTaskAnswers() throws {
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
        for revision: Int? in [nil, 1] {
            let manifest = try manifest(revision)
            try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("manifest.json"))
            for (index, script) in scripts.enumerated() {
                try "(function(){\(script)})()".write(to: root.appendingPathComponent("open.js"), atomically: true, encoding: .utf8)
                let plugin = try PluginUnderTest(packageAt: root)
                let run = helper.run(.init("open", event: .pageActionChosen(page: "p", action: "remove", values: .null, selection: .null)), of: plugin, answering: PermissiveReads())
                if revision == nil { XCTAssertThrowsError(try run.answer(), "Undeclared entry \(index) must fail"); XCTAssertTrue(run.requests.isEmpty) }
                else { _ = try run.answer() }
            }
        }
    }
    private final class PermissiveReads: PluginHostServiceBroker {
        func execute(request: PluginRuntimeHostServiceRequest, for package: PluginPackage, action: ActionConfiguration) throws -> JSONValue { .object(["available": .bool(true)]) }
    }
}

extension HomebrewAutoremoveCandidateTests {
    func testCandidateScopesCannotBeRegisteredWithoutTheExactDeclaration() throws {
        let command = CommandDeclaration(id: .init("open"), title: "Open", execution: .javascript, script: "open.js")
        for (capability, operation) in [(PluginCapability.readReviewedTools, "previewAutoremove"), (.runReviewedToolTasks, "autoremove")] {
            let scope = PluginCapabilityScope(capability: capability, commandIDs: [command.id], reviewedTools: [.init(tool: "homebrew", operations: [operation], kinds: ["formula"])])
            for revision: Int? in [nil, 1, 2] {
                let manifest = try PluginManifest(apiLevel: revision == 1 ? 3 : 2, candidateContracts: revision == 2 ? [.init(name: "homebrew_autoremove", revision: 2)] : [], id: .init("test.scoped.autoremove"), name: "Scoped Autoremove", version: "1.0", capabilities: [capability], capabilityScopes: [scope], commands: [command])
                let package = PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/scoped-autoremove"), manifest: manifest)
                let registry = PluginRegistry()
                if revision == 1 { try registry.register(package) }
                else { XCTAssertThrowsError(try registry.register(package)) }
            }
        }
    }
}
