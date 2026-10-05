import AppKit
import SpinnetCore
import XCTest
@testable import SpinnetHost

/// The window rules of Plugin Views (ADR 0010, W11 #58), driven through the
/// real View Sessions and renderer with stand-in windows: one view per
/// Plugin, presenting again replaces it in place and keeps its pin, views of
/// different Plugins coexist, an unpinned view closes when it loses focus,
/// and each view appears near the pointer.
final class PluginViewWindowsTests: XCTestCase {
    private var harness: PluginViewHarness!

    override func setUpWithError() throws {
        harness = try PluginViewHarness()
    }

    func testAViewAppearsNearThePointerAndTakesFocus() throws {
        harness.pointer = NSPoint(x: 300, y: 500)
        try harness.present(PluginViewHarness.form(title: "First"))

        let window = try XCTUnwrap(harness.window())
        XCTAssertEqual(window.shownNear, [NSPoint(x: 300, y: 500)])
        XCTAssertEqual(harness.windows.model(for: harness.pluginID)?.description.title, "First")
        XCTAssertEqual(harness.windows.model(for: harness.pluginID)?.origin, harness.frontmost,
                       "The view remembers the App it came from")
    }

    /// One View Session per Plugin: presenting again replaces the view in
    /// the same window, which stays where it is and keeps its pin.
    func testPresentingAgainReplacesTheViewInPlaceAndKeepsItsPin() throws {
        try harness.present(PluginViewHarness.form(title: "First"))
        let window = try XCTUnwrap(harness.window())
        let model = try XCTUnwrap(harness.windows.model(for: harness.pluginID))
        model.isPinned = true
        harness.frontmost = PluginViewOrigin(processIdentifier: 7, name: "Notes")

        try harness.present(PluginViewHarness.form(title: "Second"))

        XCTAssertTrue(harness.window() === window)
        XCTAssertTrue(harness.windows.model(for: harness.pluginID) === model)
        XCTAssertEqual(model.description.title, "Second")
        XCTAssertTrue(model.isPinned)
        XCTAssertEqual(window.shownNear.count, 1, "The window is not moved or shown again")
        XCTAssertEqual(window.focuses, 1, "The replaced view takes the keyboard again where it is")
        XCTAssertEqual(window.title, "Second", "VoiceOver reads the replacing view's title")
        XCTAssertEqual(model.origin, harness.frontmost, "Presenting again comes from the App now in front")
        XCTAssertEqual(window.closes, 0)
    }

    /// Calling the Plugin again while its view is open (Candidate Contract
    /// `collections` r2) brings the window forward where it is as soon as
    /// the call is accepted; the call's view then updates it in place.
    /// Under Level 1 the call is not taken: the Action starts again.
    func testACallBringsTheViewForwardWhereItIs() throws {
        harness = try PluginViewHarness(declaresHostOperations: true)
        try harness.present(PluginViewHarness.form(title: "First"))
        let window = try XCTUnwrap(harness.window())

        XCTAssertTrue(harness.sessions.call(try harness.action()))
        XCTAssertEqual(window.focuses, 1, "Forward before the call runs")
        XCTAssertEqual(harness.events.last?.event, .called)
        harness.finishEvent(with: .object(["view": PluginViewHarness.form(title: "Second"), "state": .null]))

        XCTAssertTrue(harness.window() === window)
        XCTAssertEqual(harness.windows.model(for: harness.pluginID)?.description.title, "Second")
        XCTAssertEqual(window.focuses, 1, "Its answer does not take the keyboard again")
        XCTAssertEqual(window.shownNear.count, 1)
        XCTAssertEqual(window.closes, 0)

        harness = try PluginViewHarness()
        try harness.present(PluginViewHarness.form(title: "First"))
        XCTAssertFalse(harness.sessions.call(try harness.action()))
        XCTAssertEqual(harness.window()?.focuses, 0)
    }

    func testViewsOfDifferentPluginsCoexist() throws {
        try harness.present(PluginViewHarness.form(title: "Mine"))
        let other = PluginID("com.example.other")
        try harness.present(PluginViewHarness.form(title: "Theirs"), pluginID: other)

        XCTAssertNotNil(harness.window())
        XCTAssertNotNil(harness.window(for: other))
        XCTAssertFalse(harness.window() === harness.window(for: other))
        XCTAssertEqual(harness.window()?.closes, 0)
    }

