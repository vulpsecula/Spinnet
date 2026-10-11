import XCTest
import SpinnetCore

final class HomebrewReceiptOwnershipTests: XCTestCase {
    func testNativeReceiptReaderCannotExecuteMutationCommands() throws {
        XCTAssertThrowsError(try HomebrewReadProfile.executeNativeReceipt(["--forget", "org.example.pkg"], deadline: Date().addingTimeInterval(1)))
    }
    func testCompleteNativeReceiptInventoryFindsSharedOwnerWithoutFileInfoIndex() throws {
        let records: [String: [String: Any]] = [
            "org.example.first": ["pkgid": "org.example.first", "volume": "/", "install-location": "Applications", "paths": ["Example.app/Contents/tool": [:]]],
            "org.example.second": ["pkgid": "org.example.second", "volume": "/", "install-location": "Applications", "paths": ["Example.app/Contents/tool": [:], "Other.app": [:]]]
        ]
        let index = try HomebrewReceiptOwnership.capture(selected: ["org.example.first"], deadline: Date().addingTimeInterval(1)) { arguments, _ in
            if arguments == ["--pkgs"] { return Data("org.example.first\norg.example.second\n".utf8) }
            let id = arguments.last!
            if arguments.first == "--files" { return Data((records[id]!["paths"] as! [String: Any]).keys.sorted().joined(separator: "\n").utf8) }
            let value = arguments.first == "--pkg-info-plist" ? records[id]!.filter { $0.key != "paths" } : records[id]!
            return try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
        }
        XCTAssertEqual(index.owners["/Applications/Example.app/Contents/tool"], ["org.example.first", "org.example.second"])
        XCTAssertNil(index.owners["/Applications/Other.app"])
    }
    func testIncompleteNativeInventoryCannotAssertExclusiveOwnership() throws {
        XCTAssertThrowsError(try HomebrewReceiptOwnership.capture(selected: ["org.example.first"], deadline: Date().addingTimeInterval(1)) { _, _ in Data() })
    }
    func testAggregateMetadataBudgetRefusesBeforeRetainingTheNextSelectedExport() throws {
        let id = "org.example.first"
        let record: [String: Any] = ["pkgid": id, "volume": "/", "install-location": "Applications", "paths": ["Example.app": [:]], "padding": String(repeating: "x", count: 2048)]
        let bytes = try PropertyListSerialization.data(fromPropertyList: record, format: .xml, options: 0)
        XCTAssertThrowsError(try HomebrewReceiptOwnership.capture(selected: [id], deadline: Date().addingTimeInterval(1), maximumMetadataBytes: 1024) { arguments, _ in
            arguments == ["--pkgs"] ? Data((id + "\n").utf8) : bytes
        }) { XCTAssertEqual($0 as? PluginHostServiceError, .tool(.outputTooLarge)) }
    }
}
