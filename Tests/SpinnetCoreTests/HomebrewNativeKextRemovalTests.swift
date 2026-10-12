import XCTest
import SpinnetCore

final class HomebrewNativeKextRemovalTests: XCTestCase {
    func testLoadedStateRequiresExactTypedRowsAndNeverTreatsAnErrorAsAbsent() throws {
        let identifier = "com.vendor.owned"
        XCTAssertFalse(try HomebrewNativeKextRemoval.isLoaded(Data(), identifier: identifier))
        let row = " 253 0 0xfffffe0007c83520 0x9ff 0x9ff com.vendor.owned (6.0.0) 75C583C5-52A2-34D0-8146-AE5EB60C44AE <63 7 6 5 3>\n"
        XCTAssertTrue(try HomebrewNativeKextRemoval.isLoaded(Data(row.utf8), identifier: identifier))
        XCTAssertThrowsError(try HomebrewNativeKextRemoval.isLoaded(Data(row.replacingOccurrences(of: identifier, with: identifier + ".other").utf8), identifier: identifier))
        XCTAssertThrowsError(try HomebrewNativeKextRemoval.isLoaded(Data("Error: Operation not permitted\n".utf8), identifier: identifier))
        XCTAssertThrowsError(try HomebrewNativeKextRemoval.isLoaded(Data([0xff]), identifier: identifier))
        XCTAssertThrowsError(try HomebrewNativeKextRemoval.isLoaded(Data((row + row).utf8), identifier: identifier))
    }
    func testKernelIdentifiersNeverGrantAppleWildcardOrOptionAuthority() throws {
        XCTAssertTrue(HomebrewNativeKextRemoval.validIdentifier("com.vendor.driver"))
        for value in ["com.apple.driver", "COM.APPLE.driver", "com.vendor.*", "--no-authorization", "com.vendor/driver", "a"] {
            XCTAssertFalse(HomebrewNativeKextRemoval.validIdentifier(value))
        }
    }
    func testOwnedBundleInventoryBindsExactInfoAndRecursiveRemovalBeforeAnyCommand() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spinnet-kext-fixture-" + UUID().uuidString)
        try NativeFileQuarantine.makePrivateDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("Owned.kext/Contents")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let info = bundle.appendingPathComponent("Info.plist")
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.vendor.owned"], format: .xml, options: 0).write(to: info)
        let context = try HomebrewPathManifest.Context(home: root, prefix: root.appendingPathComponent("prefix"), appDirectory: root.appendingPathComponent("apps"))
        let request = HomebrewNativeKextRemoval.Request(identifiers: ["com.vendor.owned"], context: context, deadline: Date().addingTimeInterval(5))
        let result = try HomebrewNativeKextRemoval.inventoryInOwnedFixture(request, root: root)
        XCTAssertEqual(result.matches.map(\.identifier), ["com.vendor.owned"])
        XCTAssertEqual(result.matches.map(\.path), [root.appendingPathComponent("Owned.kext").path])
        XCTAssertEqual(result.manifest?.entries.filter { !$0.snapshot.directory }.count, 1)
        try result.validateSeal()
        try FileManager.default.removeItem(at: info)
        XCTAssertThrowsError(try HomebrewNativeKextRemoval.inventoryInOwnedFixture(request, root: root))
    }
}
