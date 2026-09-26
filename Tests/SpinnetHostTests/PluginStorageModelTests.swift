import Foundation
import XCTest
@testable import SpinnetHost
import SpinnetCore

/// The Stored Data section of a Plugin's Plugin Settings sheet in the
/// Library: how much the Plugin keeps, and Clear Stored Data.
final class PluginStorageModelTests: XCTestCase {
    private let pluginID = PluginID("com.example.counter")

    private func makeStorage() -> PluginStorage {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginStorageModel-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return PluginStorage(directory: directory)
    }

    func testItShowsHowMuchThePluginKeeps() throws {
        let storage = makeStorage()
        let model = PluginStorageModel(pluginID: pluginID, storage: storage)
        XCTAssertEqual(model.usage, 0)
        XCTAssertEqual(model.usageDescription, "Nothing stored")
        XCTAssertFalse(model.canClear)

        try storage.setValue(.string(String(repeating: "x", count: 4000)), forKey: "big", of: pluginID)
        model.refresh()

        XCTAssertEqual(model.usage, storage.usage(of: pluginID))
        XCTAssertEqual(model.usageDescription,
                       ByteCountFormatter.string(fromByteCount: Int64(model.usage), countStyle: .file))
        XCTAssertTrue(model.canClear)
    }

    func testClearStoredDataEmptiesTheStoreAndOnlyThisPluginsStore() throws {
        let storage = makeStorage()
        let other = PluginID("com.example.other")
        try storage.setValue(.number(3), forKey: "runs", of: pluginID)
        try storage.setValue(.number(1), forKey: "runs", of: other)
        let model = PluginStorageModel(pluginID: pluginID, storage: storage)

        model.clear()

        XCTAssertEqual(model.usage, 0)
        XCTAssertNil(model.failure)
        XCTAssertEqual(try storage.keys(of: pluginID), [])
        XCTAssertEqual(try storage.keys(of: other), ["runs"])
    }
}
