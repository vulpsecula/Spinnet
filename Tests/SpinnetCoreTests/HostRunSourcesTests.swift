import Foundation
import XCTest
@testable import SpinnetCore

final class HostRunSourcesTests: XCTestCase {
    private func sourcePage() throws -> PluginPage {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"id":"weather","title":"Weather","sources":[{"id":"remote","perform":"http.request","input":{"method":"GET","url":"https://example.com/weather"}}],"content":[{"kind":"text","id":"temperature","text":"Waiting","bind":{"source":"remote","pointer":"/json/temperature","format":"decimal"}}]}"#.utf8))
        return try PluginPage(parsing: value, permits: CollectionsFixtures.permits)
    }
    func testLevelTwoPageAcceptsABoundHTTPSResult() throws {
        _ = try sourcePage()
    }
    func testHiddenPageCancelsTheSampleAndDiscardsItsLateResult() throws {
        let page = try sourcePage()
        let action = try ActionConfiguration(id: ActionID("view"), pluginID: PluginID("com.example.sources"), command: CommandDeclaration(id: CommandID("example.view"), title: "View", execution: .javascript, script: "view.js"), input: .null)
        var work: [() -> Void] = []
        var cancellation: HostFetchedSections.Cancellation?
        let adapter = HostSourceAdapter(deadline: 15, authorize: { _, _ in }, sample: { _, _, token in
            cancellation = token
            return .object(["json": .object(["temperature": .number(24.5)])])
        })
        let engine = HostRunSources(adapters: ["http.request": adapter], now: { 0 }, schedule: { _, _ in }, background: { work.append($0) }, executor: { $0() })
        try engine.present(page, for: action)
        engine.setVisible(true, pluginID: action.pluginID)
        XCTAssertEqual(work.count, 1)
        engine.setVisible(false, pluginID: action.pluginID)
        work.removeFirst()()
        XCTAssertNil(cancellation, "Cancelled queued work must never enter the adapter")
        XCTAssertEqual(engine.shown(component: "temperature", pluginID: action.pluginID)?.text, "Waiting")
    }

    func testEqualDefinitionKeepsInflightReadAndSecretChangeDropsIt() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"id":"weather","title":"Weather","sources":[{"id":"remote","perform":"http.request","input":{"method":"GET","url":"https://example.com/weather","credential_uses":[{"reference":"key","header":"Authorization","template":"Bearer {credential}"}]}}],"content":[{"kind":"text","id":"temperature","text":"Waiting","bind":{"source":"remote","pointer":"/json/temperature","format":"decimal"}}]}"#.utf8))
        let page = try PluginPage(parsing: value, permits: CollectionsFixtures.permits)
        let action = try makeAction()
        var work: [() -> Void] = []
        var finishes: [() -> Void] = []
        let engine = HostRunSources(adapters: ["http.request": HostSourceAdapter(deadline: 15, authorize: { _, _ in }, sample: { _, _, _ in .object(["json": .object(["temperature": .number(24.5)])]) })], schedule: { _, _ in }, background: { work.append($0) }, executor: { finishes.append($0) })
        try engine.present(page, for: action)
        engine.setVisible(true, pluginID: action.pluginID)
        work.removeFirst()()
        try engine.present(page, for: action)
        XCTAssertTrue(work.isEmpty)
        engine.credentialsChanged(pluginID: action.pluginID)
        finishes.removeFirst()()
        XCTAssertEqual(engine.shown(component: "temperature", pluginID: action.pluginID)?.text, "Waiting", "An old credential's late result must never be shown")
    }

    func testOnceSourceDoesNotRepeatAfterSuccessfulHideShow() throws {
        let action = try makeAction()
        var samples = 0
        let engine = HostRunSources(adapters: ["http.request": HostSourceAdapter(deadline: 15, authorize: { _, _ in }, sample: { _, _, _ in samples += 1; return .object(["json": .object(["temperature": .number(24.5)])]) })], schedule: { _, _ in }, background: { $0() }, executor: { $0() })
        try engine.present(try sourcePage(), for: action)
        engine.setVisible(true, pluginID: action.pluginID)
        engine.setVisible(false, pluginID: action.pluginID)
        engine.setVisible(true, pluginID: action.pluginID)
        XCTAssertEqual(samples, 1)
        XCTAssertEqual(engine.shown(component: "temperature", pluginID: action.pluginID)?.isStale, true)
    }

    func testNonHTTPFixtureCoalescesChangedResultsAndUsesFixedDelay() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"id":"counter","title":"Counter","sources":[{"id":"local","perform":"fixture.counter","input":{},"every":1,"deliver":{"pointer":"/count"}}],"content":[{"kind":"text","id":"value","text":"Waiting","bind":{"source":"local","pointer":"/count","format":"integer"}}]}"#.utf8))
        let page = try PluginPage(parsing: value, permits: { _ in true }, sourceOperation: { $0 == "fixture.counter" })
        let action = try makeAction()
        var clock = 0.0
        var timers: [(Double, () -> Void)] = []
        var count = 0
        var events: [PluginViewEvent] = []
        let engine = HostRunSources(adapters: ["fixture.counter": HostSourceAdapter(minimumInterval: 1, deadline: 1, authorize: { _, _ in }, sample: { _, _, _ in count += 1; return .object(["count": .number(Double(count))]) })], now: { clock }, schedule: { timers.append((clock + $0, $1)) }, background: { $0() }, executor: { $0() })
        engine.onDelivery = { _, event, current in if current() { events.append(event) } }
        try engine.present(page, for: action); engine.setVisible(true, pluginID: action.pluginID)
        XCTAssertEqual(events.count, 1)
        while clock < 15 {
            timers.sort { $0.0 < $1.0 }; let next = timers.removeFirst(); clock = next.0; next.1()
        }
        XCTAssertEqual(events.count, 2)
        guard case .sourceDelivered(_, _, _, let result, _)? = events.last else { return XCTFail("Expected latest result") }
        XCTAssertEqual(result?.value(atPointer: "/count"), .number(15))
        engine.setVisible(false, pluginID: action.pluginID)
        let before = count
        for task in timers { task.1() }
        XCTAssertEqual(count, before)
    }

    private func makeAction() throws -> ActionConfiguration {
        try ActionConfiguration(id: ActionID("view"), pluginID: PluginID("com.example.sources"), command: CommandDeclaration(id: CommandID("example.view"), title: "View", execution: .javascript, script: "view.js"), input: .null)
    }

    func testAdapterFloorIsValidatedAndFloorHeldDeliveryWaitsWhileHidden() throws {
        func page(_ every: Double) throws -> PluginPage {
            let value: JSONValue = .object(["id": .string("counter"), "title": .string("Counter"), "sources": .array([
                .object(["id": .string("local"), "perform": .string("fixture.counter"), "input": .object([:]), "every": .number(every), "deliver": .object([:])])]),
                "content": .array([.object(["kind": .string("text"), "id": .string("value"), "text": .string("Waiting"), "bind": .object(["source": .string("local"), "pointer": .string("/count")])])])])
            return try PluginPage(parsing: value, permits: { _ in true }, sourceOperation: { $0 == "fixture.counter" })
        }
        var clock = 0.0
        var count = 0
        var events: [PluginViewEvent] = []
        var timers: [(Double, () -> Void)] = []
        let action = try makeAction()
        let engine = HostRunSources(adapters: ["fixture.counter": HostSourceAdapter(minimumInterval: 2, deadline: 1,
            authorize: { _, _ in }, sample: { _, _, _ in count += 1; return .object(["count": .number(Double(count))]) })],
            now: { clock }, schedule: { timers.append((clock + $0, $1)) }, background: { $0() }, executor: { $0() })
        engine.onDelivery = { _, event, _ in events.append(event) }
        XCTAssertThrowsError(try engine.present(page(1), for: action), "Below-adapter intervals break the protocol")
        try engine.present(page(2), for: action); engine.setVisible(true, pluginID: action.pluginID)
        func advance(_ until: Double) {
            while let index = timers.indices.filter({ timers[$0].0 <= until }).min(by: { timers[$0].0 < timers[$1].0 }) {
                let task = timers.remove(at: index); clock = task.0; task.1()
            }
            clock = until
        }
        advance(2)
        XCTAssertEqual(count, 2); XCTAssertEqual(events.count, 1)
        engine.setVisible(false, pluginID: action.pluginID); advance(20)
        XCTAssertEqual(events.count, 1, "A floor-held result must wait until show")
        XCTAssertEqual(count, 2)
        engine.setVisible(true, pluginID: action.pluginID)
        XCTAssertEqual(events.count, 2)
        guard case .sourceDelivered(_, _, _, let latest, _) = events[1] else { return XCTFail("No source result") }
        XCTAssertEqual(latest, .object(["count": .number(2)]))
    }

    func testReplacedOwnerDropsLateResultBeforeInvalidationObserverRuns() throws {
        var owner = UUID()
        var work: [() -> Void] = []
        var replies: [() -> Void] = []
        let action = try makeAction()
        let adapter = HostSourceAdapter(deadline: 15, ownerIdentity: { _ in owner }, authorize: { _, _ in },
            sample: { _, _, _ in .object(["json": .object(["temperature": .number(24.5)])]) })
        let engine = HostRunSources(adapters: ["http.request": adapter], schedule: { _, _ in },
            background: { work.append($0) }, executor: { replies.append($0) })
        try engine.present(sourcePage(), for: action); engine.setVisible(true, pluginID: action.pluginID)
        work.removeFirst()(); owner = UUID(); replies.removeFirst()()
        XCTAssertEqual(engine.shown(component: "temperature", pluginID: action.pluginID)?.text, "Waiting")
    }

}
