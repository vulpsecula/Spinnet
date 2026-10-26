import Foundation
import XCTest
@testable import SpinnetCore

final class CurrentPluginInterfaceTests: XCTestCase {
    private let host = PluginInterfaceContracts.host
    private func manifest(_ range: String = "^1.0.0") throws -> PluginManifest {
        try PluginManifest(hostCompatibility: HostCompatibility(range), id: .init("com.example.current-interface"),
            name: "Current Interface", version: "1.0.0", commands: [
                .init(id: .init("run"), title: "Run", execution: .javascript, script: "run.js")])
    }
    func testCompatibleOriginsReceiveTheSameCurrentMembers() throws {
        let manifest = try manifest()
        for origin in [PluginOrigin.installed, .bundled] { try host.check(manifest, origin: origin) }
        let required: [PluginInterfaceMember] = [
            HostServiceCatalogue.catalogueIDsOnly, .hostService("clipboard.write"), .hostCommand("open.url"),
            HostOperationsContract.answerOperation, .request("selection.replace"), HostOperationsContract.operationFinished,
            HostOperationsContract.executionTimeInsertionTarget, HostOperationsContract.outcomeAfterClose,
            CollectionsContract.answerPage, .viewComponent("grid"), .standardAction("clipboard.write"),
            CollectionsContract.repeatedCallsIntoSession, CollectionsContract.collectionWindow,
            CollectionsContract.loadRange, CollectionsContract.toggleItemActions, CollectionsContract.performedActionOutcomes]
        for member in required { XCTAssertTrue(host.permits(member, declaredBy: manifest), "\(member)") }
        XCTAssertFalse(host.permits(.viewEvent("load_more"), declaredBy: manifest), "Retired event spellings remain unsupported")
    }
    func testCallsUseCatalogueIDsAndRefuseInternalAdapterNames() throws {
        func call(_ name: String) -> PluginRuntimeHostServiceCall {
            .init(invocationID: "i", actionID: .init("a"), name: name, input: .string("x"))
        }
        let manifest = try manifest()
        XCTAssertEqual(try host.resolve(call("clipboard.write"), declaredBy: manifest).get().service, .writeClipboard)
        switch try host.resolve(call("write_clipboard"), declaredBy: manifest) {
        case .success: XCTFail("An internal adapter name must not be public")
        case .failure(let error): XCTAssertTrue(error.localizedDescription.contains("clipboard.write"))
        }
    }
    func testCompatibleRequirementsDoNotSelectDifferentMembers() throws {
        let exact = try manifest("1.0.0"), caret = try manifest("^1.0.0")
        for member in host.members {
            XCTAssertEqual(host.permits(member, declaredBy: exact), host.permits(member, declaredBy: caret))
        }
    }
}
