import XCTest
import SpinnetCore

final class HostServiceDomainTests: XCTestCase {
    func testTypedReadAdapterUsesCurrentGrantsAndInvalidatesItsOwnersTargets() throws {
        let (package, action, scope) = try fixture()
        let grants = PluginCapabilityGrantStore()
        let reads = RecordedReads()
        let broker = CapabilityCheckedHostServiceBroker(grantStore: grants, systemPermissionCheck: { _ in true },
            tools: .init(reader: reads))
        XCTAssertThrowsError(try broker.execute(request: request(action), for: package, action: action)) {
            XCTAssertEqual($0 as? PluginHostServiceError, .capabilityDenied(.readReviewedTools))
        }
        XCTAssertEqual(reads.calls, 0, "A domain adapter cannot run before the central authority gate")
        grants.setDecision(.granted, for: package.manifest.id, pluginVersion: "1", capability: .readReviewedTools, scope: scope)
        XCTAssertEqual(try broker.execute(request: request(action), for: package, action: action), reads.answer)
        XCTAssertEqual(reads.owners, [package.manifest.id])
        grants.setDecision(.denied, for: package.manifest.id, pluginVersion: "1", capability: .readReviewedTools, scope: scope)
        XCTAssertEqual(reads.invalidations, [package.manifest.id])
    }

    func testRevocationDuringARecordedReadCannotBeUndoneByReturningAnAnswer() throws {
        let (package, action, scope) = try fixture()
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(.granted, for: package.manifest.id, pluginVersion: "1", capability: .readReviewedTools, scope: scope)
        let reads = RecordedReads()
        reads.beforeAnswer = {
            grants.setDecision(.denied, for: package.manifest.id, pluginVersion: "1", capability: .readReviewedTools, scope: scope)
            grants.setDecision(.granted, for: package.manifest.id, pluginVersion: "1", capability: .readReviewedTools, scope: scope)
        }
        let broker = CapabilityCheckedHostServiceBroker(grantStore: grants, systemPermissionCheck: { _ in true },
            tools: .init(reader: reads))
        XCTAssertThrowsError(try broker.execute(request: request(action), for: package, action: action)) {
            XCTAssertEqual($0 as? PluginHostServiceError, .capabilityDenied(.readReviewedTools))
        }
        XCTAssertEqual(reads.calls, 1)
        XCTAssertTrue(reads.cancellation?.isCancelled == true)
    }

    func testMissingExecutionAdapterDoesNotImplicitlyDiscoverOrRunATool() throws {
        let (package, action, scope) = try fixture()
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(.granted, for: package.manifest.id, pluginVersion: "1", capability: .readReviewedTools, scope: scope)
        let broker = CapabilityCheckedHostServiceBroker(grantStore: grants, systemPermissionCheck: { _ in true })
        XCTAssertThrowsError(try broker.execute(request: request(action), for: package, action: action)) {
            XCTAssertEqual($0 as? PluginHostServiceError, .unavailable("Reviewed tool reads"))
        }
    }

    private func fixture() throws -> (PluginPackage, ActionConfiguration, PluginCapabilityScope) {
        let command = CommandDeclaration(id: .init("read"), title: "Read", execution: .javascript, script: "read.js")
        let scope = PluginCapabilityScope(capability: .readReviewedTools, commandIDs: [command.id],
            reviewedTools: [.init(tool: "homebrew", operations: ["installed"], kinds: ["formula"])])
        let manifest = try PluginManifest(id: .init("example.domain"), name: "Domain", version: "1",
            capabilities: [.readReviewedTools], capabilityScopes: [scope], commands: [command])
        let package = PluginPackage(rootURL: FileManager.default.temporaryDirectory, manifest: manifest)
        return (package, try ActionConfiguration(id: .init("read"), pluginID: manifest.id, command: command, input: .null), scope)
    }

    private func request(_ action: ActionConfiguration) -> PluginRuntimeHostServiceRequest {
        PluginRuntimeHostServiceRequest(invocationID: "read", actionID: action.id, service: .reviewedToolRead,
            input: .object(["tool": .string("homebrew"), "operation": .string("installed"), "kind": .string("formula")]),
            operation: ReviewedToolReads.id)
    }

    private final class RecordedReads: HostReviewedToolReading {
        let answer: JSONValue = .object(["tool": .string("homebrew"), "packages": .array([])])
        var calls = 0
        var owners: [PluginID] = []
        var invalidations: [PluginID] = []
        var cancellation: HostFetchedSections.Cancellation?
        var beforeAnswer: (() -> Void)?

        func read(_ input: JSONValue, owner: PluginID, timeout: TimeInterval,
                  cancellation: HostFetchedSections.Cancellation, stillAuthorized: () throws -> Void) throws -> JSONValue {
            calls += 1; owners.append(owner); self.cancellation = cancellation
            try stillAuthorized()
            beforeAnswer?()
            try stillAuthorized()
            return answer
        }

        func invalidateManagementTargets(owner: PluginID) { invalidations.append(owner) }
    }
}
