import SpinnetTestSupport
import AppKit
import SpinnetCore
import SpinnetPluginTestKit
import XCTest
import Vision
@testable import SpinnetHost

final class AdaptiveViewportPanelTests: XCTestCase {
    private let fixture = TestRepository.tests.appendingPathComponent("Fixtures/AdaptiveViewport.spinnetplugin")
    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }

    private func nativeViews(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(nativeViews) }

    /// Read the actual pixels, including the text's location inside its card.
    /// This catches hidden primary Text while its binding and card survive.
    private func assertPrimaryTextVisible(_ bitmap: NSBitmapImageRep, points: NSSize,
                                          cards: [NSRect], viewport: NSRect, file: StaticString = #filePath, line: UInt = #line) throws {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage), options: [:]).perform([request])
        let rendered = (request.results ?? []).compactMap { observation -> (String, NSRect)? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            // Vision uses a lower-left normalized origin; the captured pixels
            // and measured background rectangles use an upper-left origin.
            let box = observation.boundingBox
            let rect = NSRect(x: box.minX * points.width, y: (1 - box.maxY) * points.height,
                              width: box.width * points.width, height: box.height * points.height)
            let normalized = text.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "%" }
            return (normalized, rect)
        }
        print("Rendered metric text: \(rendered)")
        for (label, value) in [("cpu", "25%"), ("memory", "8.59gb"), ("disk", "128.85gb"), ("battery", "72%")] {
            let matchingCard = cards.first { card in
                let bounds = card.insetBy(dx: -2, dy: -2)
                return rendered.contains { $0.0.contains(label) && bounds.contains($0.1) && viewport.contains($0.1) }
                    && rendered.contains { $0.0 == value && bounds.contains($0.1) && viewport.contains($0.1) }
            }
            XCTAssertNotNil(matchingCard, "Rendered \(label) label and literal \(value) must both be visible in the same card", file: file, line: line)
        }
    }

    /// Measure the drawn opaque backgrounds, rather than a layout wrapper.
    private func cardRectangles(_ bitmap: NSBitmapImageRep, points: NSSize) -> [NSRect] {
        // Tolerance covers the display profile applied by AppKit snapshots.
        let step = 2
        let width = bitmap.pixelsWide / step, height = bitmap.pixelsHigh / step
        var mask = [UInt8](repeating:0,count:width * height)
        for y in 0..<height { for x in 0..<width {
            guard let color = bitmap.colorAt(x:x * step,y:y * step) else { continue }
            if abs(color.redComponent - 34.0/255) < 0.05,
               abs(color.greenComponent - 51.0/255) < 0.05,
               abs(color.blueComponent - 68.0/255) < 0.05 { mask[y * width + x] = 1 }
        } }
        var rectangles: [NSRect] = []
        for start in mask.indices where mask[start] == 1 {
            var queue = [start], cursor = 0, minX = start % width, maxX = minX, minY = start / width, maxY = minY
            mask[start] = 0
            while cursor < queue.count {
                let index = queue[cursor]; cursor += 1
                let x = index % width, y = index / width
                minX = min(minX,x); maxX = max(maxX,x); minY = min(minY,y); maxY = max(maxY,y)
                for next in [x > 0 ? index - 1 : -1, x + 1 < width ? index + 1 : -1,
                             y > 0 ? index - width : -1, y + 1 < height ? index + width : -1] where next >= 0 {
                    if mask[next] == 1 { mask[next] = 0; queue.append(next) }
                }
            }
            if maxX - minX > 30, maxY - minY > 20 {
                let scaleX = points.width / CGFloat(width), scaleY = points.height / CGFloat(height)
                rectangles.append(NSRect(x:CGFloat(minX) * scaleX,y:CGFloat(minY) * scaleY,
                    width:CGFloat(maxX - minX + 1) * scaleX,height:CGFloat(maxY - minY + 1) * scaleY))
            }
        }
        return rectangles
    }

    func testFourMetricCardsFillBothViewportDimensionsAcrossDensityChanges() throws {
        _ = NSApplication.shared
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let plugin = try PluginUnderTest(packageAt: fixture)
        let page = PluginTestPage("cards", of: plugin, helper: helper)
        try page.open()
        let json = try XCTUnwrap(page.pageJSON)
        let permits = PluginInterfaceContracts.host.permitting(try PluginManifestLoader.load(packageAt: fixture).manifest)
        var samples = 0
        let sources = HostRunSources(adapters: ["system.metrics": HostSourceAdapter(minimumInterval:1,deadline:1,authorize:{ _,_ in },sample:{ _,_,_ in
            samples += 1
            return .object(["cpu":.object(["busy":.number(0.25)]),"memory":.object(["used_bytes":.number(8_589_934_592),"total_bytes":.number(17_179_869_184)]),"disk":.object(["available_bytes":.number(128_849_018_880),"total_bytes":.number(1_099_511_627_776)]),"battery":.object(["charge":.number(0.72),"power_source":.string("Battery")])])
        })],schedule:{ _,_ in },background:{ $0() },executor:{ $0() })
        let harness = try PageHarness(sources:sources,permits: permits)
        try harness.open(json)
        let model = try XCTUnwrap(harness.windows.pageModel(for: PageHarness.pluginID))
        let window = PluginViewPanelWindow(pageModel: model)
        window.resizing = model.page.resizing
        window.show(near: NSPoint(x: 400, y: 700)); defer { window.close() }
        settle()
        sources.setVisible(true,pluginID:PageHarness.pluginID); settle()
        let native = try XCTUnwrap(window.contentView?.window)
        native.appearance = NSAppearance(named:.darkAqua)
        for size in [NSSize(width:440,height:420), NSSize(width:440,height:700), NSSize(width:860,height:420), NSSize(width:860,height:650), NSSize(width:1200,height:800)] {
            window.simulateUserResize(to: NSRect(origin:.init(x:100,y:100),size:size)); settle()
            let view = try XCTUnwrap(native.contentView)
            let scroll = try XCTUnwrap(nativeViews(view).compactMap { $0 as? NSScrollView }.first)
            let viewport = scroll.contentView.convert(scroll.contentView.bounds,to:view)
            XCTAssertLessThanOrEqual(try XCTUnwrap(scroll.documentView).bounds.height, scroll.contentView.bounds.height + 2,
                "No scrolling at supported frame \(size)")
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds))
            view.cacheDisplay(in:view.bounds,to:bitmap)
            let cards = cardRectangles(bitmap,points:view.bounds.size)
            XCTAssertEqual(cards.count,4,"All four actual styled card backgrounds exist")
            guard !cards.isEmpty else { return XCTFail("No native card background pixels") }
            let drawnViewport = view.isFlipped ? viewport : NSRect(x:viewport.minX,y:view.bounds.height - viewport.maxY,width:viewport.width,height:viewport.height)
            XCTAssertEqual(try XCTUnwrap(cards.map(\.minY).min()),drawnViewport.minY,accuracy:2)
            XCTAssertEqual(try XCTUnwrap(cards.map(\.maxY).max()),drawnViewport.maxY,accuracy:2,"Cards fill the actual remaining height")
            XCTAssertEqual(try XCTUnwrap(cards.map(\.minX).min()),drawnViewport.minX,accuracy:2)
            XCTAssertEqual(try XCTUnwrap(cards.map(\.maxX).max()),drawnViewport.maxX,accuracy:2)
            for card in cards { XCTAssertTrue(drawnViewport.insetBy(dx:-2,dy:-2).contains(card)) }
            try assertPrimaryTextVisible(bitmap, points: view.bounds.size, cards: cards, viewport: drawnViewport)
            for metric in ["cpu","memory","disk","battery"] {
                XCTAssertNotNil(model.sourceText(metric + "-value"),"Required primary value remains source-bound")
            }
            XCTAssertEqual(samples,1,"Reflow never resamples the source")
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("viewport-\(Int(size.width))x\(Int(size.height)).png")
            try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:file)
            print("Viewport \(size), actual \(viewport), cards \(cards), image \(file.path)")
        }
        XCTAssertEqual(harness.events.count, 0)
    }
    func testDensityChangesKeepNativeEditingAndSourceCadenceAndFallbackStaysReadable() throws {
        _ = NSApplication.shared
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let plugin = try PluginUnderTest(packageAt:fixture)
        let page = PluginTestPage("cards",of:plugin,helper:helper,input:.object(["probe":.bool(true)]))
        try page.open()
        let permits = PluginInterfaceContracts.host.permitting(try PluginManifestLoader.load(packageAt:fixture).manifest)
        var samples = 0, clock: TimeInterval = 0
        var scheduled: [(at:TimeInterval,run:()->Void)] = []
        let sources = HostRunSources(adapters:["system.metrics":HostSourceAdapter(minimumInterval:1,deadline:1,authorize:{ _,_ in },sample:{ _,_,_ in
            samples += 1
            return .object(["cpu":.object(["busy":.number(samples == 1 ? 0.25 : 0.5)])])
        })],now:{ clock },schedule:{ delay,run in scheduled.append((clock + delay,run)) },background:{ $0() },executor:{ $0() })
        let harness = try PageHarness(sources:sources,permits:permits)
        try harness.open(try XCTUnwrap(page.pageJSON))
        let model = try XCTUnwrap(harness.windows.pageModel(for:PageHarness.pluginID))
        let window = PluginViewPanelWindow(pageModel:model)
        window.resizing = model.page.resizing
        window.show(near:.init(x:400,y:700)); defer { window.close() }
        settle(); sources.setVisible(true,pluginID:PageHarness.pluginID); settle()
        let field = try XCTUnwrap(model.focusTarget("note") as? NSTextField)
        let native = try XCTUnwrap(field.window)
        XCTAssertTrue(native.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil); editor.insertText("retained note",replacementRange:editor.selectedRange())
        editor.setSelectedRange(.init(location:4,length:0))
        let events = harness.events.count, timers = scheduled.count
        for size in [NSSize(width:440,height:420),NSSize(width:440,height:700),NSSize(width:860,height:650),NSSize(width:860,height:420)] {
            window.simulateUserResize(to:.init(origin:.init(x:100,y:100),size:size)); settle()
            XCTAssertTrue(model.focusTarget("note") === field)
            XCTAssertTrue(field.currentEditor() === editor)
            XCTAssertEqual(editor.selectedRange(),.init(location:4,length:0))
            XCTAssertEqual(model.text(of:"note"),"retained note")
            XCTAssertEqual(model.sourceText("cpu-value")?.text,"25%")
            XCTAssertEqual(samples,1); XCTAssertEqual(scheduled.count,timers)
            XCTAssertEqual(harness.events.count,events,"No density or resize event invokes the Plugin")
        }
        clock = 1
        let due = scheduled.filter { $0.at <= clock }; scheduled.removeAll { $0.at <= clock }; due.forEach { $0.run() }; settle()
        XCTAssertEqual(samples,2)
        XCTAssertEqual(model.sourceText("cpu-value")?.text,"50%","Existing cadence updates the same identified binding")
        XCTAssertEqual(harness.events.count,events)

        // A Plugin can understate its minimum: actual native text is retained,
        // and the Host offers readable scrolling rather than clipping it.
        var fallback = try XCTUnwrap(page.pageJSON)
        guard case .object(var root) = fallback, case .array(var content)? = root["content"], case .object(var adaptive) = content[0] else { return XCTFail("No fixture") }
        root["resizable"] = .object(["min_height":.number(120)])
        adaptive["fit"] = .object(["profiles":.array([.object(["id":.string("readable"),"min_card_width":.number(600),"min_card_height":.number(48)])])])
        content[0] = .object(adaptive); root["content"] = .array(content); fallback = .object(root)
        try harness.open(fallback)
        window.resizing = model.page.resizing
        window.simulateUserResize(to:.init(x:100,y:100,width:440,height:160)); settle()
        let view = try XCTUnwrap(native.contentView)
        let scroll = try XCTUnwrap(nativeViews(view).compactMap { $0 as? NSScrollView }.first)
        XCTAssertGreaterThan(try XCTUnwrap(scroll.documentView).bounds.height,scroll.contentView.bounds.height)
        XCTAssertEqual(model.text(of:"note"),"retained note")
    }

}
