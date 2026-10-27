import XCTest
import Darwin
import SpinnetCore
@testable import SpinnetReviewedTools

final class HomebrewNativeLaunchServiceExecutionTests: XCTestCase {
    func testOwnedInheritedChildStopKeepsIsolatedParentAliveAndOrphanOuterStopReaps() throws {
        try fixture("fixture.inherited-stop") { request, tools in
            let result = try HomebrewNativeLaunchServiceExecution.capture(request, toolsDirectory: tools)
            XCTAssertEqual(result.state, .completed); XCTAssertNil(result.response?.failure)
            XCTAssertEqual(result.response?.unavailable, "Owned parent survived identity-bound inherited child Stop")
            let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: tools.appendingPathComponent("inherited-child.json"))) as? [String: Int32])
            XCTAssertEqual(report["group"], report["parentGroup"]); XCTAssertEqual(report["group"], report["parent"])
            XCTAssertEqual(report["parentSurvived"], report["parent"]); XCTAssertEqual(report["childReaped"], 1)
            XCTAssertNotEqual(report["group"], getpgrp(), "Never share the test/Main App group")
        }
        try fixture("fixture.inherited-orphan", duration: 0.9) { request, tools in
            let result = try HomebrewNativeLaunchServiceExecution.capture(request, toolsDirectory: tools)
            XCTAssertEqual(result.state, .completed); XCTAssertEqual(result.response?.failure, .timedOut)
            let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: tools.appendingPathComponent("inherited-child.json"))) as? [String: Int32])
            XCTAssertEqual(report["group"], report["parent"])
            XCTAssertNil(HomebrewTaskProcess.startIdentity(try XCTUnwrap(report["pid"])))
            XCTAssertNil(HomebrewTaskProcess.startIdentity(result.process.processIdentifier))
        }
    }
    func testFixedReadOnlyInventoryStopBeforeSpawnAndBadOutputRefuseAuthority() throws {
        try fixture("fixture.malformed") { request, tools in
            var started = false
            XCTAssertThrowsError(try HomebrewNativeLaunchServiceExecution.capture(request, toolsDirectory: tools, isCancelled: { true }, willStart: { _ in started = true; return true }))
            XCTAssertFalse(started)
            let malformed = try HomebrewNativeLaunchServiceExecution.capture(request, toolsDirectory: tools)
            XCTAssertEqual(malformed.state, .completed); XCTAssertEqual(malformed.response?.failure, .failed); XCTAssertNil(malformed.response?.manifest)
            XCTAssertTrue(malformed.diagnostic?.contains("no valid inventory reply") == true)
            XCTAssertTrue(malformed.diagnostic?.contains("exit 0") == true)
        }
        try fixture("fixture.large", duration: 20) { request, tools in
            let result = try HomebrewNativeLaunchServiceExecution.capture(request, toolsDirectory: tools)
            XCTAssertEqual(result.state, .completed); XCTAssertEqual(result.response?.failure, .outputTooLarge); XCTAssertNil(result.response?.manifest)
        }
    }
    func testOwnedBlockedInventoryReturnsUnknownAndKeepsLaneUntilActualReap() throws {
        try fixture("fixture.block", duration: 0.5) { request, tools in
            let done = expectation(description: "Owned worker actually reaps")
            let result = try HomebrewNativeLaunchServiceExecution.capture(request, toolsDirectory: tools, stopGrace: 0, didReap: { _ in done.fulfill() })
            XCTAssertEqual(result.state, .unknown); XCTAssertNil(result.response)
            XCTAssertNotNil(HomebrewTaskProcess.startIdentity(result.process.processIdentifier))
            wait(for: [done], timeout: 3)
            XCTAssertNil(HomebrewTaskProcess.startIdentity(result.process.processIdentifier))
        }
    }
    func testOwnedFoundationLaunchChildSeparateGroupActuallyReapsAndRSSIsAggregate() throws {
        for mode in ["fixture.escape", "fixture.rss"] {
            try fixture(mode, duration: mode == "fixture.rss" ? 8 : 0.9) { request, tools in
                let result = try HomebrewNativeLaunchServiceExecution.capture(request, toolsDirectory: tools)
                XCTAssertEqual(result.state, .completed)
                XCTAssertEqual(result.response?.failure, mode == "fixture.rss" ? .outputTooLarge : .timedOut)
                let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: tools.appendingPathComponent("owned-child.json"))) as? [String: Int32])
                XCTAssertNotEqual(fields["group"], fields["parent"])
                XCTAssertNil(HomebrewTaskProcess.startIdentity(try XCTUnwrap(fields["pid"])))
                XCTAssertNil(HomebrewTaskProcess.startIdentity(result.process.processIdentifier))
            }
        }
    }
    private func fixture(_ pattern: String, duration: TimeInterval = 5,
        _ action: (HomebrewNativeLaunchServiceInventory.Request, URL) throws -> Void) throws {
        XCTAssertNotEqual(getuid(), 0, "Owned current-UID process fixture; never Root or service mutation acceptance")
        let root = URL(fileURLWithPath: "/private/tmp/spinnet-launch-execution-" + UUID().uuidString)
        try NativeFileQuarantine.makePrivateDirectory(root); defer { try? FileManager.default.removeItem(at: root) }
        let tools = root.appendingPathComponent("tools"); try NativeFileQuarantine.makePrivateDirectory(tools)
        let source = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("SpinnetLaunchServiceFixture")
        try FileManager.default.copyItem(at: source, to: tools.appendingPathComponent("SpinnetLaunchServiceInventory"))
        let context = try HomebrewNativeLaunchServices.Context(uid: getuid(), home: URL(fileURLWithPath: NSHomeDirectory()))
        let request = HomebrewNativeLaunchServiceInventory.Request(context: context, declarations: [try .init(pattern)], deadline: Date().addingTimeInterval(duration))
        try action(request, tools)
    }
}
