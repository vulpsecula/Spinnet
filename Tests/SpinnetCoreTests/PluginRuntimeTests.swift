import Foundation
import XCTest
import AppKit
@testable import SpinnetCore


/// A test package always has a directory to clean up, but `rootURL` is optional
/// because a Host Command has none.
private func removePackageDirectory(_ package: PluginPackage) {
    guard let rootURL = package.rootURL else { return }
    try? FileManager.default.removeItem(at: rootURL)
}

final class PluginRuntimeTests: XCTestCase {

    func testBundledClipboardHistoryUsesPublicServiceWithoutBackgroundSubscription() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let loaded = try PluginManifestLoader.load(packageAt: root.appendingPathComponent("Plugins/ClipboardHistory.spinnetplugin"))
        // Registered the way the Host registers it, so the test covers the
        // origin that is allowed to present a Host-owned window.
        let package = PluginPackage(rootURL: loaded.rootURL, manifest: loaded.manifest, origin: .bundled)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ClipboardHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        let grants = PluginCapabilityGrantStore()
        let registry = PluginRegistry(grantStore: grants)
        try registry.register(package)
        var launches = 0
        let supervisor = PluginRuntimeSupervisor(helperURL: try XCTUnwrap(helperURLIfBuilt()), registry: registry, grantStore: grants,
            processFactory: { launches += 1; return Process() })
        defer { supervisor.shutdown() }
        try store.applyControl(.configure(enabled: true, paused: false, retentionDays: 1))
        try store.observe(changeCount: 1, content: .init(text: "collected without a helper", type: .text), sourceName: "Notes", sourceBundleID: "notes")
        XCTAssertEqual(launches, 0)
        let action = try ActionConfiguration(id: ActionID("history"), pluginID: package.manifest.id, command: package.manifest.commands[0], input: .null)
        grants.setDecision(.granted, for: package.manifest.id, pluginVersion: package.manifest.version, capability: .readClipboardHistory, scope: package.manifest.scope(for: .readClipboardHistory))
        var queries = 0
        var presentations = 0
        let broker = CapabilityCheckedHostServiceBroker(grantStore: grants, systemPermissionCheck: { _ in false }, selectedTextProvider: { _ in "" }, clipboardWriter: { _ in },
            clipboardHistoryProvider: { types, offset in queries += 1; return try store.query(dataTypes: types, offset: offset) },
            clipboardHistoryPresenter: { shownPackage, shownAction in
                XCTAssertEqual(shownPackage.manifest.id, package.manifest.id)
                XCTAssertEqual(shownAction.id, action.id)
                presentations += 1
            })
        XCTAssertEqual(try supervisor.execute(action, in: package, using: broker), .null)
        // Browsing presents the Host window and reads nothing: the snapshot the
        // reading service returns was never what opened it.
        XCTAssertEqual(queries, 0)
        XCTAssertEqual(presentations, 1)
        supervisor.shutdown()
        try store.observe(changeCount: 2, content: .init(text: "helper retired", type: .text), sourceName: "Notes", sourceBundleID: "notes")
        XCTAssertEqual(launches, 1)
        XCTAssertEqual(queries, 0)
        XCTAssertEqual(try store.query(dataTypes: ["text"]).entries.count, 2)
    }

    func testBundledWindowPositionRequestsEachLayoutWithinTheVisibleFrame() throws {
        let package = try WindowPositionFixture.load()
        let grants = PluginCapabilityGrantStore()
        WindowPositionFixture.grant(package, in: grants)
        let supervisor = PluginRuntimeSupervisor(helperURL: try XCTUnwrap(helperURLIfBuilt()))
        defer { supervisor.shutdown() }

        // A secondary display left of the primary one, below its menu bar, with
        // an odd width so the halves have to share the extra point.
        let visible = WindowRect(x: -1501, y: 25, width: 1501, height: 875)
        var window = FocusedWindow(frame: WindowRect(x: -1400, y: 300, width: 600, height: 401), visibleFrame: visible)
        var frames: [WindowRect] = []
        let broker = CapabilityCheckedHostServiceBroker(
            grantStore: grants, systemPermissionCheck: { _ in true },
            selectedTextProvider: { _ in "" }, clipboardWriter: { _ in },
            focusedWindowProvider: { window }, focusedWindowFrameSetter: { frames.append($0) }
        )
        func run(_ commandID: String) throws -> JSONValue {
            let command = try XCTUnwrap(package.manifest.commands.first { $0.id.rawValue == commandID })
            let action = try ActionConfiguration(id: ActionID(commandID), pluginID: package.manifest.id, command: command, input: .null)
            return try supervisor.execute(action, in: package, using: broker)
        }

        XCTAssertEqual(try run("window.maximize"), .null)
        XCTAssertEqual(try run("window.left_half"), .null)
        XCTAssertEqual(try run("window.right_half"), .null)
        XCTAssertEqual(try run("window.center"), .null)
        window = FocusedWindow(frame: WindowRect(x: -1400, y: 300, width: 2000, height: 1000), visibleFrame: visible)
        XCTAssertEqual(try run("window.center"), .null)
        XCTAssertEqual(frames, [
            visible,
            WindowRect(x: -1501, y: 25, width: 750, height: 875),
            WindowRect(x: -751, y: 25, width: 751, height: 875),
            WindowRect(x: -1050, y: 262, width: 600, height: 401),
            visible
        ])
    }

    /// Every catalogue layout on a secondary display with an odd size and a
    /// negative origin. Adjacent layouts share their boundaries, so they tile
    /// without gaps or overlaps; each boundary rounds down, so the odd points go
    /// to the right-hand or lower cells.
    func testBundledWindowPositionRequestsEveryCatalogueLayoutWithinTheVisibleFrame() throws {
        let package = try WindowPositionFixture.load()
        let grants = PluginCapabilityGrantStore()
        WindowPositionFixture.grant(package, in: grants)
        let supervisor = PluginRuntimeSupervisor(helperURL: try XCTUnwrap(helperURLIfBuilt()))
        defer { supervisor.shutdown() }

        var window = FocusedWindow(frame: WindowRect(x: -1400, y: 100, width: 600, height: 401),
                                   visibleFrame: WindowRect(x: -1501, y: -201, width: 1501, height: 875))
        var frames: [WindowRect] = []
        let broker = CapabilityCheckedHostServiceBroker(
            grantStore: grants, systemPermissionCheck: { _ in true },
            selectedTextProvider: { _ in "" }, clipboardWriter: { _ in },
            focusedWindowProvider: { window }, focusedWindowFrameSetter: { frames.append($0) }
        )
        func assertLayouts(_ expected: KeyValuePairs<String, WindowRect>, file: StaticString = #filePath, line: UInt = #line) throws {
            for (commandID, frame) in expected {
                frames = []
                let command = try XCTUnwrap(package.manifest.commands.first { $0.id.rawValue == commandID }, commandID, file: file, line: line)
                let action = try ActionConfiguration(id: ActionID(commandID), pluginID: package.manifest.id, command: command, input: .null)
                XCTAssertEqual(try supervisor.execute(action, in: package, using: broker), .null, commandID, file: file, line: line)
                XCTAssertEqual(frames, [frame], commandID, file: file, line: line)
            }
        }
        func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> WindowRect {
            WindowRect(x: x, y: y, width: width, height: height)
        }

        // Landscape: thirds and fourths split the width.
        try assertLayouts([
            "window.top_half": rect(-1501, -201, 1501, 437),
            "window.bottom_half": rect(-1501, 236, 1501, 438),
            "window.first_third": rect(-1501, -201, 500, 875),
            "window.center_third": rect(-1001, -201, 500, 875),
            "window.last_third": rect(-501, -201, 501, 875),
            "window.first_two_thirds": rect(-1501, -201, 1000, 875),
            "window.last_two_thirds": rect(-1001, -201, 1001, 875),
            "window.top_left_quarter": rect(-1501, -201, 750, 437),
            "window.top_right_quarter": rect(-751, -201, 751, 437),
            "window.bottom_left_quarter": rect(-1501, 236, 750, 438),
            "window.bottom_right_quarter": rect(-751, 236, 751, 438),
            "window.first_fourth": rect(-1501, -201, 375, 875),
            "window.second_fourth": rect(-1126, -201, 375, 875),
            "window.third_fourth": rect(-751, -201, 375, 875),
            "window.last_fourth": rect(-376, -201, 376, 875),
            "window.top_left_sixth": rect(-1501, -201, 500, 437),
            "window.top_center_sixth": rect(-1001, -201, 500, 437),
            "window.top_right_sixth": rect(-501, -201, 501, 437),
            "window.bottom_left_sixth": rect(-1501, 236, 500, 438),
            "window.bottom_center_sixth": rect(-1001, 236, 500, 438),
            "window.bottom_right_sixth": rect(-501, 236, 501, 438),
            "window.maximize_height": rect(-1400, -201, 600, 875),
            "window.maximize_width": rect(-1501, 100, 1501, 401),
            "window.reasonable_size": rect(-1201, -26, 901, 525),
            "window.move_up": rect(-1400, -201, 600, 401),
            "window.move_down": rect(-1400, 273, 600, 401),
            "window.move_left": rect(-1501, 100, 600, 401),
            "window.move_right": rect(-600, 100, 600, 401)
        ])

        // Portrait: thirds and fourths split the height, the longer edge, and
        // Reasonable Size meets its 900-point height cap.
        window = FocusedWindow(frame: WindowRect(x: 1500, y: 0, width: 600, height: 401),
                               visibleFrame: WindowRect(x: 1440, y: -123, width: 875, height: 1501))
        try assertLayouts([
            "window.first_third": rect(1440, -123, 875, 500),
            "window.center_third": rect(1440, 377, 875, 500),
            "window.last_third": rect(1440, 877, 875, 501),
            "window.first_two_thirds": rect(1440, -123, 875, 1000),
            "window.last_two_thirds": rect(1440, 377, 875, 1001),
            "window.first_fourth": rect(1440, -123, 875, 375),
            "window.second_fourth": rect(1440, 252, 875, 375),
            "window.third_fourth": rect(1440, 627, 875, 375),
            "window.last_fourth": rect(1440, 1002, 875, 376),
            "window.reasonable_size": rect(1615, 178, 525, 900)
        ])

        // A wide display: Reasonable Size meets its 1025-point width cap.
        window = FocusedWindow(frame: WindowRect(x: 10, y: 40, width: 600, height: 401),
                               visibleFrame: WindowRect(x: 0, y: 25, width: 2561, height: 1415))
        try assertLayouts(["window.reasonable_size": rect(768, 308, 1025, 849)])
    }

    /// Running a half again on a window that already fills the current step
    /// moves it to the next one: 1/2 → 2/3 → 1/3 → 1/2. The script keeps no
    /// state, so the step comes from the window's frame, within 2 points. The
    /// 2/3 and 1/3 steps share the thirds layouts' boundaries.
    func testBundledWindowPositionCyclesHalvesFromTheWindowsCurrentFrame() throws {
        let package = try WindowPositionFixture.load()
        let grants = PluginCapabilityGrantStore()
        WindowPositionFixture.grant(package, in: grants)
        let supervisor = PluginRuntimeSupervisor(helperURL: try XCTUnwrap(helperURLIfBuilt()))
        defer { supervisor.shutdown() }

        let visible = WindowRect(x: -1501, y: -201, width: 1501, height: 875)
        var current = WindowRect(x: -1400, y: 100, width: 600, height: 401)
        var frames: [WindowRect] = []
        let broker = CapabilityCheckedHostServiceBroker(
            grantStore: grants, systemPermissionCheck: { _ in true },
            selectedTextProvider: { _ in "" }, clipboardWriter: { _ in },
            focusedWindowProvider: { FocusedWindow(frame: current, visibleFrame: visible) },
            focusedWindowFrameSetter: { frames.append($0) }
        )
        func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> WindowRect {
            WindowRect(x: x, y: y, width: width, height: height)
        }
        /// Runs `commandID` on a window at `from` and asserts the one frame it requests.
        func assertRun(_ commandID: String, from: WindowRect, to expected: WindowRect,
                       file: StaticString = #filePath, line: UInt = #line) throws {
            current = from
            frames = []
            let command = try XCTUnwrap(package.manifest.commands.first { $0.id.rawValue == commandID }, commandID, file: file, line: line)
            let action = try ActionConfiguration(id: ActionID(commandID), pluginID: package.manifest.id, command: command, input: .null)
            XCTAssertEqual(try supervisor.execute(action, in: package, using: broker), .null, commandID, file: file, line: line)
            XCTAssertEqual(frames, [expected], commandID, file: file, line: line)
        }
        let elsewhere = rect(-1400, 100, 600, 401)

        // Each half: a window that matches no step goes to 1/2, then each run
        // moves one step, and 1/3 wraps back to 1/2.
        let cycles: [(String, [WindowRect])] = [
            ("window.left_half", [rect(-1501, -201, 750, 875), rect(-1501, -201, 1000, 875), rect(-1501, -201, 500, 875)]),
            ("window.right_half", [rect(-751, -201, 751, 875), rect(-1001, -201, 1001, 875), rect(-501, -201, 501, 875)]),
            ("window.top_half", [rect(-1501, -201, 1501, 437), rect(-1501, -201, 1501, 583), rect(-1501, -201, 1501, 291)]),
            ("window.bottom_half", [rect(-1501, 236, 1501, 438), rect(-1501, 90, 1501, 584), rect(-1501, 382, 1501, 292)])
        ]
        for (commandID, steps) in cycles {
            try assertRun(commandID, from: elsewhere, to: steps[0])
            try assertRun(commandID, from: steps[0], to: steps[1])
            try assertRun(commandID, from: steps[1], to: steps[2])
            try assertRun(commandID, from: steps[2], to: steps[0])
        }

        // The 2/3 and 1/3 steps are exactly the thirds layouts on a landscape
        // screen, so a cycled window lines up with them.
        try assertRun("window.first_two_thirds", from: elsewhere, to: cycles[0].1[1])
        try assertRun("window.first_third", from: elsewhere, to: cycles[0].1[2])
        try assertRun("window.last_two_thirds", from: elsewhere, to: cycles[1].1[1])
        try assertRun("window.last_third", from: elsewhere, to: cycles[1].1[2])

        // Apps round their frames: 2 points off on every edge still matches the
        // step, 3 points off matches none and starts again at 1/2.
        let leftHalf = cycles[0].1[0]
        try assertRun("window.left_half", from: rect(-1499, -199, 748, 877), to: cycles[0].1[1])
        try assertRun("window.left_half", from: rect(-1503, -203, 752, 873), to: cycles[0].1[1])
        try assertRun("window.left_half", from: rect(-1501, -201, 753, 875), to: leftHalf)
        try assertRun("window.left_half", from: rect(-1504, -201, 750, 875), to: leftHalf)
        try assertRun("window.left_half", from: rect(-1501, -201, 750, 872), to: leftHalf)

        // A step of a different half is not a step of this one.
        try assertRun("window.right_half", from: leftHalf, to: cycles[1].1[0])
        try assertRun("window.top_half", from: leftHalf, to: cycles[2].1[0])

        // Other layouts never cycle: running one again on a window already
        // in it requests the same frame.
        for (commandID, frame) in [
            ("window.first_third", rect(-1501, -201, 500, 875)),
            ("window.first_two_thirds", rect(-1501, -201, 1000, 875)),
            ("window.top_left_quarter", rect(-1501, -201, 750, 437)),
            ("window.first_fourth", rect(-1501, -201, 375, 875)),
            ("window.top_left_sixth", rect(-1501, -201, 500, 437)),
            ("window.maximize", visible)
        ] {
            try assertRun(commandID, from: frame, to: frame)
        }
        try assertRun("window.center", from: rect(-1050, 36, 600, 401), to: rect(-1050, 36, 600, 401))
    }

    func testWindowPositionFailsWithoutMovingAnythingWhenTheWindowCannotBePositioned() throws {
        let package = try WindowPositionFixture.load()
        let registry = PluginRegistry()
        try registry.register(package)
        let grants = PluginCapabilityGrantStore()
        WindowPositionFixture.grant(package, in: grants)
        let command = try XCTUnwrap(package.manifest.commands.first { $0.id.rawValue == "window.maximize" })
        let action = try ActionConfiguration(id: ActionID("maximize"), pluginID: package.manifest.id, command: command, input: .null)
        let window = FocusedWindow(frame: WindowRect(x: 10, y: 40, width: 300, height: 200),
                                   visibleFrame: WindowRect(x: 0, y: 25, width: 1440, height: 875))
        func outcome(read: @escaping () throws -> FocusedWindow,
                     set: @escaping (WindowRect) throws -> Void) throws -> ActionTerminalOutcome {
            let broker = CapabilityCheckedHostServiceBroker(
                grantStore: grants, systemPermissionCheck: { _ in true },
                selectedTextProvider: { _ in "" }, clipboardWriter: { _ in },
                focusedWindowProvider: read, focusedWindowFrameSetter: set
            )
            return HostActionRunner(
                executor: NoopHostCommandExecutor(),
                scriptedExecutor: PluginRuntimeSupervisor(helperURL: try XCTUnwrap(helperURLIfBuilt())),
                hostServiceBroker: broker
            ).invoke(action, using: registry).terminal
        }

        // No readable focused window: the script never reaches the setter.
        var frames: [WindowRect] = []
        let unreadable = try outcome(read: { throw PluginHostServiceError.unavailable("No focused window") },
                                     set: { frames.append($0) })
        guard case .failed(let unreadableFailure) = unreadable else {
            return XCTFail("A missing window should fail the Action")
        }
        XCTAssertEqual(unreadableFailure.category, .hostServiceFailed)
        XCTAssertEqual(frames, [], "The script fell through to moving a window")

        // A window that reports its frame but refuses a new one.
        var attempts: [WindowRect] = []
        let refused = try outcome(read: { window }, set: {
            attempts.append($0)
            throw PluginHostServiceError.unavailable("The focused window cannot be moved or resized")
        })
        guard case .failed(let refusedFailure) = refused else {
            return XCTFail("A non-settable window should fail the Action")
        }
        XCTAssertEqual(refusedFailure.category, .hostServiceFailed)
        XCTAssertEqual(attempts, [window.visibleFrame], "Only the focused window's layout was requested")
    }

    /// Toggle Full Screen asks for the full-screen service alone: it neither
    /// reads nor sets a frame, and a window that refuses fails the Action.
    func testWindowPositionTogglesFullScreenThroughItsOwnService() throws {
        let package = try WindowPositionFixture.load()
        let registry = PluginRegistry()
        try registry.register(package)
        let grants = PluginCapabilityGrantStore()
        WindowPositionFixture.grant(package, in: grants)
        let command = try XCTUnwrap(package.manifest.commands.first { $0.id.rawValue == "window.toggle_full_screen" })
        XCTAssertEqual(command.title, "Toggle Full Screen")
        let action = try ActionConfiguration(id: ActionID("full-screen"), pluginID: package.manifest.id, command: command, input: .null)
        var reads = 0
        var frames: [WindowRect] = []
        func outcome(toggle: @escaping () throws -> Void) throws -> ActionTerminalOutcome {
            let broker = CapabilityCheckedHostServiceBroker(
                grantStore: grants, systemPermissionCheck: { _ in true },
                selectedTextProvider: { _ in "" }, clipboardWriter: { _ in },
                focusedWindowProvider: {
                    reads += 1
                    return FocusedWindow(frame: WindowRect(x: 0, y: 0, width: 10, height: 10),
                                         visibleFrame: WindowRect(x: 0, y: 25, width: 1440, height: 875))
                },
                focusedWindowFrameSetter: { frames.append($0) },
                focusedWindowFullScreenToggler: toggle
            )
            return HostActionRunner(
                executor: NoopHostCommandExecutor(),
                scriptedExecutor: PluginRuntimeSupervisor(helperURL: try XCTUnwrap(helperURLIfBuilt())),
                hostServiceBroker: broker
            ).invoke(action, using: registry).terminal
        }

        var toggles = 0
        guard case .succeeded = try outcome(toggle: { toggles += 1 }) else {
            return XCTFail("Toggling a window that allows full screen should succeed")
        }
        XCTAssertEqual(toggles, 1)

        let refused = try outcome(toggle: {
            throw PluginHostServiceError.unavailable("The focused window cannot enter or leave full screen")
        })
        guard case .failed(let failure) = refused else {
            return XCTFail("A window that refuses full screen should fail the Action")
        }
        XCTAssertEqual(failure.category, .hostServiceFailed)
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(frames, [])
    }

    func testBundledWindowPositionMovesTheWindowBetweenDisplays() throws {
        let package = try WindowPositionFixture.load()
        let grants = PluginCapabilityGrantStore()
        WindowPositionFixture.grant(package, in: grants)
        let supervisor = PluginRuntimeSupervisor(helperURL: try XCTUnwrap(helperURLIfBuilt()))
        defer { supervisor.shutdown() }

        // Left to right: a larger display with a negative origin, the primary
        // display below its menu bar, and a smaller display set higher up.
        let large = WindowRect(x: -1920, y: -100, width: 1920, height: 1080)
        let primary = WindowRect(x: 0, y: 25, width: 1440, height: 875)
        let small = WindowRect(x: 1440, y: -375, width: 1280, height: 775)
        var window = FocusedWindow(frame: primary, visibleFrame: primary)
        var frames: [WindowRect] = []
        let broker = CapabilityCheckedHostServiceBroker(
            grantStore: grants, systemPermissionCheck: { _ in true },
            selectedTextProvider: { _ in "" }, clipboardWriter: { _ in },
            focusedWindowProvider: { window }, focusedWindowFrameSetter: { frames.append($0) }
        )
        func move(_ frame: WindowRect, on index: Int, of displays: [WindowRect], _ commandID: String) throws -> WindowRect? {
            window = FocusedWindow(frame: frame, visibleFrame: displays[index], displays: displays, displayIndex: index)
            frames = []
            let command = try XCTUnwrap(package.manifest.commands.first { $0.id.rawValue == commandID })
            let action = try ActionConfiguration(id: ActionID(commandID), pluginID: package.manifest.id, command: command, input: .null)
            XCTAssertEqual(try supervisor.execute(action, in: package, using: broker), .null)
            XCTAssertLessThanOrEqual(frames.count, 1)
            return frames.first
        }
        let next = "window.next_display", previous = "window.previous_display"
        let three = [large, primary, small]
        let two = [primary, small]

        // Halfway across the free width and a fifth of the way down the free
        // height stays so on the target display, at the same size.
        let centred = WindowRect(x: 420, y: 120, width: 600, height: 400)
        XCTAssertEqual(try move(centred, on: 1, of: three, next), WindowRect(x: 1780, y: -300, width: 600, height: 400))
        XCTAssertEqual(try move(centred, on: 1, of: three, previous), WindowRect(x: -1260, y: 36, width: 600, height: 400))

        // Both commands wrap around the ends of the list.
        let wide = WindowRect(x: -1800, y: 240, width: 1600, height: 600)
        XCTAssertEqual(try move(wide, on: 0, of: three, previous), WindowRect(x: 1440, y: -251, width: 1280, height: 600))
        let onSmall = WindowRect(x: 1780, y: -300, width: 600, height: 400)
        XCTAssertEqual(try move(onSmall, on: 2, of: three, next), WindowRect(x: -1260, y: 36, width: 600, height: 400))

        // Only a dimension larger than the target is shrunk.
        XCTAssertEqual(try move(wide, on: 0, of: three, next), WindowRect(x: 0, y: 220, width: 1440, height: 600))
        XCTAssertEqual(try move(large, on: 0, of: three, next), primary)
        XCTAssertEqual(try move(primary, on: 1, of: three, previous), WindowRect(x: -1920, y: -100, width: 1440, height: 875))

        // A window hanging off its visible frame lands wholly inside the target.
        let hanging = WindowRect(x: -50, y: 0, width: 600, height: 400)
        XCTAssertEqual(try move(hanging, on: 1, of: three, next), WindowRect(x: 1440, y: -375, width: 600, height: 400))

        // With two displays either command reaches the other one, and back.
        XCTAssertEqual(try move(centred, on: 0, of: two, next), onSmall)
        XCTAssertEqual(try move(centred, on: 0, of: two, previous), onSmall)
        XCTAssertEqual(try move(onSmall, on: 1, of: two, next), centred)
        XCTAssertEqual(try move(onSmall, on: 1, of: two, previous), centred)

        // A single display leaves the window where it is and succeeds.
        XCTAssertNil(try move(centred, on: 0, of: [primary], next))
        XCTAssertNil(try move(centred, on: 0, of: [primary], previous))
    }

    /// Restore asks the Host to put the window back and supplies nothing: no
    /// window, no frame, and no read of the window first.
    func testBundledWindowPositionRestoreRequestsTheHostRestore() throws {
        let package = try WindowPositionFixture.load()
        let registry = PluginRegistry()
        try registry.register(package)
        let grants = PluginCapabilityGrantStore()
        WindowPositionFixture.grant(package, in: grants)
        let command = try XCTUnwrap(package.manifest.commands.first { $0.id.rawValue == "window.restore" })
        let action = try ActionConfiguration(id: ActionID("restore"), pluginID: package.manifest.id, command: command, input: .null)
        var reads = 0
        var frames: [WindowRect] = []
        func outcome(restore: @escaping () throws -> Void) throws -> ActionTerminalOutcome {
            let broker = CapabilityCheckedHostServiceBroker(
                grantStore: grants, systemPermissionCheck: { _ in true },
                selectedTextProvider: { _ in "" }, clipboardWriter: { _ in },
                focusedWindowProvider: { reads += 1; throw PluginHostServiceError.unavailable("No focused window") },
                focusedWindowFrameSetter: { frames.append($0) },
                focusedWindowFrameRestorer: restore
            )
            return HostActionRunner(
                executor: NoopHostCommandExecutor(),
                scriptedExecutor: PluginRuntimeSupervisor(helperURL: try XCTUnwrap(helperURLIfBuilt())),
                hostServiceBroker: broker
            ).invoke(action, using: registry).terminal
        }

        var restores = 0
        guard case .succeeded = try outcome(restore: { restores += 1 }) else {
            return XCTFail("Restoring a moved window should succeed")
        }
        XCTAssertEqual(restores, 1)

        let nothing = try outcome(restore: { throw PluginHostServiceError.nothingToRestore })
        guard case .failed(let failure) = nothing else {
            return XCTFail("A window Spinnet never moved should fail the Action")
        }
        XCTAssertEqual(failure.category, .hostServiceFailed)
        XCTAssertTrue(failure.message.contains("nothing to restore"), failure.message)
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(frames, [])
    }

    func testInvocationSchemaDeclaresItsMessageVariant() throws {
        let invocation = PluginRuntimeInvocation(
            pluginID: PluginID("com.example.fixture"),
            actionID: ActionID("action-1"),
            commandID: CommandID("fixture.transform_text"),
            scriptPath: "transform-text.js",
            scriptSource: "input",
            input: .string("value")
        )
        let data = try JSONEncoder().encode(invocation)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(object["type"] as? String, "invocation")

        var unsupported = object
        unsupported["type"] = "host_service_request"
        let unsupportedData = try JSONSerialization.data(withJSONObject: unsupported)
        XCTAssertThrowsError(
            try JSONDecoder().decode(PluginRuntimeInvocation.self, from: unsupportedData)
        )
    }

    func testConnectionBindsPluginAndEnforcesRequestLifecycle() throws {
        let pluginID = PluginID("com.example.fixture")
        let connection = PluginRuntimeConnection(pluginID: pluginID)
        let invocation = PluginRuntimeInvocation(
            invocationID: "invocation-1",
            pluginID: pluginID,
            actionID: ActionID("action-1"),
            commandID: CommandID("fixture.transform_text"),
            scriptPath: "transform-text.js",
            scriptSource: "input",
            input: .string("value")
        )

        let requestData = try connection.prepareInvocation(invocation)
        XCTAssertEqual(try PluginRuntimeProtocol.decodeInvocation(requestData), invocation)

        let response = PluginRuntimeResponse(
            invocationID: invocation.invocationID,
            actionID: invocation.actionID,
            terminal: .succeeded(.string("result"))
        )
        XCTAssertEqual(
            try connection.acceptResponse(response),
            response.terminal
        )

        let duplicateAction = PluginRuntimeInvocation(
            invocationID: "invocation-2",
            pluginID: pluginID,
            actionID: invocation.actionID,
            commandID: invocation.commandID,
            scriptPath: invocation.scriptPath,
            scriptSource: invocation.scriptSource,
            input: invocation.input
        )
        let duplicateConnection = PluginRuntimeConnection(pluginID: pluginID)
        _ = try duplicateConnection.prepareInvocation(invocation)
        _ = try duplicateConnection.acceptResponse(response)
        XCTAssertThrowsError(try duplicateConnection.prepareInvocation(duplicateAction))

        let duplicateInvocation = PluginRuntimeInvocation(
            invocationID: invocation.invocationID,
            pluginID: pluginID,
            actionID: ActionID("action-2"),
            commandID: invocation.commandID,
            scriptPath: invocation.scriptPath,
            scriptSource: invocation.scriptSource,
            input: invocation.input
        )
        let duplicateRequestConnection = PluginRuntimeConnection(pluginID: pluginID)
        _ = try duplicateRequestConnection.prepareInvocation(invocation)
        _ = try duplicateRequestConnection.acceptResponse(response)
        XCTAssertThrowsError(
            try duplicateRequestConnection.prepareInvocation(duplicateInvocation)
        )

        let outOfOrderConnection = PluginRuntimeConnection(pluginID: pluginID)
        XCTAssertThrowsError(try outOfOrderConnection.acceptResponse(response))

        let impersonation = PluginRuntimeInvocation(
            invocationID: "invocation-3",
            pluginID: PluginID("com.example.other"),
            actionID: ActionID("action-3"),
            commandID: invocation.commandID,
            scriptPath: invocation.scriptPath,
            scriptSource: invocation.scriptSource,
            input: invocation.input
        )
        let freshConnection = PluginRuntimeConnection(pluginID: pluginID)
        XCTAssertThrowsError(try freshConnection.prepareInvocation(impersonation))
    }

    func testHostServiceMessagesRoundTripThroughTheBoundConnection() throws {
        let pluginID = PluginID("com.example.fixture")
        let actionID = ActionID("action-1")
        let connection = PluginRuntimeConnection(pluginID: pluginID)
        let invocation = PluginRuntimeInvocation(
            invocationID: "invocation-1",
            pluginID: pluginID,
            actionID: actionID,
            commandID: CommandID("fixture.transform_text"),
            scriptPath: "transform-text.js",
            scriptSource: "input",
            input: .string("value")
        )
        _ = try connection.prepareInvocation(invocation)

        let request = PluginRuntimeHostServiceRequest(
            invocationID: invocation.invocationID,
            actionID: actionID,
            requestID: "service-request-1",
            service: .readSelectedText,
            input: .null
        )
        let requestData = try PluginRuntimeProtocol.encodeHostServiceRequest(request)
        let decodedRequest = try PluginRuntimeProtocol.decodeHostServiceRequest(requestData)
        XCTAssertEqual(try connection.acceptHostServiceRequest(decodedRequest), request)

        let serviceResponse = PluginRuntimeHostServiceResponse(
            invocationID: invocation.invocationID,
            actionID: actionID,
            requestID: request.requestID,
            outcome: .succeeded(.string("selected text"))
        )
        let responseData = try connection.prepareHostServiceResponse(serviceResponse)
        XCTAssertEqual(
            try PluginRuntimeProtocol.decodeHostServiceResponse(responseData),
            serviceResponse
        )

        let terminal = PluginRuntimeResponse(
            invocationID: invocation.invocationID,
            actionID: actionID,
            terminal: .succeeded(.string("done"))
        )
        XCTAssertEqual(try connection.acceptResponse(terminal), terminal.terminal)
    }

    func testInvocationMessageLimitAcceptsAtMostOneMiB() throws {
        let base = try PluginRuntimeProtocol.encodeInvocation(
            makeInvocation(scriptSource: "")
        ).count
        let below = makeInvocation(
            scriptSource: String(repeating: "x", count: PluginRuntimeProtocol.maximumMessageBytes - base - 1)
        )
        let at = makeInvocation(
            scriptSource: String(repeating: "x", count: PluginRuntimeProtocol.maximumMessageBytes - base)
        )
        let above = makeInvocation(
            scriptSource: String(repeating: "x", count: PluginRuntimeProtocol.maximumMessageBytes - base + 1)
        )

        XCTAssertEqual(
            try PluginRuntimeProtocol.encodeInvocation(below).count,
            PluginRuntimeProtocol.maximumMessageBytes - 1
        )
        XCTAssertEqual(
            try PluginRuntimeProtocol.encodeInvocation(at).count,
            PluginRuntimeProtocol.maximumMessageBytes
        )
        XCTAssertEqual(
            try PluginRuntimeProtocol.decodeInvocation(
                PluginRuntimeProtocol.encodeInvocation(at)
            ),
            at
        )
        XCTAssertThrowsError(try PluginRuntimeProtocol.encodeInvocation(above))
    }

    func testResponseMessageLimitAcceptsAtMostOneMiB() throws {
        let makeResponse: (String) -> PluginRuntimeResponse = { value in
            PluginRuntimeResponse(
                invocationID: "invocation-1",
                actionID: ActionID("action-1"),
                terminal: .succeeded(.string(value))
            )
        }
        let base = try PluginRuntimeProtocol.encodeResponse(makeResponse("")).count
        let below = makeResponse(
            String(repeating: "x", count: PluginRuntimeProtocol.maximumMessageBytes - base - 1)
        )
        let at = makeResponse(
            String(repeating: "x", count: PluginRuntimeProtocol.maximumMessageBytes - base)
        )
        let above = makeResponse(
            String(repeating: "x", count: PluginRuntimeProtocol.maximumMessageBytes - base + 1)
        )

        XCTAssertEqual(
            try PluginRuntimeProtocol.encodeResponse(below).count,
            PluginRuntimeProtocol.maximumMessageBytes - 1
        )
        XCTAssertEqual(
            try PluginRuntimeProtocol.encodeResponse(at).count,
            PluginRuntimeProtocol.maximumMessageBytes
        )
        XCTAssertEqual(
            try PluginRuntimeProtocol.decodeResponse(
                PluginRuntimeProtocol.encodeResponse(at)
            ),
            at
        )
        XCTAssertThrowsError(try PluginRuntimeProtocol.encodeResponse(above))
    }

    func testPublicFrameReaderEnforcesOneMiBBodyLimitAtPipeBoundary() throws {
        let below = Data(repeating: 0x78, count: PluginRuntimeProtocol.maximumMessageBytes - 1)
        let at = Data(repeating: 0x78, count: PluginRuntimeProtocol.maximumMessageBytes)
        let above = Data(repeating: 0x78, count: PluginRuntimeProtocol.maximumMessageBytes + 1)

        XCTAssertEqual(try readFramedBody(below)?.count, below.count)
        XCTAssertEqual(try readFramedBody(at)?.count, at.count)
        XCTAssertThrowsError(try readFramedBody(above))
    }

    func testResponseSchemaRejectsUnsupportedVersionsAndVariants() throws {
        let response = PluginRuntimeResponse(
            invocationID: "invocation-1",
            actionID: ActionID("action-1"),
            terminal: .succeeded(.null)
        )
        let encoded = try PluginRuntimeProtocol.encodeResponse(response)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        object["protocol_version"] = "2.0"
        let unsupportedVersion = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(
            try PluginRuntimeProtocol.decodeResponse(unsupportedVersion)
        )

        object["protocol_version"] = PluginRuntimeProtocol.version
        object["type"] = "progress"
        let unsupportedType = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(
            try PluginRuntimeProtocol.decodeResponse(unsupportedType)
        )

        var invocation = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: PluginRuntimeProtocol.encodeInvocation(makeInvocation(scriptSource: "input"))
            ) as? [String: Any]
        )
        invocation["protocol_version"] = "2.0"
        let unsupportedInvocationVersion = try JSONSerialization.data(withJSONObject: invocation)
        XCTAssertThrowsError(
            try PluginRuntimeProtocol.decodeInvocation(unsupportedInvocationVersion)
        )
    }

    func testSchemasRejectMalformedValuesAndUnknownTerminalKinds() throws {
        var invocation = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: PluginRuntimeProtocol.encodeInvocation(makeInvocation(scriptSource: "input"))
            ) as? [String: Any]
        )
        invocation["action_id"] = "   "
        let emptyActionID = try JSONSerialization.data(withJSONObject: invocation)
        XCTAssertThrowsError(try PluginRuntimeProtocol.decodeInvocation(emptyActionID))

        let response = PluginRuntimeResponse(
            invocationID: "invocation-1",
            actionID: ActionID("action-1"),
            terminal: .succeeded(.null)
        )
        var terminal = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: PluginRuntimeProtocol.encodeResponse(response)
            ) as? [String: Any]
        )
        terminal["terminal"] = ["kind": "progress", "result": NSNull()]
        let unknownTerminal = try JSONSerialization.data(withJSONObject: terminal)
        XCTAssertThrowsError(try PluginRuntimeProtocol.decodeResponse(unknownTerminal))

        terminal["terminal"] = [
            "kind": "succeeded",
            "result": NSNull(),
            "failure": ["category": "helper_error", "message": "unexpected"]
        ]
        let ambiguousTerminal = try JSONSerialization.data(withJSONObject: terminal)
        XCTAssertThrowsError(try PluginRuntimeProtocol.decodeResponse(ambiguousTerminal))

        let connection = PluginRuntimeConnection(pluginID: PluginID("com.example.fixture"))
        XCTAssertThrowsError(try connection.acceptResponse(response))
        XCTAssertEqual(connection.state, .closed)
    }

    func testHelperIdentityAndCapabilityClaimsAreNotPartOfResponseAuthority() throws {
        let pluginID = PluginID("com.example.fixture")
        let invocation = makeInvocation(scriptSource: "input")
        let connection = PluginRuntimeConnection(pluginID: pluginID)
        _ = try connection.prepareInvocation(invocation)

        let response = PluginRuntimeResponse(
            invocationID: invocation.invocationID,
            actionID: invocation.actionID,
            terminal: .succeeded(.string("result"))
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: PluginRuntimeProtocol.encodeResponse(response)
            ) as? [String: Any]
        )
        object["plugin_id"] = "com.example.impersonator"
        object["capabilities"] = ["clipboard.read", "network"]
        let claimed = try JSONSerialization.data(withJSONObject: object)

        let decoded = try PluginRuntimeProtocol.decodeResponse(claimed)
        XCTAssertEqual(try connection.acceptResponse(decoded), .succeeded(.string("result")))
    }

    func testMalformedHelperTerminatesOnlyItsActionAndSecondPluginStillRuns() throws {
        let helperURL = try XCTUnwrap(
            helperURLIfBuilt(),
            "Build SpinnetPluginHelper before running integration tests"
        )
        let hostileHelperURL = try makeShellHelper(
            """
            #!/bin/sh
            IFS= read -r request
            printf '%s\\n' '{"type":"progress","protocol_version":"1.0","invocation_id":"wrong","action_id":"wrong","terminal":{"kind":"succeeded","result":null}}'
            """
        )
        defer { try? FileManager.default.removeItem(at: hostileHelperURL) }

        let first = try makeScriptedPackage(
            pluginID: PluginID("com.example.first"),
            script: "input"
        )
        let second = try makeScriptedPackage(
            pluginID: PluginID("com.example.second"),
            script: "input"
        )
        defer {
            removePackageDirectory(first)
            removePackageDirectory(second)
        }

        let firstAction = try ActionConfiguration(
            id: ActionID("first-action"),
            pluginID: first.manifest.id,
            command: first.manifest.commands[0],
            input: .string("first")
        )
        let secondAction = try ActionConfiguration(
            id: ActionID("second-action"),
            pluginID: second.manifest.id,
            command: second.manifest.commands[0],
            input: .string("second")
        )
        let registry = PluginRegistry()
        try registry.register(first)
        try registry.register(second)

        let failed = HostActionRunner(
            executor: NoopHostCommandExecutor(),
            scriptedExecutor: PluginRuntimeSupervisor(helperURL: hostileHelperURL)
        ).invoke(firstAction, using: registry)
        guard case .failed(let failure) = failed.terminal else {
            return XCTFail("A hostile terminal message should fail its Action")
        }
        XCTAssertEqual(failure.category, .runtimeProtocolFailed)
        XCTAssertEqual(failure.pluginID, firstAction.pluginID)
        XCTAssertEqual(failure.actionID, firstAction.id)

        let secondOutcome = HostActionRunner(
            executor: NoopHostCommandExecutor(),
            scriptedExecutor: PluginRuntimeSupervisor(helperURL: helperURL)
        ).invoke(secondAction, using: registry)
        XCTAssertEqual(secondOutcome.terminal, .succeeded(.string("second")))
    }

    func testOversizedHelperResponseFailsClosedWithoutAffectingAnotherPlugin() throws {
        let helperURL = try XCTUnwrap(
            helperURLIfBuilt(),
            "Build SpinnetPluginHelper before running integration tests"
        )
        let oversizedHelperURL = try makeShellHelper(
            """
            #!/bin/sh
            IFS= read -r request
            printf '%s' '{"type":"terminal","protocol_version":"1.0","invocation_id":"wrong","action_id":"wrong","terminal":{"kind":"succeeded","result":"'
            awk 'BEGIN { for (i = 0; i < 1048500; i++) printf "x" }'
            printf '%s\\n' '"}}'
            """
        )
        defer { try? FileManager.default.removeItem(at: oversizedHelperURL) }

        let first = try makeScriptedPackage(
            pluginID: PluginID("com.example.oversized"),
            script: "input"
        )
        let second = try makeScriptedPackage(
            pluginID: PluginID("com.example.after-oversized"),
            script: "input"
        )
        defer {
            removePackageDirectory(first)
            removePackageDirectory(second)
        }
        let firstAction = try ActionConfiguration(
            id: ActionID("oversized-action"),
            pluginID: first.manifest.id,
            command: first.manifest.commands[0],
            input: .string("first")
        )
        let secondAction = try ActionConfiguration(
            id: ActionID("after-oversized-action"),
            pluginID: second.manifest.id,
            command: second.manifest.commands[0],
            input: .string("second")
        )
        let registry = PluginRegistry()
        try registry.register(first)
        try registry.register(second)

        let failed = HostActionRunner(
            executor: NoopHostCommandExecutor(),
            scriptedExecutor: PluginRuntimeSupervisor(helperURL: oversizedHelperURL)
        ).invoke(firstAction, using: registry)
        guard case .failed(let failure) = failed.terminal else {
            return XCTFail("An oversized terminal message should fail its Action")
        }
        XCTAssertEqual(failure.category, .runtimeProtocolFailed)

        let secondOutcome = HostActionRunner(
            executor: NoopHostCommandExecutor(),
            scriptedExecutor: PluginRuntimeSupervisor(helperURL: helperURL)
        ).invoke(secondAction, using: registry)
        XCTAssertEqual(secondOutcome.terminal, .succeeded(.string("second")))
    }

    func testLateDuplicateTerminalRetiresHelperWithoutReplayingFinishedAction() throws {
        let duplicateHelperURL = try makeShellHelper(
            """
            #!/bin/sh
            IFS= read -r request
            invocation_id=$(printf '%s' "$request" | sed -n 's/.*"invocation_id":"\\([^"]*\\)".*/\\1/p')
            action_id=$(printf '%s' "$request" | sed -n 's/.*"action_id":"\\([^"]*\\)".*/\\1/p')
            response=$(printf '{"type":"terminal","protocol_version":"1.0","invocation_id":"%s","action_id":"%s","terminal":{"kind":"succeeded","result":null}}' "$invocation_id" "$action_id")
            printf '%s\\n' "$response"
            sleep 1
            printf '%s\\n' "$response"
            while :; do :; done
            """
        )
        defer { try? FileManager.default.removeItem(at: duplicateHelperURL) }

        let package = try makeScriptedPackage(
            pluginID: PluginID("com.example.duplicate"),
            script: "input"
        )
        defer { removePackageDirectory(package) }
        let action = try ActionConfiguration(
            id: ActionID("duplicate-action"),
            pluginID: package.manifest.id,
            command: package.manifest.commands[0],
            input: .string("value")
        )
        let registry = PluginRegistry()
        try registry.register(package)

        var processes: [Process] = []
        let supervisor = PluginRuntimeSupervisor(helperURL: duplicateHelperURL,
            processFactory: { let process = Process(); processes.append(process); return process })
        defer { supervisor.shutdown() }
        let runner = HostActionRunner(
            executor: NoopHostCommandExecutor(),
            scriptedExecutor: supervisor)
        let outcome = runner.invoke(action, using: registry)
        XCTAssertEqual(outcome.terminal, .succeeded(.null))
        assertExits(processes[0])
        XCTAssertEqual(processes[0].terminationStatus, SIGKILL)
        XCTAssertEqual(supervisor.launchCount, 1, "Retirement must not replay work")
        XCTAssertEqual(runner.invoke(try action.newInvocation(), using: registry).terminal, .succeeded(.null))
        XCTAssertEqual(supervisor.launchCount, 2)
    }

    func testCancellationTerminatesOnlyTheAffectedHelperWithin250Milliseconds() throws {
        let helper = try XCTUnwrap(helperURLIfBuilt())
        let package = try makeScriptedPackage(pluginID: PluginID("test.cancel"), script: "while (true) {}")
        defer { removePackageDirectory(package) }
        let action = try ActionConfiguration(id: ActionID("cancel"), pluginID: package.manifest.id,
            command: package.manifest.commands[0], input: .null)
        let process = Process()
        let control = ActionExecutionControl()
        let completed = expectation(description: "cancelled execution finished")
        DispatchQueue.global().async {
            defer { completed.fulfill() }
            do {
                _ = try PluginRuntimeSupervisor(helperURL: helper, processFactory: { process })
                    .execute(action, in: package, using: nil, control: control)
                XCTFail("The cancelled script must not succeed")
            } catch {
                XCTAssertEqual(error as? PluginRuntimeError, .cancelled)
            }
        }
        let launchDeadline = ProcessInfo.processInfo.systemUptime + 2
        while !process.isRunning && ProcessInfo.processInfo.systemUptime < launchDeadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertTrue(process.isRunning)
        let cancelledAt = ProcessInfo.processInfo.systemUptime
        control.stop(.cancelled)
        wait(for: [completed], timeout: 0.25)
        XCTAssertFalse(process.isRunning)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - cancelledAt, 0.25)

        let healthy = try makeScriptedPackage(pluginID: PluginID("test.healthy"), script: "42")
        defer { removePackageDirectory(healthy) }
        let healthyAction = try ActionConfiguration(id: ActionID("healthy"), pluginID: healthy.manifest.id,
            command: healthy.manifest.commands[0], input: .null)
        XCTAssertEqual(try PluginRuntimeSupervisor(helperURL: helper).execute(healthyAction, in: healthy), .number(42))
    }

    func testCancellationDuringHostServiceWorkKillsHelperAndRejectsLateServiceResult() throws {
        let helper = try XCTUnwrap(helperURLIfBuilt())
        let package = try loadFixturePackage()
        let command = try XCTUnwrap(package.manifest.commands.first { $0.execution == .javascript })
        let action = try ActionConfiguration(id: ActionID("blocked-service"), pluginID: package.manifest.id,
                                            command: command, input: .null)
        let grants = PluginCapabilityGrantStore()
        for capability in [PluginCapability.readSelectedText, .writeClipboard] {
            grants.setDecision(.granted, for: package.manifest.id,
                               pluginVersion: package.manifest.version, capability: capability)
        }
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let broker = CapabilityCheckedHostServiceBroker(grantStore: grants,
            systemPermissionCheck: { _ in true }, selectedTextProvider: { _ in
                entered.signal()
                _ = release.wait(timeout: .now() + 5)
                return "late result"
            }, clipboardWriter: { _ in XCTFail("Cancelled execution must not request another service") })
        let process = Process()
        let control = ActionExecutionControl()
        let completed = expectation(description: "late service discarded")
        DispatchQueue.global().async {
            defer { completed.fulfill() }
            do {
                _ = try PluginRuntimeSupervisor(helperURL: helper, processFactory: { process })
                    .execute(action, in: package, using: broker, control: control)
                XCTFail("Cancelled execution cannot succeed")
            } catch { XCTAssertEqual(error as? PluginRuntimeError, .cancelled) }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        control.stop(.cancelled)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertFalse(process.isRunning)
        release.signal()
        wait(for: [completed], timeout: 1)
    }

    func testExternalHelperTerminationHasAStableCategory() throws {
        let helper = try makeShellHelper("#!/bin/sh\nkill -TERM $$\n")
        defer { try? FileManager.default.removeItem(at: helper) }
        let package = try makeScriptedPackage(pluginID: PluginID("test.terminated"), script: "input")
        defer { removePackageDirectory(package) }
        let action = try ActionConfiguration(id: ActionID("terminated"), pluginID: package.manifest.id,
                                            command: package.manifest.commands[0], input: .null)
        XCTAssertThrowsError(try PluginRuntimeSupervisor(helperURL: helper).execute(action, in: package)) {
            XCTAssertEqual($0 as? PluginRuntimeError, .helperTerminated)
        }
    }

    func testSilentHelperReachesAStableTimeoutAtTheActionDeadline() throws {
        let silentHelperURL = try makeShellHelper(
            """
            #!/bin/sh
            IFS= read -r request
            sleep 10
            """
        )
        defer { try? FileManager.default.removeItem(at: silentHelperURL) }

        let package = try loadFixturePackage()
        let command = try XCTUnwrap(package.manifest.commands.first {
            $0.id == CommandID("fixture.transform_text")
        })
        let action = try ActionConfiguration(
            id: ActionID("fixture-transform-silent"),
            pluginID: package.manifest.id,
            command: command,
            input: .string("Spinnet Plugin fixture")
        )
        let registry = PluginRegistry()
        try registry.register(package)

        let invokedAt = ProcessInfo.processInfo.systemUptime
        let outcome = HostActionRunner(
            executor: NoopHostCommandExecutor(),
            scriptedExecutor: PluginRuntimeSupervisor(helperURL: silentHelperURL, processFactory: {
                Thread.sleep(forTimeInterval: 0.4)
                return Process()
            })
        ).invoke(action, using: registry)
        guard case .failed(let failure) = outcome.terminal else {
            return XCTFail("A silent helper should produce a terminal timeout")
        }
        XCTAssertEqual(failure.category, .timedOut)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - invokedAt, 4.25)
    }

    func testFixtureTextCommandRunsInTheJavaScriptCoreHelper() throws {
        let helperURL = try XCTUnwrap(helperURLIfBuilt(), "Build SpinnetPluginHelper before running integration tests")
        let package = try loadFixturePackage()
        let command = try XCTUnwrap(package.manifest.commands.first {
            $0.id == CommandID("fixture.transform_text")
        })
        let action = try ActionConfiguration(
            id: ActionID("fixture-transform-text"),
            pluginID: package.manifest.id,
            command: command,
            input: .string("Spinnet Plugin fixture")
        )

        let grantStore = PluginCapabilityGrantStore()
        grantStore.setDecision(
            .granted,
            for: package.manifest.id,
            pluginVersion: package.manifest.version,
            capability: .readSelectedText
        )
        grantStore.setDecision(
            .granted,
            for: package.manifest.id,
            pluginVersion: package.manifest.version,
            capability: .writeClipboard
        )
        var clipboardValue: String?
        let hostServiceBroker = CapabilityCheckedHostServiceBroker(
            grantStore: grantStore,
            systemPermissionCheck: { _ in true },
            selectedTextProvider: { _ in "Spinnet Plugin fixture" },
            clipboardWriter: { clipboardValue = $0 }
        )
        let supervisor = PluginRuntimeSupervisor(helperURL: helperURL)
        let result = try supervisor.execute(
            action,
            in: package,
            using: hostServiceBroker
        )

        XCTAssertEqual(
            result,
            .object([
                "checksum": .string("1559691768"),
                "output_bytes": .number(22)
            ])
        )
        XCTAssertEqual(clipboardValue, "SPINNET-plugin-FIXTURE")
        XCTAssertEqual(supervisor.launchCount, 1)
    }

    func testHostActionRunnerReturnsTheFixtureTextResult() throws {
        let helperURL = try XCTUnwrap(helperURLIfBuilt(), "Build SpinnetPluginHelper before running integration tests")
        let package = try loadFixturePackage()
        let command = try XCTUnwrap(package.manifest.commands.first {
            $0.id == CommandID("fixture.transform_text")
        })
        let action = try ActionConfiguration(
            id: ActionID("fixture-transform-text-seam"),
            pluginID: package.manifest.id,
            command: command,
            input: .string("Spinnet Plugin fixture")
        )
        let registry = PluginRegistry()
        try registry.register(package)
        let grantStore = PluginCapabilityGrantStore()
        grantStore.setDecision(
            .granted,
            for: package.manifest.id,
            pluginVersion: package.manifest.version,
            capability: .readSelectedText
        )
        grantStore.setDecision(
            .granted,
            for: package.manifest.id,
            pluginVersion: package.manifest.version,
            capability: .writeClipboard
        )
        var clipboardValue: String?
        let hostServiceBroker = CapabilityCheckedHostServiceBroker(
            grantStore: grantStore,
            systemPermissionCheck: { _ in true },
            selectedTextProvider: { _ in "Spinnet Plugin fixture" },
            clipboardWriter: { clipboardValue = $0 }
        )
        let runner = HostActionRunner(
            executor: NoopHostCommandExecutor(),
            scriptedExecutor: PluginRuntimeSupervisor(helperURL: helperURL),
            hostServiceBroker: hostServiceBroker
        )

        let outcome = runner.invoke(action, using: registry)

        XCTAssertEqual(outcome.actionID, action.id)
        XCTAssertEqual(outcome.pluginID, action.pluginID)
        XCTAssertEqual(
            outcome.terminal,
            .succeeded(.object([
                "checksum": .string("1559691768"),
                "output_bytes": .number(22)
            ]))
        )
        XCTAssertEqual(clipboardValue, "SPINNET-plugin-FIXTURE")
    }

    func testHostActionRunnerReturnsCapabilityDeniedWhenReadGrantIsWithheld() throws {
        let helperURL = try XCTUnwrap(helperURLIfBuilt(), "Build SpinnetPluginHelper before running integration tests")
        let package = try loadFixturePackage()
        XCTAssertEqual(
            package.manifest.capabilities,
            [.readSelectedText, .writeClipboard]
        )
        let command = try XCTUnwrap(package.manifest.commands.first {
            $0.id == CommandID("fixture.transform_text")
        })
        let action = try ActionConfiguration(
            id: ActionID("fixture-transform-text-denied"),
            pluginID: package.manifest.id,
            command: command,
            input: .string("Spinnet Plugin fixture")
        )
        let registry = PluginRegistry()
        try registry.register(package)

        let grantStore = PluginCapabilityGrantStore()
        grantStore.setDecision(
            .denied,
            for: package.manifest.id,
            pluginVersion: package.manifest.version,
            capability: .readSelectedText
        )
        grantStore.setDecision(
            .granted,
            for: package.manifest.id,
            pluginVersion: package.manifest.version,
            capability: .writeClipboard
        )
        var selectedTextProviderCalled = false
        var clipboardWriterCalled = false
        let hostServiceBroker = CapabilityCheckedHostServiceBroker(
            grantStore: grantStore,
            systemPermissionCheck: { _ in true },
            selectedTextProvider: { _ in
                selectedTextProviderCalled = true
                return "Spinnet Plugin fixture"
            },
            clipboardWriter: { _ in clipboardWriterCalled = true }
        )

        let outcome = HostActionRunner(
            executor: NoopHostCommandExecutor(),
            scriptedExecutor: PluginRuntimeSupervisor(helperURL: helperURL),
            hostServiceBroker: hostServiceBroker
        ).invoke(action, using: registry)

        guard case .failed(let failure) = outcome.terminal else {
            return XCTFail("A withheld read Capability should fail the Action")
        }
        XCTAssertEqual(failure.category, .capabilityDenied)
        XCTAssertFalse(selectedTextProviderCalled)
        XCTAssertFalse(clipboardWriterCalled)
    }

    func testHostActionRunnerReturnsCapabilityDeniedWhenWriteGrantIsWithheld() throws {
        let helperURL = try XCTUnwrap(helperURLIfBuilt(), "Build SpinnetPluginHelper before running integration tests")
        let package = try loadFixturePackage()
        let command = try XCTUnwrap(package.manifest.commands.first {
            $0.id == CommandID("fixture.transform_text")
        })
        let action = try ActionConfiguration(
            id: ActionID("fixture-transform-text-write-denied"),
            pluginID: package.manifest.id,
            command: command,
            input: .string("Spinnet Plugin fixture")
        )
        let registry = PluginRegistry()
        try registry.register(package)

        let grantStore = PluginCapabilityGrantStore()
        grantStore.setDecision(
            .granted,
            for: package.manifest.id,
            pluginVersion: package.manifest.version,
            capability: .readSelectedText
        )
        grantStore.setDecision(
            .denied,
            for: package.manifest.id,
            pluginVersion: package.manifest.version,
            capability: .writeClipboard
        )
        var selectedTextProviderCalled = false
        var clipboardWriterCalled = false
        let hostServiceBroker = CapabilityCheckedHostServiceBroker(
            grantStore: grantStore,
            systemPermissionCheck: { _ in true },
            selectedTextProvider: { _ in
                selectedTextProviderCalled = true
                return "Spinnet Plugin fixture"
            },
            clipboardWriter: { _ in clipboardWriterCalled = true }
        )

        let outcome = HostActionRunner(
            executor: NoopHostCommandExecutor(),
            scriptedExecutor: PluginRuntimeSupervisor(helperURL: helperURL),
            hostServiceBroker: hostServiceBroker
        ).invoke(action, using: registry)

        guard case .failed(let failure) = outcome.terminal else {
            return XCTFail("A withheld write Capability should fail the Action")
        }
        XCTAssertEqual(failure.category, .capabilityDenied)
        XCTAssertTrue(selectedTextProviderCalled)
        XCTAssertFalse(clipboardWriterCalled)
    }

    func testHostActionRunnerReturnsSystemPermissionDeniedAtTheHostServiceSeam() throws {
        let helperURL = try XCTUnwrap(helperURLIfBuilt(), "Build SpinnetPluginHelper before running integration tests")
        let package = try loadFixturePackage()
        let command = try XCTUnwrap(package.manifest.commands.first {
            $0.id == CommandID("fixture.transform_text")
        })
        let action = try ActionConfiguration(
            id: ActionID("fixture-transform-text-permission-denied"),
            pluginID: package.manifest.id,
            command: command,
            input: .string("Spinnet Plugin fixture")
        )
        let registry = PluginRegistry()
        try registry.register(package)

        let grantStore = PluginCapabilityGrantStore()
        grantStore.setDecision(
            .granted,
            for: package.manifest.id,
            pluginVersion: package.manifest.version,
            capability: .readSelectedText
        )
        grantStore.setDecision(
            .granted,
            for: package.manifest.id,
            pluginVersion: package.manifest.version,
            capability: .writeClipboard
        )
        var selectedTextProviderCalled = false
        let hostServiceBroker = CapabilityCheckedHostServiceBroker(
            grantStore: grantStore,
            systemPermissionCheck: { _ in false },
            selectedTextProvider: { _ in
                selectedTextProviderCalled = true
                return "Spinnet Plugin fixture"
            },
            clipboardWriter: { _ in }
        )

        let outcome = HostActionRunner(
            executor: NoopHostCommandExecutor(),
            scriptedExecutor: PluginRuntimeSupervisor(helperURL: helperURL),
            hostServiceBroker: hostServiceBroker
        ).invoke(action, using: registry)

        guard case .failed(let failure) = outcome.terminal else {
            return XCTFail("A missing System Permission should fail the Action")
        }
        XCTAssertEqual(failure.category, .systemPermissionDenied)
        XCTAssertFalse(selectedTextProviderCalled)
    }

    func testHostActionRunnerRechecksGrantBeforeEachHostServiceRequest() throws {
        let helperURL = try XCTUnwrap(helperURLIfBuilt(), "Build SpinnetPluginHelper before running integration tests")
        let package = try loadFixturePackage()
        let command = try XCTUnwrap(package.manifest.commands.first {
            $0.id == CommandID("fixture.transform_text")
        })
        let action = try ActionConfiguration(
            id: ActionID("fixture-transform-text-revoked"),
            pluginID: package.manifest.id,
            command: command,
            input: .string("Spinnet Plugin fixture")
        )
        let registry = PluginRegistry()
        try registry.register(package)

        let grantStore = PluginCapabilityGrantStore()
        grantStore.setDecision(
            .granted,
            for: package.manifest.id,
            pluginVersion: package.manifest.version,
            capability: .readSelectedText
        )
        grantStore.setDecision(
            .granted,
            for: package.manifest.id,
            pluginVersion: package.manifest.version,
            capability: .writeClipboard
        )
        var clipboardWriterCalled = false
        let hostServiceBroker = CapabilityCheckedHostServiceBroker(
            grantStore: grantStore,
            systemPermissionCheck: { _ in true },
            selectedTextProvider: { _ in
                grantStore.setDecision(
                    .denied,
                    for: package.manifest.id,
                    pluginVersion: package.manifest.version,
                    capability: .writeClipboard
                )
                return "Spinnet Plugin fixture"
            },
            clipboardWriter: { _ in clipboardWriterCalled = true }
        )

        let outcome = HostActionRunner(
            executor: NoopHostCommandExecutor(),
            scriptedExecutor: PluginRuntimeSupervisor(helperURL: helperURL),
            hostServiceBroker: hostServiceBroker
        ).invoke(action, using: registry)

        guard case .failed(let failure) = outcome.terminal else {
            return XCTFail("A Capability revoked between requests should fail the Action")
        }
        XCTAssertEqual(failure.category, .capabilityDenied)
        XCTAssertFalse(clipboardWriterCalled)
    }

    func testHostUsesConnectionBoundIdentityForHostServiceAuthorization() throws {
        let helperURL = try makeShellHelper(
            """
            #!/bin/sh
            IFS= read -r request
            invocation_id=$(printf '%s' "$request" | sed -n 's/.*"invocation_id":"\\([^" ]*\\)".*/\\1/p')
            action_id=$(printf '%s' "$request" | sed -n 's/.*"action_id":"\\([^" ]*\\)".*/\\1/p')
            printf '{"type":"host_service_request","protocol_version":"1.0","invocation_id":"%s","action_id":"%s","request_id":"claim-1","service":"read_selected_text","input":null,"plugin_id":"com.attacker","capabilities":["write_clipboard"]}\\n' "$invocation_id" "$action_id"
            IFS= read -r response
            printf '{"type":"terminal","protocol_version":"1.0","invocation_id":"%s","action_id":"%s","terminal":{"kind":"succeeded","result":"identity-bound"}}\\n' "$invocation_id" "$action_id"
            """
        )
        defer { try? FileManager.default.removeItem(at: helperURL) }

        let package = try loadFixturePackage()
        let command = try XCTUnwrap(package.manifest.commands.first {
            $0.id == CommandID("fixture.transform_text")
        })
        let action = try ActionConfiguration(
            id: ActionID("fixture-transform-text-identity"),
            pluginID: package.manifest.id,
            command: command,
            input: .string("ignored by helper")
        )
        let registry = PluginRegistry()
        try registry.register(package)

        let grantStore = PluginCapabilityGrantStore()
        grantStore.setDecision(
            .granted,
            for: package.manifest.id,
            pluginVersion: package.manifest.version,
            capability: .readSelectedText
        )
        let hostServiceBroker = CapabilityCheckedHostServiceBroker(
            grantStore: grantStore,
            systemPermissionCheck: { _ in true },
            selectedTextProvider: { _ in "selected text" },
            clipboardWriter: { _ in }
        )

        let outcome = HostActionRunner(
            executor: NoopHostCommandExecutor(),
            scriptedExecutor: PluginRuntimeSupervisor(helperURL: helperURL),
            hostServiceBroker: hostServiceBroker
        ).invoke(action, using: registry)

        XCTAssertEqual(outcome.terminal, .succeeded(.string("identity-bound")))
    }

    func testFixtureStructuredDataCommandRunsInTheJavaScriptCoreHelper() throws {
        let helperURL = try XCTUnwrap(helperURLIfBuilt(), "Build SpinnetPluginHelper before running integration tests")
        let package = try loadFixturePackage()
        let command = try XCTUnwrap(package.manifest.commands.first {
            $0.id == CommandID("fixture.transform_data")
        })
        let input = #"{"items":[{"id":2,"name":"beta","enabled":true},{"id":1,"name":"alpha","enabled":true},{"id":3,"name":"disabled","enabled":false}]}"#
        let action = try ActionConfiguration(
            id: ActionID("fixture-transform-data"),
            pluginID: package.manifest.id,
            command: command,
            input: .string(input)
        )

        let registry = PluginRegistry()
        try registry.register(package)
        let runner = HostActionRunner(
            executor: NoopHostCommandExecutor(),
            scriptedExecutor: PluginRuntimeSupervisor(helperURL: helperURL)
        )
        let outcome = runner.invoke(action, using: registry)
        guard case .succeeded(let result) = outcome.terminal else {
            return XCTFail("The structured-data Action should succeed through the Host seam")
        }
        XCTAssertEqual(
            result,
            .object([
                "checksum": .string("3454327220"),
                "output_bytes": .number(20)
            ])
        )

        let objectAction = try ActionConfiguration(
            id: ActionID("fixture-transform-data-object"),
            pluginID: package.manifest.id,
            command: command,
            input: .object([
                "items": .array([
                    .object([
                        "id": .number(2),
                        "name": .string("beta"),
                        "enabled": .bool(true)
                    ]),
                    .object([
                        "id": .number(1),
                        "name": .string("alpha"),
                        "enabled": .bool(true)
                    ]),
                    .object([
                        "id": .number(3),
                        "name": .string("disabled"),
                        "enabled": .bool(false)
                    ])
                ])
            ])
        )
        let objectOutcome = runner.invoke(objectAction, using: registry)
        guard case .succeeded(let objectResult) = objectOutcome.terminal else {
            return XCTFail("The object-form structured-data Action should succeed")
        }
        XCTAssertEqual(objectResult, result)
    }

    func testFatalHelperFaultIsContainedByTheHostProcess() throws {
        let helperURL = try XCTUnwrap(helperURLIfBuilt(), "Build SpinnetPluginHelper before running integration tests")
        let process = Process()
        process.executableURL = helperURL
        process.arguments = ["--fault-abort"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGABRT)
    }

    func testSupervisorReportsAFatalHelperFaultAtTheActionSeam() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpinnetCrashHelper-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let helperURL = directory.appendingPathComponent("crash-helper")
        try Data("#!/bin/sh\nkill -ABRT $$\n".utf8).write(to: helperURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: helperURL.path
        )

        let package = try loadFixturePackage()
        let command = try XCTUnwrap(package.manifest.commands.first {
            $0.id == CommandID("fixture.transform_text")
        })
        let action = try ActionConfiguration(
            id: ActionID("fixture-transform-text-crash"),
            pluginID: package.manifest.id,
            command: command,
            input: .string("Spinnet Plugin fixture")
        )
        let supervisor = PluginRuntimeSupervisor(helperURL: helperURL)
        let registry = PluginRegistry()
        try registry.register(package)
        let outcome = HostActionRunner(
            executor: NoopHostCommandExecutor(),
            scriptedExecutor: supervisor
        ).invoke(action, using: registry)

        guard case .failed(let failure) = outcome.terminal else {
            return XCTFail("A fatal helper fault should produce a terminal Host failure")
        }
        XCTAssertEqual(failure.category, .helperCrashed)
        XCTAssertEqual(failure.pluginID, action.pluginID)
        XCTAssertEqual(failure.actionID, action.id)
        XCTAssertEqual(supervisor.launchCount, 1)
    }

    func testDifferentPluginHelpersRemainIndependentWhenOneCrashes() throws {
        let helperURL = try makeShellHelper(
            """
            #!/bin/sh
            while IFS= read -r request; do
                case "$request" in
                    *com.spinnet.crash*) sleep 0.5; kill -ABRT $$ ;;
                    *)
                        invocation_id=$(printf '%s' "$request" | sed -n 's/.*"invocation_id":"\\([^"]*\\)".*/\\1/p')
                        action_id=$(printf '%s' "$request" | sed -n 's/.*"action_id":"\\([^"]*\\)".*/\\1/p')
                        printf '{"type":"terminal","protocol_version":"1.0","invocation_id":"%s","action_id":"%s","terminal":{"kind":"succeeded","result":"healthy"}}\\n' "$invocation_id" "$action_id"
                        ;;
                esac
            done
            """
        )
        defer { try? FileManager.default.removeItem(at: helperURL) }

        let crashingPackage = try makeScriptedPackage(
            pluginID: PluginID("com.spinnet.crash"),
            script: "input"
        )
        let healthyPackage = try makeScriptedPackage(
            pluginID: PluginID("com.spinnet.healthy"),
            script: "input"
        )
        defer {
            removePackageDirectory(crashingPackage)
            removePackageDirectory(healthyPackage)
        }
        let crashingAction = try ActionConfiguration(
            id: ActionID("crash-action"),
            pluginID: crashingPackage.manifest.id,
            command: crashingPackage.manifest.commands[0],
            input: .null
        )
        let healthyAction = try ActionConfiguration(
            id: ActionID("healthy-action"),
            pluginID: healthyPackage.manifest.id,
            command: healthyPackage.manifest.commands[0],
            input: .null
        )
        let registry = PluginRegistry()
        try registry.register(crashingPackage)
        try registry.register(healthyPackage)
        let processLock = NSLock()
        var processes: [Process] = []
        let supervisor = PluginRuntimeSupervisor(
            helperURL: helperURL,
            processFactory: {
                let process = Process()
                processLock.lock()
                processes.append(process)
                processLock.unlock()
                return process
            }
        )
        defer { supervisor.shutdown() }
        let runner = HostActionRunner(
            executor: NoopHostCommandExecutor(),
            scriptedExecutor: supervisor
        )

        let crashCompleted = DispatchSemaphore(value: 0)
        let healthyStarted = DispatchSemaphore(value: 0)
        let healthyCompleted = DispatchSemaphore(value: 0)
        let outcomeLock = NSLock()
        var crashed: ActionOutcome?
        var healthy: ActionOutcome?
        DispatchQueue.global().async {
            let outcome = runner.invoke(crashingAction, using: registry)
            outcomeLock.lock()
            crashed = outcome
            outcomeLock.unlock()
            crashCompleted.signal()
        }
        let launchDeadline = ProcessInfo.processInfo.systemUptime + 2
        while supervisor.launchCount < 1,
              ProcessInfo.processInfo.systemUptime < launchDeadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertEqual(supervisor.launchCount, 1)
        DispatchQueue.global().async {
            healthyStarted.signal()
            let outcome = runner.invoke(healthyAction, using: registry)
            outcomeLock.lock()
            healthy = outcome
            outcomeLock.unlock()
            healthyCompleted.signal()
        }
        XCTAssertEqual(healthyStarted.wait(timeout: .now() + 1), .success)
        let independentDeadline = ProcessInfo.processInfo.systemUptime + 0.25
        while supervisor.launchCount < 2,
              ProcessInfo.processInfo.systemUptime < independentDeadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertEqual(supervisor.launchCount, 2, "Different Plugins need independent helpers")
        XCTAssertEqual(healthyCompleted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(crashCompleted.wait(timeout: .now() + 2), .success)
        outcomeLock.lock()
        let outcomes = (crashed, healthy)
        outcomeLock.unlock()
        guard case .failed(let crashFailure) = outcomes.0?.terminal else {
            return XCTFail("The crashing Plugin should produce a terminal failure")
        }
        XCTAssertEqual(crashFailure.category, .helperCrashed)
        XCTAssertEqual(outcomes.1?.terminal, .succeeded(.string("healthy")))
        XCTAssertEqual(supervisor.launchCount, 2)
        processLock.lock()
        let processCount = processes.count
        processLock.unlock()
        XCTAssertEqual(processCount, 2)
    }

    func testMemoryLimitTerminatesProductionHelperAfterTwoSamples() throws {
        let helperURL = try XCTUnwrap(
            helperURLIfBuilt(),
            "Build SpinnetPluginHelper before running integration tests"
        )
        let package = try makeScriptedPackage(
            pluginID: PluginID("com.spinnet.memory"),
            script: "input"
        )
        defer { removePackageDirectory(package) }
        let action = try ActionConfiguration(
            id: ActionID("memory-action"),
            pluginID: package.manifest.id,
            command: package.manifest.commands[0],
            input: .null
        )
        let registry = PluginRegistry()
        try registry.register(package)
        let sampleCount = LockedCounter()
        let supervisor = PluginRuntimeSupervisor(
            helperURL: helperURL,
            helperArguments: ["--fault-memory"],
            resourceSampler: { processID in
                sampleCount.increment()
                return PluginHelperResourceSampler.physFootprint(processID: processID)
            }
        )
        defer { supervisor.shutdown() }

        let startedAt = ProcessInfo.processInfo.systemUptime
        let outcome = HostActionRunner(
            executor: NoopHostCommandExecutor(),
            scriptedExecutor: supervisor
        ).invoke(action, using: registry)

        guard case .failed(let failure) = outcome.terminal else {
            return XCTFail("A memory-hungry helper must terminate with a failure")
        }
        XCTAssertEqual(failure.category, .helperTerminated)
        XCTAssertGreaterThanOrEqual(sampleCount.value, 2)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - startedAt, 4.25)
    }

    func testExplicitActionGetsFreshHelperAfterCompletedHelperFault() throws {
        let helperURL = try makeShellHelper(
            """
            #!/bin/sh
            IFS= read -r request
            invocation_id=$(printf '%s' "$request" | sed -n 's/.*"invocation_id":"\\([^\"]*\\)".*/\\1/p')
            action_id=$(printf '%s' "$request" | sed -n 's/.*"action_id":"\\([^\"]*\\)".*/\\1/p')
            printf '{"type":"terminal","protocol_version":"1.0","invocation_id":"%s","action_id":"%s","terminal":{"kind":"succeeded","result":"finished"}}\\n' "$invocation_id" "$action_id"
            exit 1
            """
        )
        defer { try? FileManager.default.removeItem(at: helperURL) }
        let package = try makeScriptedPackage(
            pluginID: PluginID("com.spinnet.faulted-lease"),
            script: "input"
        )
        defer { removePackageDirectory(package) }
        let firstAction = try ActionConfiguration(
            id: ActionID("finished"),
            pluginID: package.manifest.id,
            command: package.manifest.commands[0],
            input: .null
        )
        let secondAction = try ActionConfiguration(
            id: ActionID("fresh-helper"),
            pluginID: package.manifest.id,
            command: package.manifest.commands[0],
            input: .null
        )
        let registry = PluginRegistry()
        try registry.register(package)
        let processLock = NSLock()
        var processes: [Process] = []
        let supervisor = PluginRuntimeSupervisor(
            helperURL: helperURL,
            processFactory: {
                let process = Process()
                processLock.lock()
                processes.append(process)
                processLock.unlock()
                return process
            }
        )
        defer { supervisor.shutdown() }
        let runner = HostActionRunner(
            executor: NoopHostCommandExecutor(),
            scriptedExecutor: supervisor
        )

        XCTAssertEqual(runner.invoke(firstAction, using: registry).terminal,
                       .succeeded(.string("finished")))
        processLock.lock()
        let firstProcess = processes[0]
        processLock.unlock()
        let exitDeadline = ProcessInfo.processInfo.systemUptime + 2
        while firstProcess.isRunning,
              ProcessInfo.processInfo.systemUptime < exitDeadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertFalse(firstProcess.isRunning)

        let outcome = runner.invoke(secondAction, using: registry)
        XCTAssertEqual(outcome.terminal, .succeeded(.string("finished")))
        XCTAssertEqual(supervisor.launchCount, 2, "An explicit Action after a fault gets a fresh helper")
    }

    func testTerminatingAPluginInvalidatesCurrentAndQueuedActionsOnce() throws {
        let helperURL = try makeShellHelper(
            """
            #!/bin/sh
            while IFS= read -r request; do sleep 10; done
            """
        )
        defer { try? FileManager.default.removeItem(at: helperURL) }
        let package = try makeScriptedPackage(
            pluginID: PluginID("com.spinnet.queued"),
            script: "input"
        )
        defer { removePackageDirectory(package) }
        let firstAction = try ActionConfiguration(
            id: ActionID("current"),
            pluginID: package.manifest.id,
            command: package.manifest.commands[0],
            input: .null
        )
        let secondAction = try ActionConfiguration(
            id: ActionID("queued"),
            pluginID: package.manifest.id,
            command: package.manifest.commands[0],
            input: .null
        )
        let supervisor = PluginRuntimeSupervisor(helperURL: helperURL)
        defer { supervisor.shutdown() }
        let firstControl = ActionExecutionControl()
        let secondControl = ActionExecutionControl()
        let firstFinished = expectation(description: "current Action invalidated")
        let secondFinished = expectation(description: "queued Action invalidated")
        let lock = NSLock()
        var firstError: PluginRuntimeError?
        var secondError: PluginRuntimeError?

        DispatchQueue.global().async {
            defer { firstFinished.fulfill() }
            do {
                _ = try supervisor.execute(
                    firstAction,
                    in: package,
                    using: nil,
                    control: firstControl
                )
                XCTFail("The current Action must be invalidated")
            } catch let error as PluginRuntimeError {
                lock.lock()
                firstError = error
                lock.unlock()
            } catch {
                XCTFail("Unexpected current Action error: \(error)")
            }
        }

        let launchDeadline = ProcessInfo.processInfo.systemUptime + 2
        while supervisor.launchCount == 0,
              ProcessInfo.processInfo.systemUptime < launchDeadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertEqual(supervisor.launchCount, 1)

        DispatchQueue.global().async {
            defer { secondFinished.fulfill() }
            do {
                _ = try supervisor.execute(
                    secondAction,
                    in: package,
                    using: nil,
                    control: secondControl
                )
                XCTFail("The queued Action must be invalidated")
            } catch let error as PluginRuntimeError {
                lock.lock()
                secondError = error
                lock.unlock()
            } catch {
                XCTFail("Unexpected queued Action error: \(error)")
            }
        }

        let queueDeadline = ProcessInfo.processInfo.systemUptime + 2
        while supervisor.queuedActionCount(for: package.manifest.id) < 1,
              ProcessInfo.processInfo.systemUptime < queueDeadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertEqual(supervisor.queuedActionCount(for: package.manifest.id), 1)
        supervisor.terminate(pluginID: package.manifest.id)
        wait(for: [firstFinished, secondFinished], timeout: 1)
        lock.lock()
        let errors = (firstError, secondError)
        lock.unlock()
        XCTAssertEqual(errors.0, .helperTerminated)
        XCTAssertEqual(errors.1, .helperTerminated)
        XCTAssertEqual(supervisor.launchCount, 1, "Invalidated work must not replay")
    }

    func testConsecutiveActionsReuseTheLazyPluginHelper() throws {
        let package = try makeScriptedPackage(pluginID: PluginID("com.example.reuse"), script: "input")
        defer { removePackageDirectory(package) }
        let registry = PluginRegistry()
        let process = Process()
        let supervisor = PluginRuntimeSupervisor(helperURL: try XCTUnwrap(helperURLIfBuilt()),
            registry: registry, processFactory: { process })
        defer { supervisor.shutdown() }
        try registry.register(package)
        XCTAssertEqual(supervisor.launchCount, 0)
        XCTAssertFalse(process.isRunning)
        let action = try ActionConfiguration(id: ActionID("repeat"), pluginID: package.manifest.id,
            command: package.manifest.commands[0], input: .string("first"))
        XCTAssertEqual(try supervisor.execute(action, in: package), .string("first"))
        let pid = process.processIdentifier
        XCTAssertTrue(process.isRunning)
        XCTAssertEqual(try supervisor.execute(action, in: package), .string("first"))
        XCTAssertTrue(process.isRunning)
        XCTAssertEqual(process.processIdentifier, pid)
        XCTAssertEqual(supervisor.launchCount, 1)
    }

    func testIdleHelperExitsGracefullyAndExplicitActionStartsFresh() throws {
        let (package, action) = try lifecycleAction()
        let clock = RuntimeTestClock()
        var processes: [Process] = []
        let supervisor = PluginRuntimeSupervisor(helperURL: try XCTUnwrap(helperURLIfBuilt()),
            processFactory: { let process = Process(); processes.append(process); return process },
            schedule: clock.schedule)
        defer { supervisor.shutdown() }
        XCTAssertEqual(try supervisor.execute(action, in: package), .number(42))
        clock.advance(by: 29.99)
        XCTAssertTrue(processes[0].isRunning)
        clock.advance(by: 0.01)
        assertExits(processes[0])
        XCTAssertEqual(processes[0].terminationReason, .exit)
        XCTAssertEqual(processes[0].terminationStatus, 0)
        XCTAssertEqual(try supervisor.execute(action, in: package), .number(42))
        XCTAssertEqual(supervisor.launchCount, 2)
        XCTAssertNotEqual(processes[0].processIdentifier, processes[1].processIdentifier)
        clock.advance(by: 0.25)
        XCTAssertTrue(processes[1].isRunning, "Old exit allowance must not kill the replacement")
    }

    func testUnresponsiveIdleHelperIsKilledOnlyAfterExitAllowance() throws {
        let (package, action) = try lifecycleAction()
        let helper = try makeShellHelper("""
            #!/bin/sh
            IFS= read -r request
            invocation_id=$(printf '%s' "$request" | sed -n 's/.*"invocation_id":"\\([^"]*\\)".*/\\1/p')
            action_id=$(printf '%s' "$request" | sed -n 's/.*"action_id":"\\([^"]*\\)".*/\\1/p')
            printf '{"type":"terminal","protocol_version":"1.0","invocation_id":"%s","action_id":"%s","terminal":{"kind":"succeeded","result":42}}\\n' "$invocation_id" "$action_id"
            while :; do :; done
            """)
        defer { try? FileManager.default.removeItem(at: helper) }
        let clock = RuntimeTestClock()
        let process = Process()
        let supervisor = PluginRuntimeSupervisor(helperURL: helper,
            processFactory: { process }, schedule: clock.schedule)
        defer { supervisor.shutdown() }
        XCTAssertEqual(try supervisor.execute(action, in: package), .number(42))
        clock.advance(by: 30)
        XCTAssertTrue(process.isRunning)
        clock.advance(by: 0.249)
        XCTAssertTrue(process.isRunning)
        clock.advance(by: 0.0011)
        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGKILL)
    }

    func testPluginMutationsRetireHelpersBeforeReturning() throws {
        for mutation in ["disable", "uninstall", "update"] {
            let (package, action) = try lifecycleAction()
            let registry = PluginRegistry()
            try registry.register(package)
            var processes: [Process] = []
            let supervisor = PluginRuntimeSupervisor(helperURL: try XCTUnwrap(helperURLIfBuilt()),
                registry: registry,
                processFactory: { let process = Process(); processes.append(process); return process })
            defer { supervisor.shutdown() }
            XCTAssertEqual(try supervisor.execute(action, in: package), .number(42))
            var currentPackage = package
            switch mutation {
            case "disable":
                try registry.setEnabled(false, for: package.manifest.id)
                XCTAssertFalse(processes[0].isRunning)
                XCTAssertThrowsError(try supervisor.execute(action, in: package))
                try registry.setEnabled(true, for: package.manifest.id)
            case "uninstall":
                registry.unregister(package.manifest.id)
                XCTAssertFalse(processes[0].isRunning)
                XCTAssertThrowsError(try supervisor.execute(action, in: package))
                try registry.register(package)
            default:
                currentPackage = try makeScriptedPackage(pluginID: package.manifest.id, script: "99")
                addTeardownBlock { removePackageDirectory(currentPackage) }
                try registry.replace(currentPackage)
                XCTAssertFalse(processes[0].isRunning)
                XCTAssertThrowsError(try supervisor.execute(action, in: package), "Reject stale package snapshot")
            }
            XCTAssertEqual(try supervisor.execute(action, in: currentPackage),
                .number(mutation == "update" ? 99 : 42))
            XCTAssertEqual(supervisor.launchCount, 2)
            XCTAssertTrue(processes[1].isRunning)
        }
    }

    func testRevokingEitherCapabilityRetiresHelperAndLaterActionUsesCurrentGrants() throws {
        let package = try loadFixturePackage()
        let command = try XCTUnwrap(package.manifest.commands.first { $0.id == CommandID("fixture.transform_text") })
        let action = try ActionConfiguration(id: ActionID("revocation"), pluginID: package.manifest.id,
            command: command, input: .null)
        for capability in package.manifest.capabilities {
            let registry = PluginRegistry()
            try registry.register(package)
            let grants = PluginCapabilityGrantStore()
            for grant in PluginCapability.allCases {
                grants.setDecision(.granted, for: package.manifest.id,
                    pluginVersion: package.manifest.version, capability: grant)
            }
            var writes = 0
            let broker = CapabilityCheckedHostServiceBroker(grantStore: grants,
                systemPermissionCheck: { _ in true }, selectedTextProvider: { _ in "example" },
                clipboardWriter: { _ in writes += 1 })
            var processes: [Process] = []
            let supervisor = PluginRuntimeSupervisor(helperURL: try XCTUnwrap(helperURLIfBuilt()),
                registry: registry, grantStore: grants,
                processFactory: { let process = Process(); processes.append(process); return process })
            defer { supervisor.shutdown() }
            let runner = HostActionRunner(executor: NoopHostCommandExecutor(),
                scriptedExecutor: supervisor, hostServiceBroker: broker)
            guard case .succeeded = runner.invoke(action, using: registry).terminal else {
                return XCTFail("Granted Action should succeed")
            }
            XCTAssertEqual(writes, 1)
            grants.setDecision(.denied, for: package.manifest.id,
                pluginVersion: package.manifest.version, capability: capability)
            XCTAssertFalse(processes[0].isRunning)
            let outcome = runner.invoke(try action.newInvocation(), using: registry)
            guard case .failed(let failure) = outcome.terminal else {
                return XCTFail("The new Action must observe revocation")
            }
            XCTAssertEqual(failure.category, .capabilityDenied)
            XCTAssertEqual(writes, 1)
            XCTAssertEqual(supervisor.launchCount, 2)
        }
    }

    func testQueuedActionsSerializeAndOldIdleTimerCannotRetireActiveHelper() throws {
        let package = try loadFixturePackage()
        let command = try XCTUnwrap(package.manifest.commands.first { $0.id == CommandID("fixture.transform_text") })
        let action = try ActionConfiguration(id: ActionID("serialized"), pluginID: package.manifest.id,
            command: command, input: .null)
        let grants = PluginCapabilityGrantStore()
        for capability in PluginCapability.allCases {
            grants.setDecision(.granted, for: package.manifest.id,
                pluginVersion: package.manifest.version, capability: capability)
        }
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 1)
        defer { release.signal(); release.signal() }
        let broker = CapabilityCheckedHostServiceBroker(grantStore: grants,
            systemPermissionCheck: { _ in true }, selectedTextProvider: { _ in
                entered.signal()
                guard release.wait(timeout: .now() + 3) == .success else {
                    throw PluginRuntimeError.timedOut
                }
                return "example"
            }, clipboardWriter: { _ in })
        let clock = RuntimeTestClock()
        let process = Process()
        let supervisor = PluginRuntimeSupervisor(helperURL: try XCTUnwrap(helperURLIfBuilt()),
            processFactory: { process }, schedule: clock.schedule)
        defer { supervisor.shutdown() }
        _ = try supervisor.execute(action, in: package, using: broker)
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        let second = expectation(description: "second Action")
        DispatchQueue.global().async {
            defer { second.fulfill() }
            do { _ = try supervisor.execute(action, in: package, using: broker) }
            catch { XCTFail("Second Action failed: \(error)") }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        clock.advance(by: 30)
        XCTAssertTrue(process.isRunning, "The old idle deadline expired during an Action")
        let third = expectation(description: "third Action")
        let submitted = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { third.fulfill() }
            submitted.signal()
            do { _ = try supervisor.execute(action, in: package, using: broker) }
            catch { XCTFail("Third Action failed: \(error)") }
        }
        XCTAssertEqual(submitted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(entered.wait(timeout: .now() + 0.05), .timedOut)
        release.signal()
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(supervisor.launchCount, 1)
        release.signal()
        wait(for: [second, third], timeout: 2)
        clock.advance(by: 29)
        XCTAssertTrue(process.isRunning)
        clock.advance(by: 1)
        assertExits(process)
        XCTAssertEqual(process.terminationReason, .exit)
    }

    func testShutdownReapsIdleAndActiveHelpersAndRejectsLaterExecution() throws {
        _ = NSApplication.shared
        for _ in 0..<20 {
            try checkShutdownDuringHelperStartup()
        }
    }

    private func checkShutdownDuringHelperStartup() throws {
        let (idlePackage, idleAction) = try lifecycleAction()
        let activePackage = try makeScriptedPackage(pluginID: PluginID("test.shutdown.active"),
            script: "while (true) {}")
        defer { removePackageDirectory(activePackage) }
        let activeAction = try ActionConfiguration(id: ActionID("active"), pluginID: activePackage.manifest.id,
            command: activePackage.manifest.commands[0], input: .null)
        let processes = [Process(), Process()]
        var nextProcess = 0
        let supervisor = PluginRuntimeSupervisor(helperURL: try XCTUnwrap(helperURLIfBuilt()),
            processFactory: { defer { nextProcess += 1 }; return processes[nextProcess] })
        defer { supervisor.shutdown() }
        XCTAssertEqual(try supervisor.execute(idleAction, in: idlePackage), .number(42))
        let completed = expectation(description: "active execution interrupted by shutdown")
        DispatchQueue.global().async {
            defer { completed.fulfill() }
            do {
                _ = try supervisor.execute(activeAction, in: activePackage)
                XCTFail("Shutdown must interrupt the active Action")
            } catch { XCTAssertEqual(error as? PluginRuntimeError, .helperTerminated) }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !processes[1].isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertTrue(processes[0].isRunning)
        XCTAssertTrue(processes[1].isRunning)
        supervisor.shutdown()
        XCTAssertTrue(processes.allSatisfy { !$0.isRunning })
        wait(for: [completed], timeout: 1)
        XCTAssertThrowsError(try supervisor.execute(idleAction, in: idlePackage)) {
            XCTAssertEqual($0 as? PluginRuntimeError, .helperTerminated)
        }
        XCTAssertEqual(supervisor.launchCount, 2)
    }

    func testRegistryMenuDataAndDeclarativeActionStartNoHelper() throws {
        let package = try loadFixturePackage()
        let registry = PluginRegistry()
        let supervisor = PluginRuntimeSupervisor(helperURL: try XCTUnwrap(helperURLIfBuilt()),
            registry: registry, processFactory: { XCTFail("Helper must remain lazy"); return Process() })
        defer { supervisor.shutdown() }
        try registry.register(package)
        XCTAssertFalse(registry.menuItemPresets().isEmpty)
        XCTAssertFalse(registry.availableCommands().isEmpty)
        let command = try XCTUnwrap(package.manifest.commands.first { $0.execution == .host })
        let action = try ActionConfiguration(id: ActionID("declarative"), pluginID: package.manifest.id,
            command: command, input: .string("https://example.com"))
        let runner = HostActionRunner(executor: NoopHostCommandExecutor(), scriptedExecutor: supervisor)
        XCTAssertEqual(runner.invoke(action, using: registry).terminal, .succeeded(.null))
        XCTAssertEqual(supervisor.launchCount, 0)
    }

    private func lifecycleAction(script: String = "42") throws -> (PluginPackage, ActionConfiguration) {
        let package = try makeScriptedPackage(pluginID: PluginID("test.lifecycle"), script: script)
        addTeardownBlock { removePackageDirectory(package) }
        let action = try ActionConfiguration(id: ActionID("lifecycle"), pluginID: package.manifest.id,
            command: package.manifest.commands[0], input: .null)
        return (package, action)
    }

    private func assertExits(_ process: Process, file: StaticString = #filePath, line: UInt = #line) {
        let exited = expectation(description: "helper exited")
        DispatchQueue.global().async { process.waitUntilExit(); exited.fulfill() }
        wait(for: [exited], timeout: 2)
        XCTAssertFalse(process.isRunning, file: file, line: line)
    }

    private func loadFixturePackage() throws -> PluginPackage {
        try ScriptedPackageFixture.load()
    }

    private func makeInvocation(scriptSource: String) -> PluginRuntimeInvocation {
        PluginRuntimeInvocation(
            invocationID: "invocation-1",
            pluginID: PluginID("com.example.fixture"),
            actionID: ActionID("action-1"),
            commandID: CommandID("fixture.transform_text"),
            scriptPath: "transform-text.js",
            scriptSource: scriptSource,
            input: .string("value")
        )
    }

    private func readFramedBody(_ body: Data) throws -> Data? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpinnetProtocolFrame-\(UUID().uuidString)")
        var framed = body
        framed.append(0x0A)
        try framed.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try PluginRuntimeProtocol.readFrame(
            from: handle,
            label: "Test message"
        )
    }

    private func makeScriptedPackage(pluginID: PluginID, script: String) throws -> PluginPackage {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpinnetProtocolPackage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data(script.utf8).write(to: directory.appendingPathComponent("action.js"))
        let command = CommandDeclaration(
            id: CommandID("\(pluginID.rawValue).action"),
            title: "Action",
            execution: .javascript,
            script: "action.js"
        )
        let manifest = try PluginManifest(
            id: pluginID,
            name: pluginID.rawValue,
            version: "1.0.0",
            commands: [command]
        )
        return PluginPackage(rootURL: directory, manifest: manifest)
    }

    private func makeShellHelper(_ source: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpinnetHostileHelper-\(UUID().uuidString)")
        try Data(source.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
        return url
    }

    func helperURLIfBuilt() -> URL? {
        if let value = ProcessInfo.processInfo.environment["SPINNET_PLUGIN_HELPER_URL"] {
            let url = URL(fileURLWithPath: value)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }

        if let executableURL = Bundle.main.executableURL {
            var directory = executableURL.deletingLastPathComponent()
            for _ in 0..<5 {
                let candidate = directory.appendingPathComponent("SpinnetPluginHelper")
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
                directory.deleteLastPathComponent()
            }
        }

        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let buildRoot = root.appendingPathComponent(".build", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: buildRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isExecutableKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in enumerator {
            guard url.lastPathComponent == "SpinnetPluginHelper",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isExecutableKey]),
                  values.isRegularFile == true,
                  values.isExecutable == true else { continue }
            return url
        }
        return nil
    }
}

private struct NoopHostCommandExecutor: HostCommandExecutor {
    func execute(_ action: ActionConfiguration) throws -> JSONValue { .null }
}

/// Virtual time is injected only at the OS timer boundary. Processes and the
/// Host/helper wire protocol remain real in lifecycle integration tests.
private final class RuntimeTestClock {
    private let lock = NSLock()
    private var now: TimeInterval = 0
    private var operations: [(TimeInterval, () -> Void)] = []

    func schedule(_ delay: TimeInterval, _ operation: @escaping () -> Void) {
        lock.lock()
        operations.append((now + delay, operation))
        lock.unlock()
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        now += interval
        while let index = operations.firstIndex(where: { $0.0 <= now }) {
            let operation = operations.remove(at: index).1
            lock.unlock()
            operation()
            lock.lock()
        }
        lock.unlock()
    }
}

private final class LockedCounter {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}
