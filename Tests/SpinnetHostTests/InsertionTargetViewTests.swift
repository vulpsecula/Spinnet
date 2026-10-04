import AppKit
import SpinnetCore
import XCTest
@testable import SpinnetHost

/// How a Plugin View of a Plugin declaring `host_operations` shows where
/// text goes and captures it with each gesture (ADR 0018, P1): the Host
/// names the App on each insert action and in a target line the view asks
/// for, keeps it current, and hands the session what was shown when the
/// user acted. A Level 1 Plugin's view is unchanged.
final class InsertionTargetViewTests: XCTestCase {
    private var desktop: FakeDesktop!
    private var apps: FakeApps!
    private var tracker: InsertionTargetTracker!

    override func setUp() {
        desktop = FakeDesktop()
        desktop.frontmost = 42
        apps = FakeApps(desktop: desktop)
        apps.focus[42] = "field 1"
        tracker = InsertionTargetTracker(environment: apps.environment)
    }

    private func harness(declaring: Bool = true) throws -> PluginViewHarness {
        try PluginViewHarness(insertionTargets: tracker, declaresHostOperations: declaring)
    }

    private static func picker(showsTarget: Bool = true) -> JSONValue {
        guard case .object(var view) = PluginViewHarness.form(title: "Symbols", actions: [
            .object(["title": .string("Insert ★"), "perform": .string("insert_text"), "text": .string("★")]),
            .object(["id": .string("copy"), "title": .string("Copy ♥")])
        ]) else { return .null }
        if showsTarget { view["shows_insertion_target"] = .bool(true) }
        return .object(view)
    }

    func testTheViewNamesTheTargetAndKeepsItCurrent() throws {
        let harness = try harness()
        try harness.present(Self.picker())
        let model = try XCTUnwrap(harness.windows.model(for: harness.pluginID))
        let insert = try XCTUnwrap(model.description.actions.first)

        XCTAssertEqual(model.insertionTargetLine, "Inserts into TextEdit")
        XCTAssertEqual(model.insertionTargetLabel(of: insert), "into TextEdit")
        XCTAssertEqual(model.actionLabel(insert), "Insert ★, into TextEdit", "VoiceOver reads the App with the action")
        XCTAssertNil(model.insertionTargetLabel(of: model.description.actions[1]), "Only insert actions name it")
        XCTAssertTrue(model.accessibilityLabels.contains("Inserts into TextEdit"))

        var changes = 0
        let watch = model.objectWillChange.sink { _ in changes += 1 }
        desktop.frontmost = 99
        apps.activate()
        XCTAssertEqual(model.insertionTargetLine, "Inserts into Notes")
        XCTAssertGreaterThan(changes, 0, "The view redraws when the App in front changes")
        desktop.frontmost = desktop.ownProcess
        apps.activate()
        XCTAssertEqual(model.insertionTargetLine, PluginViewModel.noInsertionTarget)
        XCTAssertEqual(model.insertionTargetLabel(of: insert), PluginViewModel.noInsertionTarget)
        watch.cancel()
    }

    func testTheTargetLineIsShownOnlyWhenTheViewAsks() throws {
        let harness = try harness()
        try harness.present(Self.picker(showsTarget: false))
        let model = try XCTUnwrap(harness.windows.model(for: harness.pluginID))
        XCTAssertNil(model.insertionTargetLine)
        XCTAssertEqual(model.insertionTargetLabel(of: try XCTUnwrap(model.description.actions.first)), "into TextEdit",
                       "An insert action names its App anyway")
    }

    /// A gesture in a view that names the target carries what was shown,
    /// focused element included; one in a view that does not carries
    /// nothing, and typing never does.
    func testGesturesCarryWhatTheViewShowed() throws {
        let harness = try harness()
        try harness.present(Self.picker())
        let model = try XCTUnwrap(harness.windows.model(for: harness.pluginID))
        model.submit()
        XCTAssertEqual(harness.events.last?.delivery.insertionTarget, .shown(app: apps.textEdit, focus: "field 1"))
        harness.finishEvent(with: .null)
        model.choose(model.description.actions[1])
        XCTAssertEqual(harness.events.last?.delivery.insertionTarget, .shown(app: apps.textEdit, focus: "field 1"))
        harness.finishEvent(with: .null)

        try harness.present(Self.picker(showsTarget: false))
        model.submit()
        XCTAssertEqual(harness.events.last?.delivery.insertionTarget, .notShown)
    }

    /// The standard insert action of a candidate view inserts into the App
    /// its button named, not the App the view came from.
    func testTheStandardInsertActionInsertsIntoTheAppItNamed() throws {
        let harness = try harness()
        try harness.present(Self.picker())
        let model = try XCTUnwrap(harness.windows.model(for: harness.pluginID))
        desktop.frontmost = 99
        apps.activate()

        model.choose(try XCTUnwrap(model.description.actions.first))

        XCTAssertEqual(harness.inserted.map(\.0), ["★"])
        XCTAssertEqual(harness.inserted.map(\.1), [.shown(.shown(app: apps.notes, focus: nil))],
                       "Notes is named now; the view came from TextEdit")
    }

    /// A refusal from the targeted path shows the Host's own words inline.
    func testARefusedInsertShowsWhyInTheView() throws {
        let harness = try harness()
        harness.insertionFinishesAtOnce = .some(.insertion(InsertionFailure(
            .targetChanged, message: "Spinnet showed TextEdit, but Notes is in front. Nothing was inserted.")))
        try harness.present(Self.picker())
        let model = try XCTUnwrap(harness.windows.model(for: harness.pluginID))
        model.choose(try XCTUnwrap(model.description.actions.first))
        XCTAssertEqual(model.error?.message, "Spinnet showed TextEdit, but Notes is in front. Nothing was inserted.")
        XCTAssertEqual(model.error?.category, .insertionTargetChanged)
    }

    /// Level 1 keeps its origin and draws nothing new.
    func testALevelOneViewIsUnchanged() throws {
        let harness = try harness(declaring: false)
        try harness.present(Self.picker(showsTarget: false))
        let model = try XCTUnwrap(harness.windows.model(for: harness.pluginID))
        XCTAssertNil(model.insertionTargetLine)
        XCTAssertNil(model.insertionTargetLabel(of: try XCTUnwrap(model.description.actions.first)))
        model.choose(try XCTUnwrap(model.description.actions.first))
        XCTAssertEqual(harness.inserted.map(\.1), [.origin(harness.frontmost)])
        model.submit()
        XCTAssertEqual(harness.events.last?.delivery.insertionTarget, .notShown)

        XCTAssertThrowsError(try harness.present(Self.picker()), "shows_insertion_target is not a Level 1 member")
    }

    /// The operation's own busy state, distinct from an event's.
    func testTheOperationBusyStateIsReadToVoiceOver() throws {
        let harness = try harness()
        try harness.present(Self.picker())
        let model = try XCTUnwrap(harness.windows.model(for: harness.pluginID))
        model.update(PluginViewPresentation(view: model.view, isBusy: false, error: nil, isPerformingOperation: true),
                     description: model.description, newView: false, answersTyping: false, presentedAnew: false)
        XCTAssertTrue(model.isPerformingOperation)
        XCTAssertTrue(model.accessibilityLabels.contains(PluginViewModel.operationBusyLabel))
        XCTAssertFalse(model.isBusy)
    }
}
