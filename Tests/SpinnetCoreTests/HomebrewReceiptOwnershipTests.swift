import XCTest
import SpinnetCore
@testable import SpinnetReviewedTools

final class HomebrewReceiptOwnershipTests: XCTestCase {
    func testSameIdentifierOwnerChangesDuringCaptureCannotBecomeCompleteOwnershipProof() throws {
        let records: [String: [String: Any]] = [
            "org.example.first": ["pkgid": "org.example.first", "volume": "/", "install-location": "Applications", "paths": ["Example.app/tool": [:]]],
            "org.example.second": ["pkgid": "org.example.second", "volume": "/", "install-location": "Applications", "paths": ["Other.app/tool": [:]]]
        ]
        var fileReads = 0
        XCTAssertThrowsError(try HomebrewReceiptOwnership.capture(selected: ["org.example.first"], deadline: Date().addingTimeInterval(3)) { arguments, _ in
            if arguments == ["--pkgs"] { return Data("org.example.first\norg.example.second\n".utf8) }
            let record = records[arguments.last!]!
            if arguments.first == "--files" {
                fileReads += 1
                return Data((fileReads == 1 ? "Other.app/tool\n" : "Example.app/tool\n").utf8)
            }
            return try PropertyListSerialization.data(fromPropertyList: arguments.first == "--pkg-info-plist" ? record.filter { $0.key != "paths" } : record, format: .xml, options: 0)
        }) { error in XCTAssertEqual(error as? PluginHostServiceError, .tool(.planChanged)) }
    }
    func testCancelledNativeInventoryNeverReturnsOwnershipAuthority() throws {
        XCTAssertThrowsError(try HomebrewReceiptOwnership.capture(selected: ["org.example.first"], deadline: Date().addingTimeInterval(3), isCancelled: { true })) {
            XCTAssertEqual($0 as? PluginHostServiceError, .tool(.planChanged))
        }
    }
    func testMatchingNativeWorkerEnforcesAggregateMetadataBudget() throws {
        let began = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try HomebrewReceiptOwnership.capture(selected: ["org.example.first"], deadline: Date().addingTimeInterval(3), maximumMetadataBytes: 1)) {
            XCTAssertEqual($0 as? PluginHostServiceError, .tool(.outputTooLarge))
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 3.5)
    }
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
    func testCompleteInventoryDetectsDescendantAliasFromDisjointInstallRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Applications/Example.app")
        let library = root.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try Data("shared payload".utf8).write(to: app.appendingPathComponent("Contents/tool"))
        try FileManager.default.createSymbolicLink(at: library.appendingPathComponent("ExampleAlias.app"), withDestinationURL: app)
        let records: [String: [String: Any]] = [
            "org.example.first": ["pkgid": "org.example.first", "volume": "/", "install-location": root.appendingPathComponent("Applications").path, "paths": ["Example.app/Contents/tool": [:]]],
            "org.example.second": ["pkgid": "org.example.second", "volume": "/", "install-location": library.path, "paths": ["ExampleAlias.app/Contents/tool": [:]]]
        ]
        let index = try HomebrewReceiptOwnership.capture(selected: ["org.example.first"], deadline: Date().addingTimeInterval(3)) { arguments, _ in
            if arguments == ["--pkgs"] { return Data("org.example.first\norg.example.second\n".utf8) }
            let record = records[arguments.last!]!
            if arguments.first == "--files" { return Data((record["paths"] as! [String: Any]).keys.sorted().joined(separator: "\n").utf8) }
            return try PropertyListSerialization.data(fromPropertyList: arguments.first == "--pkg-info-plist" ? record.filter { $0.key != "paths" } : record, format: .xml, options: 0)
        }
        XCTAssertEqual(index.owners[app.appendingPathComponent("Contents/tool").path], ["org.example.first", "org.example.second"])
    }
    func testOrdinaryNativeAppDirectoriesRetainCompleteSharedOwnership() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Applications/Example.app")
        let other = root.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: other.appendingPathComponent("Alias.app"), withDestinationURL: app)
        let records: [String: [String: Any]] = [
            "org.example.first": ["pkgid": "org.example.first", "volume": "/", "install-location": app.deletingLastPathComponent().path, "paths": ["Example.app": [:], "Example.app/Contents": [:]]],
            "org.example.second": ["pkgid": "org.example.second", "volume": "/", "install-location": other.path, "paths": ["Alias.app/Contents": [:]]]
        ]
        let index = try HomebrewReceiptOwnership.capture(selected: ["org.example.first"], deadline: Date().addingTimeInterval(3)) { arguments, _ in
            if arguments == ["--pkgs"] { return Data("org.example.first\norg.example.second\n".utf8) }
            let record = records[arguments.last!]!
            if arguments.first == "--files" { return Data((record["paths"] as! [String: Any]).keys.sorted().joined(separator: "\n").utf8) }
            return try PropertyListSerialization.data(fromPropertyList: arguments.first == "--pkg-info-plist" ? record.filter { $0.key != "paths" } : record, format: .xml, options: 0)
        }
        XCTAssertEqual(index.owners[app.path], ["org.example.first"])
        XCTAssertEqual(index.owners[app.appendingPathComponent("Contents").path], ["org.example.first", "org.example.second"])
    }
    func testPhysicalAliasIndexCannotAuthorizeAMultiplyLinkedSelectedPayload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("shared payload".utf8).write(to: root.appendingPathComponent("first"))
        try FileManager.default.linkItem(at: root.appendingPathComponent("first"), to: root.appendingPathComponent("different-leaf"))
        let id = "org.example.first"
        let record: [String: Any] = ["pkgid": id, "volume": "/", "install-location": root.path, "paths": ["first": [:]]]
        XCTAssertThrowsError(try HomebrewReceiptOwnership.capture(selected: [id], deadline: Date().addingTimeInterval(3)) { arguments, _ in
            if arguments == ["--pkgs"] { return Data((id + "\n").utf8) }
            return try PropertyListSerialization.data(fromPropertyList: arguments.first == "--pkg-info-plist" ? record.filter { $0.key != "paths" } : record, format: .xml, options: 0)
        })
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

