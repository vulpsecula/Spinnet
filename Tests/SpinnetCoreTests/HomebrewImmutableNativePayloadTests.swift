import XCTest
import SpinnetCore
import Darwin

final class HomebrewImmutableNativePayloadTests: XCTestCase {
    func testPayloadCopyRefusesRemainingEntryBudgetBeforeAddingAnotherEntry() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try NativeFileQuarantine.makePrivateDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try NativeFileQuarantine.makePrivateDirectory(source)
        try Data("a".utf8).write(to: source.appendingPathComponent("one"))
        try Data("b".utf8).write(to: source.appendingPathComponent("two"))
        let destination = root.appendingPathComponent("refused")
        XCTAssertThrowsError(try HomebrewNativePayloadCopy.copy(source, into: destination, deadline: Date().addingTimeInterval(2), maximumEntries: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
    func testPinnedHistoricalPublisherChecksumCannotBeReplacedByALocalSnapshotHash() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try NativeFileQuarantine.makePrivateDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try HomebrewSignedCaskCatalog.load(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/Homebrew/api/internal/packages.arm64_golden_gate.jws.json"), deadline: Date().addingTimeInterval(5))
        let file = root.appendingPathComponent("homebrew-source.jws.json")
        try catalog.envelope.write(to: file)
        let configuration = try HomebrewSignedCaskCatalog.Configuration(languages: [], home: URL(fileURLWithPath: NSHomeDirectory()), prefix: URL(fileURLWithPath: "/opt/homebrew"), appDirectory: URL(fileURLWithPath: "/Applications"))
        let proof = HomebrewPrivilegePlan.SourceProof(envelope: file, envelopeSHA256: catalog.catalog.envelopeSHA256, projectionSHA256: try catalog.catalog.projectionDigest("adobe-air", configuration: configuration), configuration: configuration)
        let stage = root.appendingPathComponent("payload")
        try NativeFileQuarantine.makePrivateDirectory(stage)
        XCTAssertThrowsError(try HomebrewNoCheckSnapshot.capturePinnedSource(proof: proof, name: "adobe-air", into: stage, deadline: Date().addingTimeInterval(5), fetch: { _, fd, _, _, _ in
            let bytes = Data("different local installer".utf8)
            XCTAssertEqual(bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }, bytes.count)
        }))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: stage.path), [])
    }
}
