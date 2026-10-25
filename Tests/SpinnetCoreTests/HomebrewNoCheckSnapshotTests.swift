import XCTest
@testable import SpinnetCore
import Darwin

final class HomebrewNoCheckSnapshotTests: XCTestCase {
    func testNoCheckConfirmationFreezesBytesAndReusesTheSamePublisherBoundSnapshot() throws {
        let metadata = try HomebrewSignedCatalogFixture.snapshot("4peaks")
        try withDirectory { root in
            let selected = try HomebrewNoCheckSnapshot.capture(snapshot: metadata, into: root, deadline: Date().addingTimeInterval(10), fetch: fixture(for: metadata))
            XCTAssertEqual(metadata.metadata["url"], .string(selected.sourceURL.absoluteString))
            XCTAssertEqual(try Data(contentsOf: selected.fileURL), Data("Host-owned fixture bytes".utf8))
            XCTAssertEqual(selected.byteCount, 24)
            XCTAssertEqual(selected.sha256, "4a37fa3a733f79c20210d05cc2a48de4e29d23eebffc7332bc49e38eb54e5962")
            let reused = try HomebrewNoCheckSnapshot.capture(snapshot: metadata, into: root, deadline: Date().addingTimeInterval(10), expectedSHA256: selected.sha256, fetch: { _, _, _, _, _ in XCTFail("Confirmed snapshot must never re-fetch"); throw PluginHostServiceError.tool(.failed) })
            XCTAssertEqual(reused.sha256, selected.sha256)
            XCTAssertEqual(reused.fileURL, selected.fileURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: selected.fileURL.path)
            try Data("changed cache".utf8).write(to: selected.fileURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: selected.fileURL.path)
            XCTAssertThrowsError(try HomebrewNoCheckSnapshot.capture(snapshot: metadata, into: root, deadline: Date().addingTimeInterval(10), fetch: fixture(for: metadata))) {
                XCTAssertEqual($0 as? PluginHostServiceError, .tool(.planChanged))
            }
            let receiptURL = selected.fileURL.deletingPathExtension().appendingPathExtension("json")
            var receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as? [String: Any])
            receipt["sha256"] = "cbe4ec39bbf296559d5f61598ca3daca559edd2dbfda661d326438009e7bc550"
            receipt["byteCount"] = 13
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptURL.path)
            try JSONSerialization.data(withJSONObject: receipt).write(to: receiptURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: receiptURL.path)
            XCTAssertThrowsError(try HomebrewNoCheckSnapshot.capture(snapshot: metadata, into: root, deadline: Date().addingTimeInterval(10), expectedSHA256: selected.sha256, fetch: fixture(for: metadata))) {
                XCTAssertEqual($0 as? PluginHostServiceError, .tool(.planChanged))
            }
            try FileManager.default.removeItem(at: receiptURL)
            XCTAssertThrowsError(try HomebrewNoCheckSnapshot.capture(snapshot: metadata, into: root, deadline: Date().addingTimeInterval(10), expectedSHA256: selected.sha256, fetch: { _, _, _, _, _ in XCTFail("Missing confirmed evidence must never re-fetch"); throw PluginHostServiceError.tool(.failed) })) {
                XCTAssertEqual($0 as? PluginHostServiceError, .tool(.planChanged))
            }
        }
    }
    func testCheckedPublisherArtifactNeverEntersTheNoCheckDownloader() throws {
        let metadata = try HomebrewSignedCatalogFixture.snapshot("libreoffice-language-pack", languages: ["zh-CN"])
        try withDirectory { root in
            XCTAssertThrowsError(try HomebrewNoCheckSnapshot.capture(snapshot: metadata, into: root, deadline: Date().addingTimeInterval(10), fetch: { _, _, _, _, _ in XCTFail("Checked artifacts cannot use no_check capture"); throw PluginHostServiceError.tool(.failed) })) {
                XCTAssertEqual($0 as? PluginHostServiceError, .tool(.sourceNotAllowed))
            }
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        }
    }
    func testCancellationAndExpiredDeadlineCannotLeaveAReusablePartialSnapshot() throws {
        let metadata = try HomebrewSignedCatalogFixture.snapshot("4peaks")
        try withDirectory { root in
            XCTAssertThrowsError(try HomebrewNoCheckSnapshot.capture(snapshot: metadata, into: root, deadline: Date().addingTimeInterval(-1), fetch: fixture(for: metadata))) {
                XCTAssertEqual($0 as? PluginHostServiceError, .tool(.timedOut))
            }
            XCTAssertThrowsError(try HomebrewNoCheckSnapshot.capture(snapshot: metadata, into: root, deadline: Date().addingTimeInterval(10), isCancelled: { true }, fetch: fixture(for: metadata))) {
                XCTAssertEqual($0 as? PluginHostServiceError, .tool(.planChanged))
            }
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        }
    }
    func testExpandedDownloadBudgetAndIncompleteFetchCannotBecomeConfirmationEvidence() throws {
        let metadata = try HomebrewSignedCatalogFixture.snapshot("4peaks")
        try withDirectory { root in
            XCTAssertThrowsError(try HomebrewNoCheckSnapshot.capture(snapshot: metadata, into: root, deadline: Date().addingTimeInterval(10), fetch: { _, fd, limit, _, _ in
                // Sparse fixture proves the byte bound without downloading or
                // allocating eight GiB of app data.
                XCTAssertEqual(ftruncate(fd, limit + 1), 0)
            })) {
                XCTAssertEqual($0 as? PluginHostServiceError, .tool(.outputTooLarge))
            }
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
            XCTAssertThrowsError(try HomebrewNoCheckSnapshot.capture(snapshot: metadata, into: root, deadline: Date().addingTimeInterval(10), fetch: { source, fd, limit, deadline, stop in
                try self.fixture(for: metadata)(source, fd, limit, deadline, stop)
                throw PluginHostServiceError.tool(.timedOut)
            })) {
                XCTAssertEqual($0 as? PluginHostServiceError, .tool(.timedOut))
            }
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        }
    }
    func testAReadableHostStageCannotReceivePrivateConfirmationBytes() throws {
        let metadata = try HomebrewSignedCatalogFixture.snapshot("4peaks")
        try withDirectory { root in
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            XCTAssertThrowsError(try HomebrewNoCheckSnapshot.capture(snapshot: metadata, into: root, deadline: Date().addingTimeInterval(10), fetch: { _, _, _, _, _ in XCTFail("Nonprivate stage must fail before download"); throw PluginHostServiceError.tool(.failed) })) {
                XCTAssertEqual($0 as? PluginHostServiceError, .tool(.planChanged))
            }
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        }
    }
    private func fixture(for snapshot: HomebrewPrivilegeMetadata.Snapshot) -> HomebrewNoCheckSnapshot.Fetch {
        let expected = snapshot.metadata["url"]
        return { source, fd, _, _, _ in
            let data = Data("Host-owned fixture bytes".utf8)
            XCTAssertEqual(expected, .string(source.absoluteString))
            XCTAssertEqual(data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }, data.count)
        }
    }
    private func withDirectory(_ action: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try action(root)
    }
}