extension HomebrewReceiptOwnershipTests {
    func testFullDatabaseStillMustMatchAfterEveryApprovedReceiptHasBeenForgotten() throws {
        var ids = ["org.example.first", "org.example.second"], changed = false
        let read: ([String], Date) throws -> Data = { arguments, _ in
            if arguments == ["--pkgs"] { return Data((ids.joined(separator: "\n") + "\n").utf8) }
            let id = arguments.last!
            if arguments.first == "--files" { return Data((changed ? "Changed.app/tool\n" : "Other.app/tool\n").utf8) }
            return try PropertyListSerialization.data(fromPropertyList: ["pkgid": id, "volume": "/", "install-location": "Applications", "paths": ["MissingTest.app/tool": [:]]], format: .xml, options: 0)
        }
        let original = try HomebrewReceiptOwnership.capture(selected: ["org.example.first"], deadline: Date().addingTimeInterval(3), execute: read)
        ids = ["org.example.second"]
        let complete = try HomebrewReceiptOwnership.captureInNativeWorker(selected: [], deadline: Date().addingTimeInterval(3), execute: read)
        XCTAssertNoThrow(try HomebrewReceiptOwnership.validateLiveSources(reference: original, live: complete, forgotten: ["org.example.first"]))
        changed = true
        let drift = try HomebrewReceiptOwnership.captureInNativeWorker(selected: [], deadline: Date().addingTimeInterval(3), execute: read)
        XCTAssertThrowsError(try HomebrewReceiptOwnership.validateLiveSources(reference: original, live: drift, forgotten: ["org.example.first"]))
    }
}