    func testAnUnpinnedViewClosesWhenItLosesFocus() throws {
        try harness.present(PluginViewHarness.form(title: "First"))
        let window = try XCTUnwrap(harness.window())
        let session = try XCTUnwrap(harness.sessions.session(for: harness.pluginID))

        window.onResignKey?()

        XCTAssertTrue(session.isEnded)
        XCTAssertEqual(window.closes, 1)
        XCTAssertNil(harness.windows.model(for: harness.pluginID))
        XCTAssertNil(harness.sessions.session(for: harness.pluginID))
    }

    func testAPinnedViewStaysWhenItLosesFocus() throws {
        try harness.present(PluginViewHarness.form(title: "First"))
        let window = try XCTUnwrap(harness.window())
        harness.windows.model(for: harness.pluginID)?.isPinned = true

        window.onResignKey?()

        XCTAssertEqual(window.closes, 0)
        XCTAssertNotNil(harness.sessions.session(for: harness.pluginID))
    }

    /// macOS's window-capture highlight tints only normal-level windows, so a
    /// view floats above other Apps only while pinned, which is when the
    /// user keeps it beside their work.
    func testAViewFloatsOnlyWhilePinned() throws {
        try harness.present(PluginViewHarness.form(title: "First"))
        let window = try XCTUnwrap(harness.window())
        XCTAssertFalse(window.floats)

        harness.windows.model(for: harness.pluginID)?.isPinned = true
        XCTAssertTrue(window.floats)

        harness.windows.model(for: harness.pluginID)?.isPinned = false
        XCTAssertFalse(window.floats)
    }

    /// Escape or the close button closes the view and ends its session.
    func testClosingTheWindowEndsTheSession() throws {
        try harness.present(PluginViewHarness.form(title: "First"))
        let window = try XCTUnwrap(harness.window())
        let session = try XCTUnwrap(harness.sessions.session(for: harness.pluginID))

        window.onUserClose?()

        XCTAssertTrue(session.isEnded)
        XCTAssertEqual(window.closes, 1)
        XCTAssertEqual(harness.provider.ended.count, 1, "Its Host-Fetched Sections are cancelled")
    }

    /// Ending the session some other way, such as the Plugin being updated,
    /// closes its window, and a view presented afterwards opens anew.
    func testASessionEndedElsewhereClosesItsWindow() throws {
        try harness.present(PluginViewHarness.form(title: "First"))
        let window = try XCTUnwrap(harness.window())

        harness.sessions.end(pluginID: harness.pluginID, because: .pluginChanged)

        XCTAssertEqual(window.closes, 1)
        try harness.present(PluginViewHarness.form(title: "Again"))
        XCTAssertFalse(harness.window() === window)
    }

    /// A script that breaks the interface ends its session; the Host says so.
    func testAProtocolViolationClosesTheViewAndIsReported() throws {
        try harness.present(PluginViewHarness.form(title: "First"))
        let window = try XCTUnwrap(harness.window())
        harness.sessions.session(for: harness.pluginID)?.send(.submitted(values: .null))
        harness.finishEvent(with: .object(["view": .object(["title": .string("No component")])]))

        XCTAssertEqual(window.closes, 1)
        XCTAssertEqual(harness.reports.count, 1)
        XCTAssertTrue(harness.reports[0].contains("View Gallery"), harness.reports[0])
    }

    /// The section provider hears of every view the script answers with:
    /// when it is presented, replaced, or answered by an event, even with
    /// the same view, but not when only the busy state changes.
    func testTheSectionProviderHearsOfEachViewItsSectionsBelongTo() throws {
        let fetched = PluginViewHarness.detail(sections: [
            .object(["id": .string("local"), "text": .string("Here")]),
            .object(["id": .string("remote"), "title": .string("Remote"), "fetch": .object(["mode": .string("show")])])
        ])
        try harness.present(fetched)
        XCTAssertEqual(harness.provider.presented.map { $0.map(\.id) }, [["remote"]])

        let session = try XCTUnwrap(harness.sessions.session(for: harness.pluginID))
        session.send(.actionChosen("refresh"))
        XCTAssertEqual(harness.provider.presented.count, 1, "Busy alone changes no sections")
        harness.finishEvent(with: .object(["view": PluginViewHarness.detail(sections: [
            .object(["id": .string("other"), "fetch": .object([:])])
        ])]))
        XCTAssertEqual(harness.provider.presented.map { $0.map(\.id) }, [["remote"], ["other"]])

        session.send(.actionChosen("refresh"))
        harness.finishEvent(with: .object(["view": PluginViewHarness.detail(sections: [
            .object(["id": .string("other"), "fetch": .object([:])])
        ])]))
        XCTAssertEqual(harness.provider.presented.count, 3, "The same view answered again asks again")

        try harness.present(PluginViewHarness.detail(sections: [
            .object(["id": .string("other"), "fetch": .object([:])])
        ]))
        XCTAssertEqual(harness.provider.presented.count, 4, "Presenting again asks again")
    }

