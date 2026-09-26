import Foundation
import XCTest
@testable import SpinnetCore

/// The Plugin Storage Host Services, through the broker every invocation's
/// requests go through, View Events' included.
final class PluginStorageHostServiceTests: XCTestCase {
    private var storage: PluginStorage!
    private var broker: CapabilityCheckedHostServiceBroker!

    override func setUp() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginStorageServices-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        storage = PluginStorage(directory: directory)
        broker = CapabilityCheckedHostServiceBroker(
            grantStore: PluginCapabilityGrantStore(), systemPermissionCheck: { _ in false },
            selectedTextProvider: { _ in "" }, clipboardWriter: { _ in },
            pluginStorage: storage
        )
    }

    /// A Plugin that declares no Capability at all.
    private func makePackage(_ id: String) throws -> PluginPackage {
        let manifest = try PluginManifestLoader.decode(Data("""
        {
          "protocol_version": "1.0", "id": "\(id)", "name": "Keeper", "version": "1.0.0",
          "commands": [{"id": "keep", "title": "Keep", "execution": "javascript", "is_configurable": false, "script": "keep.js"}]
        }
        """.utf8))
        return PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/\(id)"), manifest: manifest)
    }

    private func action(of package: PluginPackage, pluginID: PluginID? = nil) throws -> ActionConfiguration {
        try ActionConfiguration(id: ActionID("keep"), pluginID: pluginID ?? package.manifest.id,
                                command: package.manifest.commands[0], input: .null)
    }

    @discardableResult
    private func request(_ service: PluginHostService, _ input: JSONValue = .null,
                         of package: PluginPackage, action: ActionConfiguration? = nil) throws -> JSONValue {
        let action = try action ?? self.action(of: package)
        return try broker.execute(request: PluginRuntimeHostServiceRequest(
            invocationID: "invocation", actionID: action.id, service: service, input: input
        ), for: package, action: action)
    }

    func testTheStorageServicesNeedNoCapabilityAndNoSystemPermission() throws {
        let services: [PluginHostService] = [.getStorageValue, .setStorageValue, .removeStorageValue,
                                             .listStorageKeys, .clearStorage]
        for service in services {
            XCTAssertNil(service.requiredCapability, service.rawValue)
            XCTAssertNil(service.requiredSystemPermission, service.rawValue)
            XCTAssertTrue(service.isPluginStorage, service.rawValue)
        }
        XCTAssertEqual(Set(PluginHostService.allCases.filter(\.isPluginStorage)), Set(services))
    }

    func testAPluginGetsSetsListsRemovesAndClearsItsOwnValues() throws {
        let keeper = try makePackage("com.example.keeper")

        XCTAssertEqual(try request(.getStorageValue, .string("runs"), of: keeper), .null)
        XCTAssertEqual(try request(.setStorageValue, .object(["key": .string("runs"), "value": .number(1)]), of: keeper), .null)
        try request(.setStorageValue, .object(["key": .string("last"), "value": .object(["at": .string("now")])]), of: keeper)

        XCTAssertEqual(try request(.getStorageValue, .string("runs"), of: keeper), .number(1))
        XCTAssertEqual(try request(.listStorageKeys, of: keeper), .array([.string("last"), .string("runs")]))
        XCTAssertEqual(try request(.removeStorageValue, .string("last"), of: keeper), .null)
        XCTAssertEqual(try request(.listStorageKeys, of: keeper), .array([.string("runs")]))
        XCTAssertEqual(try request(.clearStorage, of: keeper), .null)
        XCTAssertEqual(try request(.listStorageKeys, of: keeper), .array([]))
    }

    /// The store is chosen by the Plugin bound to the connection; a request
    /// names no Plugin, so there is nothing to name another's store with.
    func testOnePluginCannotReadOrChangeAnothersStorage() throws {
        let keeper = try makePackage("com.example.keeper")
        let snoop = try makePackage("com.example.snoop")
        try request(.setStorageValue, .object(["key": .string("secret-ish"), "value": .string("mine")]), of: keeper)

        XCTAssertEqual(try request(.getStorageValue, .string("secret-ish"), of: snoop), .null)
        XCTAssertEqual(try request(.listStorageKeys, of: snoop), .array([]))
        try request(.removeStorageValue, .string("secret-ish"), of: snoop)
        try request(.clearStorage, of: snoop)

        XCTAssertEqual(try request(.getStorageValue, .string("secret-ish"), of: keeper), .string("mine"))
        // Nor may a Plugin run the request for an Action that is not its own.
        let foreign = try action(of: snoop, pluginID: keeper.manifest.id)
        XCTAssertThrowsError(try request(.getStorageValue, .string("secret-ish"), of: snoop, action: foreign))
        XCTAssertThrowsError(try request(.clearStorage, of: snoop, action: foreign))
        XCTAssertEqual(try storage.keys(of: keeper.manifest.id), ["secret-ish"])
    }

    func testMalformedRequestsFailWithoutStoringAnything() throws {
        let keeper = try makePackage("com.example.keeper")
        let malformed: [(PluginHostService, JSONValue)] = [
            (.getStorageValue, .null),
            (.getStorageValue, .object(["key": .string("a")])),
            (.getStorageValue, .string("")),
            (.setStorageValue, .string("a")),
            (.setStorageValue, .object(["key": .string("a")])),
            (.setStorageValue, .object(["key": .string("a"), "value": .number(1), "extra": .null])),
            (.setStorageValue, .object(["key": .number(1), "value": .number(1)])),
            (.setStorageValue, .object(["key": .string(String(repeating: "k", count: 129)), "value": .number(1)])),
            (.removeStorageValue, .null),
            (.listStorageKeys, .string("a")),
            (.clearStorage, .string("a"))
        ]

        for (service, input) in malformed {
            XCTAssertThrowsError(try request(service, input, of: keeper), "\(service.rawValue) \(input)") {
                XCTAssertEqual(($0 as? PluginHostServiceError)?.runtimeFailureCategory, .hostServiceFailed)
            }
        }
        XCTAssertEqual(try storage.keys(of: keeper.manifest.id), [])
    }

    /// A write over a limit fails with the one failure a script may catch.
    func testAWriteOverALimitFailsWithACatchableFailure() throws {
        let keeper = try makePackage("com.example.keeper")
        let tooLarge = JSONValue.string(String(repeating: "x", count: 512 * 1024))

        XCTAssertThrowsError(try request(.setStorageValue, .object(["key": .string("a"), "value": tooLarge]), of: keeper)) {
            let category = ($0 as? PluginHostServiceError)?.runtimeFailureCategory
            XCTAssertEqual(category, .storageLimitExceeded)
            XCTAssertEqual(category?.isCatchableByScript, true)
        }
        XCTAssertEqual(try storage.keys(of: keeper.manifest.id), [])
        XCTAssertFalse(PluginRuntimeFailureCategory.hostServiceFailed.isCatchableByScript)
        XCTAssertFalse(PluginRuntimeFailureCategory.capabilityDenied.isCatchableByScript)
    }

    func testWithoutAStoreTheServicesAreUnavailable() throws {
        broker = CapabilityCheckedHostServiceBroker(
            grantStore: PluginCapabilityGrantStore(), systemPermissionCheck: { _ in false },
            selectedTextProvider: { _ in "" }, clipboardWriter: { _ in }
        )
        let keeper = try makePackage("com.example.keeper")

        XCTAssertThrowsError(try request(.listStorageKeys, of: keeper)) {
            XCTAssertEqual($0 as? PluginHostServiceError, .unavailable("Plugin Storage"))
        }
    }
}
