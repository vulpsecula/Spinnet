import Foundation
import XCTest
import SpinnetCore
import SpinnetPluginTestKit

final class RecordedActivityDeliveryTests: XCTestCase {
    func testRecordedActivitiesDeliverChangedDataAtOneSecondCadence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".spinnetplugin")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = try PluginManifest(id: .init("com.example.recorded-activities"), name: "Activities", version: "1",
            commands: [.init(id: .init("tasks"), title: "Tasks", execution: .javascript, script: "tasks.js")])
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("manifest.json"))
        try "null".write(to: root.appendingPathComponent("tasks.js"), atomically: true, encoding: .utf8)
        let plugin = try PluginUnderTest(packageAt: root)
        var log = "Starting"
        let sources = try RecordedHostSources(of: plugin, for: .init("tasks"), operations: [
            "activities.list": .answer { _ in .array([.object(["id": .string("task"), "log": .array([.string(log)])])]) }
        ])
        let page = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"id":"tasks","title":"Tasks","sources":[{"id":"activities","perform":"activities.list","input":null,"every":1,"deliver":{}}],"content":[{"kind":"text","id":"log","text":"Waiting"}]}"#.utf8))
        try sources.present(page)
        sources.setVisible(true)
        XCTAssertEqual(sources.deliveries.count, 1)
        log = "Still running"
        sources.advance(by: 1)
        XCTAssertEqual(sources.deliveries.count, 2)
        sources.advance(by: 1)
        XCTAssertEqual(sources.deliveries.count, 2, "Unchanged activity data must not wake the script")
        sources.advance(by: 13)
        XCTAssertEqual(sources.deliveries.count, 2)
        if case .sourceDelivered(_, _, _, let result?, nil) = sources.deliveries.last {
            XCTAssertEqual(result.value(atPointer: "/0/log/0"), .string(log))
        } else { XCTFail("Expected recorded activity data") }
    }
}
