import Foundation
import XCTest
import SpinnetCore

final class SystemMetricsTests: XCTestCase {
    func testActualSystemSnapshotIsBoundedAndFirstCPUSampleHasNoInterval() throws {
        let sampler = SystemMetricsSampler()
        let input: JSONValue = .object(["metrics": .array(["cpu", "memory", "disk", "battery"].map(JSONValue.string))])
        let first = try sampler.read(input, owner: PluginID("com.example.monitor"))
        XCTAssertEqual(first.value(atPointer: "/cpu/busy"), .null)
        XCTAssertEqual(first.value(atPointer: "/memory/total_bytes"), .number(Double(ProcessInfo.processInfo.physicalMemory)))
        let data = try JSONEncoder().encode(first)
        XCTAssertLessThan(data.count, 1024)
        XCTAssertNil(first.value(atPointer: "/processes"))
        let second = try sampler.read(input, owner: PluginID("com.example.monitor"))
        if case .number(let busy)? = second.value(atPointer: "/cpu/busy") { XCTAssertTrue((0...1).contains(busy)) }
        else { XCTAssertEqual(second.value(atPointer: "/cpu/busy"), .null) }
        XCTAssertThrowsError(try sampler.read(.object(["metrics": .array([.string("temperature")])]), owner: PluginID("com.example.monitor")))
    }
}

extension SystemMetricsTests {
    func testPublishedFixturesAndUnknownMetricBoundary() throws {
        let api = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("PluginAPI")
        struct Index: Decodable { struct Fixture: Decodable { let file: String; let definition: String; let valid: Bool }; let fixtures: [Fixture] }
        let dir = api.appendingPathComponent("fixtures/system-metrics")
        for fixture in try JSONDecoder().decode(Index.self, from: Data(contentsOf: dir.appendingPathComponent("index.json"))).fixtures {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: dir.appendingPathComponent(fixture.file)))
            let schema = try JSONSchemaSubsetValidator(definition: fixture.definition, inSchemaAt: api.appendingPathComponent("schemas/system-metrics.schema.json"))
            XCTAssertEqual(schema.errors(for: value).isEmpty, fixture.valid, "\(fixture.file): \(schema.errors(for: value))")
            if fixture.definition == "input" { XCTAssertEqual((try? SystemMetricsInput(value)) != nil, fixture.valid, fixture.file) }
        }
    }
}

extension SystemMetricsTests {
    func testVisibleSourceRetiresItsBaselineOnHideAndCloseButKeepsItAcrossSamples() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"id":"monitor","title":"System Monitor","sources":[{"id":"metrics","perform":"system.metrics","input":{"metrics":["cpu"]},"every":1}],"content":[{"kind":"text","id":"cpu","text":"Waiting","bind":{"source":"metrics","pointer":"/cpu/busy","format":"percent"}}]}"#.utf8))
        let page = try PluginPage(parsing: value, permits: { PluginInterfaceContracts.levelTwoMembers.contains($0) })
        let action = try ActionConfiguration(id: ActionID("monitor"), pluginID: PluginID("com.example.monitor"), command: CommandDeclaration(id: CommandID("monitor.show"), title: "Monitor", execution: .javascript, script: "monitor.js"), input: .null)
        var retired = 0, samples = 0, clock = 0.0, timers: [(Double, () -> Void)] = []
        let adapter = HostSourceAdapter(minimumInterval: 1, deadline: 1, authorize: { _, _ in }, retire: { _, _ in retired += 1 }, sample: { _, _, _ in samples += 1; return .object(["cpu": .object(["busy": .number(0.37)])]) })
        let engine = HostRunSources(adapters: ["system.metrics": adapter], now: { clock }, schedule: { timers.append((clock + $0, $1)) }, background: { $0() }, executor: { $0() })
        try engine.present(page, for: action); engine.setVisible(true, pluginID: action.pluginID)
        XCTAssertEqual(samples, 1); XCTAssertEqual(retired, 0)
        engine.setVisible(false, pluginID: action.pluginID)
        XCTAssertEqual(retired, 1)
        for task in timers { task.1() }
        XCTAssertEqual(samples, 1)
        clock = 2; engine.setVisible(true, pluginID: action.pluginID)
        XCTAssertEqual(samples, 2); XCTAssertEqual(retired, 1)
        engine.end(pluginID: action.pluginID)
        XCTAssertEqual(retired, 2)
        for task in timers { task.1() }
        XCTAssertEqual(samples, 2)
    }
}
