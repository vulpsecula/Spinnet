import XCTest
import Carbon
import SpinnetCore
@testable import SpinnetHost

final class SpotifyControlAdapterTests: XCTestCase {
    private func request(_ operation: String, _ arguments: [String: JSONValue] = [:]) throws -> AppleEventRequest {
        try XCTUnwrap(ReviewedAppInterface.interface(for: SpotifyPlayback.bundleID)).request(operation: operation,
            arguments: arguments, candidateContracts: [SpotifyControls.declaration])
    }

    func testVolumeAdjustmentUsesReviewedPropertyClampsAndReturnsObservedVolume() throws {
        var events: [NSAppleEventDescriptor] = []
        var answers = [NSAppleEventDescriptor(int32: 98), NSAppleEventDescriptor.null(), NSAppleEventDescriptor(int32: 100)]
        let adapter = SpotifyControlAppleEvents(target: NSAppleEventDescriptor(processIdentifier: 123), send: { event, timeout in
            XCTAssertGreaterThan(timeout, 0); XCTAssertLessThanOrEqual(timeout, 3)
            events.append(event); return answers.removeFirst()
        })
        XCTAssertEqual(try adapter.perform(request("adjust_volume", ["delta": .number(5)])), .object(["volume": .number(100)]))
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[1].attributeDescriptor(forKeyword: AEKeyword(keyEventIDAttr))?.typeCodeValue, AEEventID(kAESetData))
        XCTAssertEqual(events[1].paramDescriptor(forKeyword: AEKeyword(keyAEData))?.int32Value, 100)
        XCTAssertEqual(events[1].paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.paramDescriptor(forKeyword: AEKeyword(keyAEKeyData))?.typeCodeValue, OSType(0x70566f6c))
    }
}

extension SpotifyControlAdapterTests {
    func testNextAcknowledgementAfterDeadlineIsUnconfirmedAndNeverRetried() throws {
        var clock = 0.0
        var nextCount = 0
        let adapter = SpotifyControlAppleEvents(target: NSAppleEventDescriptor(processIdentifier: 123), send: { event, _ in
            if event.attributeDescriptor(forKeyword: AEKeyword(keyEventIDAttr))?.typeCodeValue == 0x4e657874 {
                nextCount += 1; clock = 3.1; return .null()
            }
            let property = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.paramDescriptor(forKeyword: AEKeyword(keyAEKeyData))?.typeCodeValue
            return property == 0x70506c53 ? NSAppleEventDescriptor(enumCode: 0x6b505350) : NSAppleEventDescriptor(string: "spotify:track:before")
        }, now: { clock })
        XCTAssertEqual(try adapter.perform(request("next_checked")), .object(["outcome": .string("unconfirmed")]))
        XCTAssertEqual(nextCount, 1)
    }
}

extension SpotifyControlAdapterTests {
    func testNextBoundariesNeverInventQueueStateOrSendAnotherNext() throws {
        let cases: [(OSType, NSAppleEventDescriptor, NSAppleEventDescriptor, String, Int)] = [
            (0x6b505353, .null(), .null(), "stopped", 0),
            (0x6b505350, .null(), .null(), "no_current_track", 0),
            (0x6b505370, .init(string: "a"), .init(string: "b"), "changed", 1),
            (0x6b505350, .init(string: "a"), .init(string: "a"), "unconfirmed", 1),
            (0x6b505350, .init(string: "a"), .null(), "unconfirmed", 1),
            (0x6b505350, .init(string: "a"), .init(int32: 7), "unconfirmed", 1)
        ]
        for (state, before, after, outcome, expectedNext) in cases {
            var nextCount = 0
            var reads = 0
            let adapter = SpotifyControlAppleEvents(target: NSAppleEventDescriptor(processIdentifier: 123), send: { event, _ in
                if event.attributeDescriptor(forKeyword: AEKeyword(keyEventIDAttr))?.typeCodeValue == 0x4e657874 {
                    nextCount += 1; return .null()
                }
                let property = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.paramDescriptor(forKeyword: AEKeyword(keyAEKeyData))?.typeCodeValue
                if property == 0x70506c53 { return .init(enumCode: state) }
                reads += 1; return reads == 1 ? before : after
            })
            XCTAssertEqual(try adapter.perform(request("next_checked")), .object(["outcome": .string(outcome)]), outcome)
            XCTAssertEqual(nextCount, expectedNext, outcome)
        }
    }

    func testNextPropagatesKnownErrorsAndOnlyPostMutationReadTimeoutIsUnconfirmed() throws {
        for failureAt in [0, 1, 2, 3] {
            var calls = 0
            let adapter = SpotifyControlAppleEvents(target: NSAppleEventDescriptor(processIdentifier: 123), send: { _, _ in
                defer { calls += 1 }
                if calls == failureAt { throw NSError(domain: NSOSStatusErrorDomain, code: -1712) }
                return calls == 0 ? .init(enumCode: 0x6b505350) : .init(string: "a")
            })
            if failureAt >= 2 {
                XCTAssertEqual(try adapter.perform(request("next_checked")), .object(["outcome": .string("unconfirmed")]))
            } else { XCTAssertThrowsError(try adapter.perform(request("next_checked"))) }
        }
        let denied = SpotifyControlAppleEvents(target: NSAppleEventDescriptor(processIdentifier: 123), send: { _, _ in
            throw NSError(domain: NSOSStatusErrorDomain, code: -1743)
        })
        XCTAssertThrowsError(try denied.perform(request("next_checked"))) { XCTAssertEqual(($0 as NSError).code, -1743) }
    }

    func testSharedDeadlinePreventsFurtherExternalCalls() throws {
        var clock = 0.0
        var budgets: [Double] = []
        let adapter = SpotifyControlAppleEvents(target: NSAppleEventDescriptor(processIdentifier: 123), send: { _, timeout in
            budgets.append(timeout); clock += 1.6; return .init(int32: 50)
        }, now: { clock })
        XCTAssertThrowsError(try adapter.perform(request("adjust_volume", ["delta": .number(5)])))
        XCTAssertEqual(budgets.count, 2)
        XCTAssertEqual(budgets[0], 3, accuracy: 0.001)
        XCTAssertEqual(budgets[1], 1.4, accuracy: 0.001)
    }
}
