import XCTest
@testable import SpinnetCore
import SpinnetPluginTestKit

/// Window Position's scripts run in the real helper. Layouts are answered from
/// a recorded focused window and checked by the frames the scripts request;
/// failures still go through the Host's own broker and Action runner.
final class WindowPositionScriptTests: XCTestCase {

    func testBundledWindowPositionRequestsEachLayoutWithinTheVisibleFrame() throws {
        let plugin = try WindowPositionFixture.plugin()
        let helper = try PluginTestHelper()
        defer { helper.shutdown() }

        // A secondary display left of the primary one, below its menu bar, with
        // an odd width so the halves have to share the extra point.
        let visible = WindowRect(x: -1501, y: 25, width: 1501, height: 875)
        var window = FocusedWindow(frame: WindowRect(x: -1400, y: 300, width: 600, height: 401), visibleFrame: visible)
        var frames: [WindowRect] = []
        func run(_ commandID: String) throws -> JSONValue {
            let run = helper.run(PluginTestInvocation(commandID), of: plugin,
                                 answering: try WindowPositionFixture.services(for: window))
            frames += try run.frames()
            return try run.result.get()
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
        let plugin = try WindowPositionFixture.plugin()
        let helper = try PluginTestHelper()
        defer { helper.shutdown() }

        var window = FocusedWindow(frame: WindowRect(x: -1400, y: 100, width: 600, height: 401),
                                   visibleFrame: WindowRect(x: -1501, y: -201, width: 1501, height: 875))
        func assertLayouts(_ expected: KeyValuePairs<String, WindowRect>, file: StaticString = #filePath, line: UInt = #line) throws {
            for (commandID, frame) in expected {
                let run = helper.run(PluginTestInvocation(commandID), of: plugin,
                                     answering: try WindowPositionFixture.services(for: window))
                let frames = try run.frames(file: file, line: line)
                XCTAssertEqual(try run.result.get(), .null, commandID, file: file, line: line)
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
        let plugin = try WindowPositionFixture.plugin()
        let helper = try PluginTestHelper()
        defer { helper.shutdown() }

        let visible = WindowRect(x: -1501, y: -201, width: 1501, height: 875)
        func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> WindowRect {
            WindowRect(x: x, y: y, width: width, height: height)
        }
        /// Runs `commandID` on a window at `from` and asserts the one frame it requests.
        func assertRun(_ commandID: String, from: WindowRect, to expected: WindowRect,
                       file: StaticString = #filePath, line: UInt = #line) throws {
            let run = helper.run(PluginTestInvocation(commandID), of: plugin,
                                 answering: try WindowPositionFixture.services(for: FocusedWindow(frame: from, visibleFrame: visible)))
            let frames = try run.frames(file: file, line: line)
            XCTAssertEqual(try run.result.get(), .null, commandID, file: file, line: line)
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
                scriptedExecutor: try PluginTestHelper(),
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
                scriptedExecutor: try PluginTestHelper(),
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
        let plugin = try WindowPositionFixture.plugin()
        let helper = try PluginTestHelper()
        defer { helper.shutdown() }

        // Left to right: a larger display with a negative origin, the primary
        // display below its menu bar, and a smaller display set higher up.
        let large = WindowRect(x: -1920, y: -100, width: 1920, height: 1080)
        let primary = WindowRect(x: 0, y: 25, width: 1440, height: 875)
        let small = WindowRect(x: 1440, y: -375, width: 1280, height: 775)
        func move(_ frame: WindowRect, on index: Int, of displays: [WindowRect], _ commandID: String) throws -> WindowRect? {
            let window = FocusedWindow(frame: frame, visibleFrame: displays[index], displays: displays, displayIndex: index)
            let run = helper.run(PluginTestInvocation(commandID), of: plugin,
                                 answering: try WindowPositionFixture.services(for: window))
            let frames = try run.frames()
            XCTAssertEqual(try run.result.get(), .null)
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
                scriptedExecutor: try PluginTestHelper(),
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
}

private struct NoopHostCommandExecutor: HostCommandExecutor {
    func execute(_ action: ActionConfiguration) throws -> JSONValue { .null }
}
