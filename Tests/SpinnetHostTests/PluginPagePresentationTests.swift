import AppKit
import SpinnetCore
import SwiftUI
import XCTest
@testable import SpinnetHost

/// Styles, images and progress on a page (#81) as the Host draws them: the
/// published track, metrics and task fixtures in the real panel in light and
/// dark appearance, a colour for each appearance, the pictures the renderer
/// asks for and lets go of, and the cancel View Action. VoiceOver speech,
/// text-size changes and the look itself are checked by hand.
final class PluginPagePresentationTests: XCTestCase {
    private var window: PluginViewPanelWindow?

    override func setUp() { _ = NSApplication.shared }

    override func tearDown() {
        window?.close()
        window = nil
    }

    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("PluginAPI/fixtures/pages/answers")

    private func page(_ name: String) throws -> JSONValue {
        let answer = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: Self.fixtures.appendingPathComponent(name)))
        guard case .object(let members) = answer, let page = members["page"] else { throw PluginTestFailure.noPage }
        return page
    }

    private enum PluginTestFailure: Error { case noPage }

    private func settle(_ seconds: TimeInterval = 0.15) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Each fixture draws in the real panel in both appearances, at the
    /// panel's width, without the page breaking the panel's layout.
    func testTheFixturesDrawInLightAndDark() throws {
        for name in ["spotify-track.json", "monitor-metrics.json", "brew-task-running.json", "brew-list-icons.json"] {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let harness = try PageHarness()
                try harness.open(try page(name))
                let model = try XCTUnwrap(harness.windows.pageModel(for: PageHarness.pluginID))
                let panel = PluginViewPanelWindow(pageModel: model)
                window = panel
                panel.show(near: NSPoint(x: 500, y: 700))
                let content = try XCTUnwrap(panel.contentView)
                content.window?.appearance = NSAppearance(named: appearance)
                settle()
                // The panel measures its content itself (no hosting-view
                // size constraints), so the panel's frame is the content's size.
                let size = panel.presentationSnapshot.frame.size
                XCTAssertEqual(size.width, PluginViewPanelWindow.width, accuracy: 1, "\(name) in \(appearance.rawValue)")
                XCTAssertGreaterThan(size.height, 80, "\(name) in \(appearance.rawValue)")
                panel.close()
            }
        }
    }

    /// A colour for each appearance resolves to its own in each; a named
    /// colour is the system's, which follows the appearance itself.
    func testAColourForEachAppearanceResolvesInEach() throws {
        let light = PluginPageColor.rgb(red: 1, green: 0, blue: 0, alpha: 1)
        let dark = PluginPageColor.rgb(red: 0, green: 0, blue: 1, alpha: 1)
        let color = PluginPageColor.appearance(light: light, dark: dark).nsColor
        func resolved(_ name: NSAppearance.Name) -> NSColor {
            var result = NSColor.clear
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                result = color.usingColorSpace(.sRGB)!
            }
            return result
        }
        XCTAssertEqual(resolved(.aqua).redComponent, 1, accuracy: 0.01)
        XCTAssertEqual(resolved(.darkAqua).blueComponent, 1, accuracy: 0.01)
        XCTAssertEqual(PluginPageColor.named(.secondary).nsColor, .secondaryLabelColor)
    }

    /// The renderer asks for the page's pictures as it shows each answer,
    /// keeps them across an answer naming the same ones, and lets them go
    /// when the session ends.
    func testTheRendererAsksForThePicturesAndLetsThemGo() throws {
        var loads = 0
        let images = PluginPageImages(load: { _, _, _ in
            loads += 1
            return Data()
        }, decode: { _, _ in
            CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        }, background: { $0() }, executor: { $0() })
        let harness = try PageHarness(images: images)
        let track = try page("spotify-track.json")
        try harness.open(track)
        let model = try XCTUnwrap(harness.windows.pageModel(for: PageHarness.pluginID))
        guard case .image(let artwork)? = model.page.component("artwork") else { return XCTFail("No artwork") }
        guard case .loaded = model.imageState(of: artwork.request) else { return XCTFail("\(model.imageState(of: artwork.request))") }
        XCTAssertEqual(loads, 1)
        model.choose(try XCTUnwrap(buttons(of: model).first))
        try harness.answer(track)
        XCTAssertEqual(loads, 1, "The same picture is not loaded again")
        model.close()
        XCTAssertEqual(images.decodedBytes, 0)
        XCTAssertNil(images.state(of: artwork.request, for: PageHarness.pluginID))
    }

    private func buttons(of model: PluginPageModel) -> [PluginPageAction] {
        for case .actions(_, let actions) in model.page.components { return actions }
        return []
    }

    /// The cancel View Action sends `action_chosen` while the task runs, and
    /// nothing while a cancellation is being attempted.
    func testCancelSendsActionChosenOnlyWhileRunning() throws {
        let harness = try PageHarness()
        try harness.open(try page("brew-task-running.json"))
        let model = try XCTUnwrap(harness.windows.pageModel(for: PageHarness.pluginID))
        guard case .progress(let task)? = model.page.component("task") else { return XCTFail("No progress") }
        model.chooseCancel(of: task)
        XCTAssertEqual(harness.events.last?.event, .pageActionChosen(page: "task:ffmpeg", action: "cancel",
                                                                     values: .object([:]), selection: .object([:])))
        try harness.answer(try page("brew-task-cancelling.json"))
        guard case .progress(let cancelling)? = model.page.component("task") else { return XCTFail("No progress") }
        let sent = harness.events.count
        model.chooseCancel(of: cancelling)
        XCTAssertEqual(harness.events.count, sent)
    }

    /// An indeterminate bar keeps running across answers to the same page:
    /// the panel keeps the very indicator it drew, still animating, so a
    /// refresh does not flash.
    func testAnIndeterminateBarKeepsRunningAcrossAnswers() throws {
        let harness = try PageHarness()
        let running = try page("brew-task-running.json")
        try harness.open(running)
        let model = try XCTUnwrap(harness.windows.pageModel(for: PageHarness.pluginID))
        let panel = PluginViewPanelWindow(pageModel: model)
        window = panel
        panel.show(near: NSPoint(x: 500, y: 700))
        settle()
        let bar = try XCTUnwrap(indeterminateBars(in: panel.contentView).first, "The task draws a native indeterminate bar")

        for status in ["Pouring ffmpeg--7.1", "Linking 12 files"] {
            model.choose(try XCTUnwrap(buttons(of: model).first))
            try harness.answer(Self.page(running, status: status))
            settle()
            guard case .progress(let task)? = model.page.component("task") else { return XCTFail("No progress") }
            XCTAssertEqual(task.status, status)
            XCTAssertEqual(indeterminateBars(in: panel.contentView).map(ObjectIdentifier.init), [ObjectIdentifier(bar)],
                           "The same bar, not a new one")
            XCTAssertTrue(bar.isIndeterminate)
        }
    }

    private static func page(_ page: JSONValue, status: String) -> JSONValue {
        guard case .object(var members) = page, case .array(var content)? = members["content"],
              case .object(var task) = content[0] else { return page }
        task["status"] = .string(status)
        content[0] = .object(task)
        members["content"] = .array(content)
        return .object(members)
    }

    private func indeterminateBars(in view: NSView?) -> [NSProgressIndicator] {
        guard let view else { return [] }
        let own = (view as? NSProgressIndicator).map { $0.isIndeterminate && $0.style == .bar ? [$0] : [] } ?? []
        return own + view.subviews.flatMap(indeterminateBars)
    }

    /// Styles, icons, images and progress add no focus stop and take no
    /// focus: a page opens focused on its field even inside a styled
    /// column, and Tab moves between the field and the collection only.
    func testPresentationComponentsLeaveFocusToTheFieldsAndCollection() throws {
        let harness = try PageHarness()
        let style: JSONValue = .object(["background": .string("#1DB95420"), "padding": .number(8), "corner_radius": .number(6)])
        try harness.open(.object([
            "id": .string("styled"), "title": .string("Styled"),
            "content": .array([
                .object(["kind": .string("progress"), "id": .string("task"), "title": .string("Working"),
                         "cancel": .object(["id": .string("stop")])]),
                .object(["kind": .string("column"), "id": .string("panel"), "style": style, "content": .array([
                    .object(["kind": .string("icon"), "id": .string("glyph"), "source": .object(["symbol": .string("music.note")])]),
                    .object(["kind": .string("image"), "id": .string("art"), "label": .string("Artwork"),
                             "source": .object(["resource": .string("art/cover.png")]),
                             "width": .number(48), "height": .number(48)]),
                    .object(["kind": .string("text_field"), "id": .string("query"), "title": .string("Search"),
                             "collection": .string("results")])
                ])]),
                .object(["kind": .string("list"), "id": .string("results"),
                         "items": .array(["A", "B"].map(PageHarness.item))])
            ])
        ]))
        let model = try XCTUnwrap(harness.windows.pageModel(for: PageHarness.pluginID))
        XCTAssertEqual(model.focused, "query")
        XCTAssertEqual(model.focusStops, ["query", "results"])
        model.moveFocus(from: "results", forward: true)
        XCTAssertEqual(model.focused, "query", "Tab wraps past the progress, icon and image")
    }
}