    func testAToastWithAViewShowsInsideIt() throws {
        try harness.present(PluginViewHarness.form(title: "First"), toast: "Ready")
        XCTAssertEqual(harness.windows.model(for: harness.pluginID)?.toast, "Ready")
        XCTAssertEqual(harness.feedback, [])
    }
}

/// View Sessions whose renderer is the Host's, with stand-in windows, a
/// section provider that records what it hears, and events the test answers.
final class PluginViewHarness {
    static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/ViewGallery.spinnetplugin", isDirectory: true)

    let package: PluginPackage
    var pluginID: PluginID { package.manifest.id }
    var pointer = NSPoint(x: 400, y: 400)
    var frontmost: PluginViewOrigin? = PluginViewOrigin(processIdentifier: 42, name: "TextEdit")
    private(set) var windowsByPlugin: [PluginID: FakePluginViewWindow] = [:]
    private(set) var reports: [String] = []
    private(set) var feedback: [String] = []
    private(set) var events: [HeldEvent] = []
    var stored: [String: JSONValue] = [:]
    var copied: [String] = []
    var opened: [URL] = []
    var inserted: [(String, PluginViewInsertionTarget)] = []
    /// How an insertion finishes before `perform` returns; nil holds it in
    /// `deliveries` until the test finishes it.
    var insertionFinishesAtOnce: PluginHostServiceError?? = .some(nil)
    var deliveries: [(PluginHostServiceError?) -> Void] = []
    var repairs: [PluginViewRepairRoute] = []
    var grants: Set<PluginCapability> = [.writeClipboard, .openURL, .insertIntoFocusedApp]
    let provider = RecordingSectionProvider()
    var scheduled: [(TimeInterval, () -> Void)] = []
    private(set) var windows: PluginViewWindows!
    private(set) var sessions: PluginViewSessions!

    /// `insertionTargets`, when given, is the App the Host shows as where
    /// text goes, and `declaresHostOperations` makes the fixture's views
    /// those of a Plugin declaring Candidate Contract `host_operations`.
    init(insertionTargets: InsertionTargetTracker? = nil, declaresHostOperations: Bool = false) throws {
        package = try PluginManifestLoader.load(packageAt: Self.fixture)
        let manifest = package.manifest
        let hostActions = PluginViewHostActions(
            authorize: { [unowned self] service, action in
                guard action.pluginID == manifest.id else { throw PluginHostServiceError.failed("Not its Action") }
                if let capability = service.requiredCapability, !grants.contains(capability) {
                    throw PluginHostServiceError.capabilityDenied(capability)
                }
            },
            manifest: { $0 == manifest.id ? manifest : nil },
            copyText: { [unowned self] in copied.append($0) },
            openURL: { [unowned self] in opened.append($0) },
            insertText: { [unowned self] text, target, finished in
                inserted.append((text, target))
                if let outcome = insertionFinishesAtOnce { finished(outcome) } else { deliveries.append(finished) }
            },
            openPluginSettings: { [unowned self] _ in repairs.append(.pluginSettings) },
            readSettings: { [unowned self] in $0.resolvedSettings(stored: stored) },
            writeSettings: { [unowned self] _, values in stored = values }
        )
        let environment = PluginViewEnvironment(
            hostActions: hostActions,
            sections: provider,
            settingsFields: { $0 == manifest.id ? manifest.settingsFields : [] },
            pluginName: { $0 == manifest.id ? manifest.name : $0.rawValue },
            repair: { [unowned self] route, _ in repairs.append(route) },
            copy: { [unowned self] in copied.append($0) },
            schedule: { [unowned self] delay, operation in scheduled.append((delay, operation)) },
            report: { [unowned self] in reports.append($0) },
            insertionTargets: insertionTargets
        )
        windows = PluginViewWindows(
            environment: environment,
            makeWindow: { [unowned self] model in
                let window = FakePluginViewWindow()
                windowsByPlugin[model.session.pluginID] = window
                return window
            },
            pointer: { [unowned self] in pointer },
            frontmostApplication: { [unowned self] in frontmost },
            report: { [unowned self] in reports.append($0) }
        )
        sessions = PluginViewSessions(
            renderer: windows,
            runEvent: { [unowned self] action, delivery, _, started, finish in
                events.append(HeldEvent(event: delivery.event, finish: finish, action: action, delivery: delivery))
                started()
            },
            schedule: { _, _ in },
            showFeedback: { [unowned self] in feedback.append($0) },
            readView: { [unowned self] action, view in
                _ = try PluginViewDescription(parsing: view, settingsFields: action.pluginID == pluginID
                                                ? package.manifest.settingsFields : [],
                                              permits: Self.permits(declaresHostOperations))
            },
            permitting: { _ in Self.permits(declaresHostOperations) }
        )
    }

