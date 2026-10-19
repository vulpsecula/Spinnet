import XCTest
@testable import SpinnetCore

final class HomebrewBackgroundUpdateTests: XCTestCase {
    func testMatchingLoadedHelperNeedsNoRestartEvenDuringWork() throws {
        XCTAssertFalse(try HomebrewBackgroundUpdate.needsRestart(loadedRevision: "same", expectedRevision: "same", hasWork: true))
        var requests = 0
        try HomebrewBackgroundUpdate.refresh(revision: "same", request: { requests += 1; return $0 }, wait: { XCTFail() })
        XCTAssertEqual(requests, 1)
    }
    func testChangedHelperCanRestartOnlyWithAnIdleRootLane() throws {
        XCTAssertTrue(try HomebrewBackgroundUpdate.needsRestart(loadedRevision: "old", expectedRevision: "new", hasWork: false))
        XCTAssertThrowsError(try HomebrewBackgroundUpdate.needsRestart(loadedRevision: "old", expectedRevision: "new", hasWork: true))
    }
    func testRestartAcknowledgementAllowsOnlyTheBriefConnectionHandoff() throws {
        var requests = 0, waits = 0
        try HomebrewBackgroundUpdate.refresh(revision: "new", request: { expected in
            requests += 1
            if requests == 1 { return "restarting" }
            if requests == 2 { throw PluginHostServiceError.tool(.failed) }
            return expected
        }, wait: { waits += 1 })
        XCTAssertEqual(requests, 3); XCTAssertEqual(waits, 2)
    }
    func testUnprovenBusyOrLegacyReplyIsNotRetriedOrTreatedAsUpdated() {
        var calls = 0
        XCTAssertThrowsError(try HomebrewBackgroundUpdate.refresh(revision: "new", request: { _ in
            calls += 1; throw PluginHostServiceError.tool(.busy)
        }, wait: { XCTFail() }))
        XCTAssertEqual(calls, 1)
        XCTAssertThrowsError(try HomebrewBackgroundUpdate.refresh(revision: "new", request: { _ in "old" }, wait: { XCTFail() }))
    }
    func testRepeatedRestartRepliesHaveABoundAndNeverBecomeSuccess() {
        var requests = 0
        XCTAssertThrowsError(try HomebrewBackgroundUpdate.refresh(revision: "new", request: { _ in requests += 1; return "restarting" }, wait: {}))
        XCTAssertEqual(requests, 60)
    }
}
