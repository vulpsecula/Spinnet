import AppKit
import SpinnetCore
import XCTest
@testable import SpinnetHost

/// Real panel resize, identified native fields and Host-run source bindings.
/// No Plugin resize callback or collection-selection machinery is involved.
final class AdaptivePagePanelTests: XCTestCase {
    private static var manifest: PluginManifest {
        get throws {
            let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Fixtures/AdaptiveCards.spinnetplugin")
            return try PluginManifestLoader.load(packageAt: package).manifest
        }
    }
    private func page(minimum: Double = 320, spacing: Double = 12, maximum: Int = 2) -> JSONValue {
        let cards = ["cpu", "memory"].map { name -> JSONValue in
            .object(["kind": .string("column"), "id": .string(name), "style": .object(["padding": .number(12), "background": .string("#303030"), "corner_radius": .number(8)]),
                "content": .array([
                    .object(["kind": .string("text_field"), "id": .string(name + "-note"), "title": .string("Note"), "value": .string("initial")]),
                    .object(["kind": .string("text"), "id": .string(name + "-value"), "text": .string(name == "cpu" ? "CPU usage" : "Memory pressure and available physical memory"),
                        "style": .object(["font_size": .number(40), "color": .string("#FFFFFF")]),
                        "bind": .object(["source": .string("live"), "pointer": .string("/" + name), "format": .string("text")])])])])
        }
        return .object(["id": .string("metrics"), "title": .string("Metrics"), "resizable": .bool(true),
            "sources": .array([.object(["id": .string("live"), "perform": .string("system.metrics"), "input": .object(["metrics": .array([.string("cpu"), .string("memory")])]), "every": .number(1)])]),
            "content": .array([.object(["kind": .string("adaptive"), "id": .string("cards"), "min_card_width": .number(minimum),
                "spacing": .number(spacing), "max_columns": .number(Double(maximum)), "content": .array(cards)])])])
    }
    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }

    func testPanelReflowsCardsWithoutReplacingFieldsSamplingOrInvokingThePlugin() throws {
        _ = NSApplication.shared
        var samples = 0, clock: TimeInterval = 0
        var scheduled: [(at: TimeInterval, run: () -> Void)] = []
        let sources = HostRunSources(adapters: ["system.metrics": HostSourceAdapter(minimumInterval: 1, deadline: 1, authorize: { _, _ in }, sample: { _, _, _ in
            samples += 1
            return .object(["cpu": .string(samples == 1 ? "12%" : "25%"), "memory": .string("Memory pressure and available physical memory")])
        })], now: { clock }, schedule: { delay, callback in scheduled.append((clock + delay, callback)) }, background: { $0() }, executor: { $0() })
        let manifest = try Self.manifest
        let harness = try PageHarness(sources: sources, permits: PluginInterfaceContracts.host.permitting(manifest))
        try harness.open(page())
        let model = try XCTUnwrap(harness.windows.pageModel(for: PageHarness.pluginID))
        let window = PluginViewPanelWindow(pageModel: model)
        window.resizing = model.page.resizing
        window.show(near: NSPoint(x: 400, y: 700))
        defer { window.close() }
        settle()
        sources.setVisible(true, pluginID: PageHarness.pluginID)
        settle()
        XCTAssertEqual(samples, 1)
        XCTAssertEqual(model.sourceText("cpu-value")?.text, "12%")
        let first = try XCTUnwrap(model.focusTarget("cpu-note") as? NSView)
        let second = try XCTUnwrap(model.focusTarget("memory-note") as? NSView)
        let native = try XCTUnwrap(first.window)
        func frame(_ view: NSView) -> NSRect { view.convert(view.bounds, to: native.contentView) }
        func capture(_ label: String) throws -> URL {
            let view = try XCTUnwrap(native.contentView)
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("adaptive-" + label + "-" + UUID().uuidString + ".png")
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
            return url
        }
        let narrow = (frame(first), frame(second))
        let narrowImage = try capture("narrow")
        XCTAssertEqual(narrow.0.minX, narrow.1.minX, accuracy: 1)
        XCTAssertGreaterThan(abs(narrow.0.minY - narrow.1.minY), 40, "The default width lays out two full-height cards vertically")
        let field = try XCTUnwrap(first as? NSTextField)
        XCTAssertTrue(native.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("retained note", replacementRange: editor.selectedRange())
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        XCTAssertEqual(model.text(of: "cpu-note"), "retained note", "Real native editing reaches the component state")
        let eventCount = harness.events.count
        let timers = scheduled.count
        window.simulateUserResize(to: NSRect(x: 100, y: 100, width: 860, height: 600))
        settle()
        let wide = (frame(first), frame(second))
        let wideImage = try capture("wide")
        XCTAssertEqual(wide.0.minY, wide.1.minY, accuracy: 1, "Cards share a native row when the actual content width fits two")
        XCTAssertGreaterThan(wide.1.minX - wide.0.minX, 320)
        XCTAssertTrue(model.focusTarget("cpu-note") === first)
        XCTAssertTrue(model.focusTarget("memory-note") === second)
        XCTAssertEqual(model.text(of: "cpu-note"), "retained note")
        XCTAssertTrue(field.currentEditor() === editor)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 4, length: 0))
        XCTAssertEqual(model.sourceText("memory-value")?.text, "Memory pressure and available physical memory")
        XCTAssertEqual(samples, 1, "Resize cannot restart a source")
        XCTAssertEqual(scheduled.count, timers, "Resize cannot schedule a second source loop")
        XCTAssertEqual(harness.events.count, eventCount, "No resize script or source delivery is generated by reflow")
        window.simulateUserResize(to: NSRect(x: 100, y: 100, width: 440, height: 300))
        settle()
        XCTAssertEqual(frame(first).minX, frame(second).minX, accuracy: 1)
        XCTAssertGreaterThan(abs(frame(first).minY - frame(second).minY), 40)
        XCTAssertLessThanOrEqual(frame(first).maxX, native.contentView!.bounds.maxX)
        XCTAssertEqual(model.text(of: "cpu-note"), "retained note")
        XCTAssertEqual(samples, 1); XCTAssertEqual(harness.events.count, eventCount)
        clock = 1
        let due = scheduled.filter { $0.at <= clock }; scheduled.removeAll { $0.at <= clock }
        due.forEach { $0.run() }; settle()
        XCTAssertEqual(samples, 2, "The existing source cadence still updates its same bound component after reflow")
        XCTAssertEqual(model.sourceText("cpu-value")?.text, "25%")
        XCTAssertEqual(harness.events.count, eventCount, "A binding-only source needs no script delivery")
        print("Adaptive native screenshots: \(narrowImage.path), \(wideImage.path)")
        print("Adaptive native frames: narrow=\(narrow), wide=\(wide), final=\(frame(first)), \(frame(second)); font40, min320, spacing12")
    }
}
