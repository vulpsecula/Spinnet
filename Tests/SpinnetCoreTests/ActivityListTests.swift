import XCTest
import SpinnetCore
import SpinnetPluginTestKit

final class ActivityListTests: XCTestCase {
    func testDurationReadShowsRemainingSecondsAfterOneSecondWithoutHelper() throws {
        let recorded = RecordedKeepAwake()
        let owner = PluginID("com.example.clock")
        try recorded.effects.start(KeepAwakeRequest(mode: .duration(60)), owner: owner, pluginName: "Clock")
        recorded.advance(by: 1)
        XCTAssertEqual(recorded.activities.list(for: owner).first?.status, "59 seconds remaining")
    }

    func testWallClockChangesDoNotAlterMonotonicRemainingSeconds() throws {
        let registry = HostActivities(), power = RecordedPowerAssertions()
        var wall = Date(timeIntervalSince1970: 1_000), uptime: TimeInterval = 100
        let effects = HostKeepAwake(activities: registry, power: power, now: { wall }, monotonicNow: { uptime }, schedule: { _, _ in {} })
        try effects.start(KeepAwakeRequest(mode: .duration(60)), owner: PluginID("clock"), pluginName: "Clock")
        wall = wall.addingTimeInterval(10_000); uptime += 1
        XCTAssertEqual(registry.list().first?.status, "59 seconds remaining")
        XCTAssertEqual(registry.list().first?.expiresAt, Date(timeIntervalSince1970: 1_060))
        wall = wall.addingTimeInterval(-20_000); uptime += 1
        XCTAssertEqual(registry.list().first?.status, "58 seconds remaining")
        XCTAssertEqual(power.count, 2)
    }

    func testRecordingDestructionReleasesAnActiveDurationWithoutReadingItsDestroyedClock() throws {
        let power: RecordedPowerAssertions
        do {
            let recorded = RecordedKeepAwake()
            power = recorded.power
            try recorded.effects.start(KeepAwakeRequest(mode: .duration(60)), owner: PluginID("clock"), pluginName: "Clock")
            XCTAssertEqual(power.count, 2)
        }
        XCTAssertEqual(power.count, 0)
    }

    func testPublicActivityListComponentNeedsNoPluginSuppliedItemsOrOwner() throws {
        let page: JSONValue = .object(["id": .string("activities"), "title": .string("Active Effects"), "content": .array([
            .object(["kind": .string("activity_list"), "id": .string("held"), "empty_text": .string("No active effects")])
        ])])
        XCTAssertNoThrow(try PluginPage(parsing: page, permits: { PluginInterfaceContracts.levelTwoMembers.contains($0) }))
    }
    func testActivityListCannotNameAnotherOwnerOrPluginSuppliedRows() throws {
        for extra in ["owner", "items", "actions"] {
            let page: JSONValue = .object(["id": .string("p"), "title": .string("Activities"), "content": .array([
                .object(["kind": .string("activity_list"), "id": .string("held"), extra: .string("foreign")])])])
            XCTAssertThrowsError(try PluginPage(parsing: page, permits: { PluginInterfaceContracts.levelTwoMembers.contains($0) }))
        }
    }
}
