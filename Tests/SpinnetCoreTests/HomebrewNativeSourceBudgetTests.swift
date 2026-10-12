import XCTest
import CryptoKit
import Darwin
import SpinnetCore

final class HomebrewNativeSourceBudgetTests: XCTestCase {
    func testOuterPackageAndPayloadEachFitButCombinedExpansionRefuses() throws {
        try fixture { package, payload in
            var packageProbe = try HomebrewNativeSourceBudget(), payloadProbe = try HomebrewNativeSourceBudget()
            try packageProbe.consume(package, deadline: Date().addingTimeInterval(5))
            try payloadProbe.consume(payload, deadline: Date().addingTimeInterval(5))
            let limit = packageProbe.usedBytes + payloadProbe.usedBytes - 1
            XCTAssertGreaterThan(limit, packageProbe.usedBytes); XCTAssertGreaterThan(limit, payloadProbe.usedBytes)
            var budget = try HomebrewNativeSourceBudget(maximumBytes: limit)
            try budget.consume(package, deadline: Date().addingTimeInterval(5))
            XCTAssertThrowsError(try budget.consume(payload, deadline: Date().addingTimeInterval(5))) {
                XCTAssertEqual($0 as? PluginHostServiceError, .tool(.outputTooLarge))
            }
            XCTAssertEqual(budget.usedBytes, packageProbe.usedBytes, "Refused layer never resets/advances the aggregate ledger")
        }
    }
    func testAggregateEntriesStopAndChangedSealedTreeRefuse() throws {
        try fixture { package, payload in
            var first = try HomebrewNativeSourceBudget(), second = try HomebrewNativeSourceBudget()
            try first.consume(package, deadline: Date().addingTimeInterval(5)); try second.consume(payload, deadline: Date().addingTimeInterval(5))
            var budget = try HomebrewNativeSourceBudget(maximumEntries: first.usedEntries + second.usedEntries - 1)
            try budget.consume(package, deadline: Date().addingTimeInterval(5))
            XCTAssertThrowsError(try budget.consume(payload, deadline: Date().addingTimeInterval(5))) {
                XCTAssertEqual($0 as? PluginHostServiceError, .tool(.outputTooLarge))
            }
            var stopped = try HomebrewNativeSourceBudget()
            XCTAssertThrowsError(try stopped.consume(package, deadline: Date().addingTimeInterval(5), isCancelled: { true })) {
                XCTAssertEqual($0 as? PluginHostServiceError, .tool(.planChanged))
            }
            XCTAssertEqual(stopped.usedBytes, 0)
            try Data("unreviewed extra resource".utf8).write(to: payload.selectedURL.appendingPathComponent("extra"))
            XCTAssertThrowsError(try stopped.consume(payload, deadline: Date().addingTimeInterval(5))) {
                XCTAssertEqual($0 as? PluginHostServiceError, .tool(.planChanged))
            }
            XCTAssertEqual(stopped.usedBytes, 0)
        }
    }
    private func fixture(_ action: (HomebrewArchiveStaging.SealedTree, HomebrewArchiveStaging.SealedTree) throws -> Void) throws {
        XCTAssertNotEqual(getuid(), 0, "Owned fixture accounting, never Root or publisher authority")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try NativeFileQuarantine.makePrivateDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "vendor-origin", withExtension: "pkg", subdirectory: "ArchiveFixtures")))
        let file = root.appendingPathComponent("fixture.pkg")
        try source.write(to: file); XCTAssertEqual(chmod(file.path, 0o600), 0)
        let decoder = HomebrewArchiveStaging.DecoderConfiguration(bootstrap: Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("SpinnetArchiveBootstrap"), uid: getuid(), gid: getgid())
        let checksum = SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
        let package = try HomebrewArchiveStaging.extractVerified(file, checksum: checksum, into: root.appendingPathComponent("package"), selected: ".", decoder: decoder)
        let payload = try HomebrewNativeVendorOrigin.extractPackagePayload(package, into: root.appendingPathComponent("payload"), decoder: decoder, deadline: Date().addingTimeInterval(5))
        try action(package, payload.tree)
    }
}