    func window(for pluginID: PluginID? = nil) -> FakePluginViewWindow? {
        let id = pluginID ?? self.pluginID
        return windows.model(for: id) == nil ? nil : windowsByPlugin[id]
    }

    func action(pluginID: PluginID? = nil) throws -> ActionConfiguration {
        let command = try XCTUnwrap(package.manifest.commands.first)
        return try ActionConfiguration(id: ActionID("gallery"), pluginID: pluginID ?? self.pluginID,
                                       command: command, input: .null)
    }

    func present(_ view: JSONValue, pluginID: PluginID? = nil, state: JSONValue = .null, toast: String? = nil) throws {
        var answer: [String: JSONValue] = ["view": view, "state": state]
        if let toast { answer["toast"] = .string(toast) }
        try sessions.actionAnswered(action(pluginID: pluginID), with: .object(answer))
    }

    func finishEvent(with answer: JSONValue) {
        guard let run = events.last else { return XCTFail("No event is running") }
        run.finish(ActionOutcome(actionID: run.action.id, pluginID: run.action.pluginID, title: run.action.title,
                                 terminal: .succeeded(answer)))
    }

    func failEvent(_ category: ActionFailureCategory) {
        guard let run = events.last else { return XCTFail("No event is running") }
        run.finish(ActionOutcome(actionID: run.action.id, pluginID: run.action.pluginID, title: run.action.title,
                                 terminal: .failed(ActionFailure(pluginID: run.action.pluginID, actionID: run.action.id,
                                                                 category: category, message: category.rawValue))))
    }

    static func form(title: String, fields: [JSONValue]? = nil, actions: [JSONValue]? = nil,
                     settings: [String] = []) -> JSONValue {
        var view: [String: JSONValue] = [
            "title": .string(title),
            "form": .object(["fields": .array(fields ?? [
                .object(["key": .string("query"), "kind": .string("text"), "title": .string("Query")])
            ])])
        ]
        if let actions { view["actions"] = .array(actions) }
        if !settings.isEmpty { view["settings"] = .array(settings.map { .object(["key": .string($0)]) }) }
        return .object(view)
    }

    static func detail(sections: [JSONValue], actions: [JSONValue]? = nil) -> JSONValue {
        var view: [String: JSONValue] = ["title": .string("Detail"), "detail": .object(["sections": .array(sections)])]
        if let actions { view["actions"] = .array(actions) }
        return .object(view)
    }
}

/// One View Event's run, held until the test finishes it.
struct HeldEvent {
    let event: PluginViewEvent?
    let finish: (ActionOutcome) -> Void
    let action: ActionConfiguration
    var delivery = ViewEventDelivery.actionStart
}

extension PluginViewHarness {
    /// What a Plugin declaring `host_operations` and `namespaces` may use, or
    /// a Level 1 Plugin.
    static func permits(_ declaresHostOperations: Bool) -> (PluginInterfaceMember) -> Bool {
        { member in
            declaresHostOperations && PluginInterfaceContracts.host.candidates.contains { $0.members.contains(member) }
        }
    }
}

final class FakePluginViewWindow: PluginViewWindow {
    var onResignKey: (() -> Void)?
    var onUserClose: (() -> Void)?
    private(set) var shownNear: [NSPoint] = []
    private(set) var closes = 0
    private(set) var focuses = 0
    var title = ""
    var floats = false

    func show(near pointer: NSPoint) { shownNear.append(pointer) }
    func focus() { focuses += 1 }
    func close() { closes += 1 }
}

final class RecordingSectionProvider: HostFetchedSectionProvider {
    var onChange: ((PluginViewSession, String) -> Void)?
    private(set) var presented: [[PluginViewSection]] = []
    private(set) var ended: [PluginViewSession] = []
    var states: [String: HostFetchedSectionState] = [:]

    func sectionsPresented(_ sections: [PluginViewSection], in session: PluginViewSession) {
        presented.append(sections)
    }

    func state(ofSection id: String, in session: PluginViewSession) -> HostFetchedSectionState {
        states[id] ?? .loading
    }

    func sessionEnded(_ session: PluginViewSession) { ended.append(session) }
}
