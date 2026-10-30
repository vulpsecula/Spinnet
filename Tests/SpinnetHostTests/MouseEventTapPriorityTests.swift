import AppKit
import XCTest
@testable import SpinnetHost

/// Drives the real controller through a head-insertion event chain, including
/// a remapper installed after Spinnet. No native permissions are needed.
final class MouseEventTapPriorityTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    func testStartingRecordingTakesPriorityOverALaterRemapper() throws {
        let rig = try PriorityRig()
        defer { rig.controller.stop() }
        rig.installRemapper()
        var captured: [Int] = []

        rig.controller.setMouseButtonCaptureActive(true) { captured.append($0) }
        rig.mouse(.otherMouseDown)
        rig.mouse(.otherMouseUp)

        XCTAssertEqual(captured, [3], "The recorder must receive the raw button before the remapper")
        XCTAssertEqual(rig.mappedCount, 0)
        XCTAssertEqual(rig.menuCount, 0)
        XCTAssertEqual(rig.appEvents, [])
    }

    func testRecoveryNoticesAButtonFilterEnabledAfterAMouseChange() throws {
        let rig = try PriorityRig()
        defer { rig.controller.stop() }
        let driver = rig.installRemapper(enabled: false)
        rig.controller.retryMouseInterceptionIfAuthorized()
        driver.isEnabled = true

        rig.controller.retryMouseInterceptionIfAuthorized()
        rig.mouse(.otherMouseDown)
        rig.mouse(.otherMouseUp)

        XCTAssertEqual(rig.menuCount, 1)
        XCTAssertEqual(rig.mappedCount, 0)
    }

    func testRecoveryReinstallsADisabledHostTap() throws {
        let rig = try PriorityRig()
        defer { rig.controller.stop() }
        rig.hostTaps.last?.isEnabled = false

        rig.controller.retryMouseInterceptionIfAuthorized()
        rig.mouse(.otherMouseDown)

        XCTAssertEqual(rig.menuCount, 1)
        XCTAssertTrue(rig.controller.mouseInterceptionAvailable)
    }

    func testUnchangedFiltersDoNotCauseRepeatedReinstallation() throws {
        let rig = try PriorityRig()
        defer { rig.controller.stop() }
        let count = rig.hostTaps.count

        for _ in 0..<5 { rig.controller.retryMouseInterceptionIfAuthorized() }

        XCTAssertEqual(rig.hostTaps.count, count)
    }

    func testRecordedPressMotionAndReleaseNeverOpenTheMenu() throws {
        let rig = try PriorityRig(clickDragEnabled: true, buttonHeld: { $0 == 3 })
        defer { rig.controller.stop() }
        var captured: [Int] = []
        rig.controller.setMouseButtonCaptureActive(true) { button in
            captured.append(button)
            rig.controller.setMouseButtonCaptureActive(false)
            _ = rig.controller.apply(MenuTriggerConfiguration(mouseButton: button, clickDragEnabled: true))
        }

        rig.mouse(.otherMouseDown)
        rig.mouse(.mouseMoved, button: 0, x: 30)
        rig.mouse(.otherMouseDragged, x: 50)
        rig.mouse(.otherMouseUp, x: 50)

        XCTAssertEqual(captured, [3])
        XCTAssertEqual(rig.menuCount, 0, "Held-button recovery must not turn a recorded press into a Menu gesture")
        XCTAssertEqual(rig.appEvents, [.mouseMoved])
    }

    func testRecordingAlsoWorksWhileRuntimeTriggersAreSwitchedOff() throws {
        let rig = try PriorityRig()
        defer { rig.controller.stop() }
        rig.controller.stop()
        rig.installRemapper()
        var captured: [Int] = []

        rig.controller.setMouseButtonCaptureActive(true) { captured.append($0) }
        rig.mouse(.otherMouseDown)
        rig.mouse(.otherMouseUp)

        XCTAssertEqual(captured, [3])
        XCTAssertFalse(rig.controller.isRunning)
        XCTAssertEqual(rig.mappedCount, 0)
        XCTAssertEqual(rig.menuCount, 0)
    }

    func testAFilterChangeWaitsUntilTheCurrentPressEnds() throws {
        let rig = try PriorityRig()
        defer { rig.controller.stop() }
        rig.mouse(.otherMouseDown)
        let count = rig.hostTaps.count
        let driver = rig.installRemapper()

        rig.controller.retryMouseInterceptionIfAuthorized()
        XCTAssertEqual(rig.hostTaps.count, count, "Do not split a press while reclaiming priority")

        // Let the original release reach the Host, then enable the filter.
        driver.isEnabled = false
        rig.mouse(.otherMouseUp)
        driver.isEnabled = true
        rig.controller.retryMouseInterceptionIfAuthorized()
        rig.mouse(.otherMouseDown)

        XCTAssertEqual(rig.hostTaps.count, count + 1)
        XCTAssertEqual(rig.menuCount, 2)
        XCTAssertEqual(rig.mappedCount, 0)
    }

    func testCancellingRecordingRemovesTheTemporaryTapWhenRuntimeIsOff() throws {
        let rig = try PriorityRig()
        defer { rig.controller.stop() }
        rig.controller.stop()
        rig.controller.setMouseButtonCaptureActive(true) { _ in }
        XCTAssertTrue(rig.hostTaps.last?.isEnabled == true)

        rig.controller.setMouseButtonCaptureActive(false)

        XCTAssertFalse(rig.hostTaps.last?.isEnabled == true)
        XCTAssertFalse(rig.controller.mouseInterceptionAvailable)
        rig.mouse(.otherMouseDown)
        XCTAssertEqual(rig.appEvents, [.otherMouseDown])
        XCTAssertEqual(rig.menuCount, 0)
    }

    func testCompletingRecordingRemovesTheTemporaryTapAfterReleaseWhenRuntimeIsOff() throws {
        let rig = try PriorityRig()
        defer { rig.controller.stop() }
        rig.controller.stop()
        rig.controller.setMouseButtonCaptureActive(true) { _ in
            rig.controller.setMouseButtonCaptureActive(false)
        }
        rig.mouse(.otherMouseDown)
        XCTAssertTrue(rig.hostTaps.last?.isEnabled == true, "Keep the connection until the recorded button is released")

        rig.mouse(.otherMouseUp)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))

        XCTAssertFalse(rig.hostTaps.last?.isEnabled == true)
        XCTAssertFalse(rig.controller.mouseInterceptionAvailable)
        rig.mouse(.otherMouseDown)
        XCTAssertEqual(rig.appEvents, [.otherMouseDown])
        XCTAssertEqual(rig.menuCount, 0)
    }

    func testStoppingPreventsAutomaticRecoveryFromReinstallingAnyTap() throws {
        let rig = try PriorityRig()
        rig.controller.stop()
        let count = rig.hostTaps.count
        rig.installRemapper()

        rig.controller.retryMouseInterceptionIfAuthorized()
        rig.mouse(.otherMouseDown)

        XCTAssertEqual(rig.hostTaps.count, count)
        XCTAssertEqual(rig.menuCount, 0)
        XCTAssertEqual(rig.mappedCount, 1)
    }

    func testFailedPriorityRefreshKeepsTheExistingConnection() throws {
        let rig = try PriorityRig()
        defer { rig.controller.stop() }
        let original = try XCTUnwrap(rig.hostTaps.last)
        rig.failNextConnection = true

        rig.controller.setMouseButtonCaptureActive(true) { _ in }

        XCTAssertFalse(rig.failNextConnection, "A refresh was attempted")
        XCTAssertTrue(original.isEnabled)
        XCTAssertTrue(rig.controller.mouseInterceptionAvailable)
    }
}

private final class PriorityRig {
    let controller: GlobalTriggerController
    private(set) var taps: [PriorityTap] = []
    private(set) var hostTaps: [PriorityTap] = []
    private var nextID: UInt32 = 0
    var failNextConnection = false
    private(set) var mappedCount = 0
    private(set) var menuCount = 0
    private(set) var appEvents: [CGEventType] = []

    init(clickDragEnabled: Bool = false, buttonHeld: @escaping (Int) -> Bool = { _ in false }) throws {
        var connect: ((@escaping MouseEventTapHandler) -> MouseEventTapConnection?)!
        var inventory: (() -> Set<UInt32>?)!
        controller = GlobalTriggerController(
            accessibilityPermission: AccessibilityPermissionController(isTrusted: { true }, request: {}),
            mouseButtonStateCheck: buttonHeld,
            createMouseEventTap: { connect($0) },
            otherMouseEventTapIDs: { inventory() }
        )
        connect = { [weak self] handler in
            guard let self else { return nil }
            if self.failNextConnection { self.failNextConnection = false; return nil }
            let tap = self.install(isHost: true, handler: handler)
            self.hostTaps.append(tap)
            return tap
        }
        inventory = { [weak self] in
            Set(self?.taps.filter { !$0.isHost && $0.isEnabled }.map(\.id) ?? [])
        }
        controller.onInvoke = { [weak self] in self?.menuCount += 1 }
        XCTAssertTrue(controller.start(configuration: MenuTriggerConfiguration(
            mouseButton: 3, clickDragEnabled: clickDragEnabled
        )))
    }

    @discardableResult
    func installRemapper(enabled: Bool = true) -> PriorityTap {
        let tap = install(isHost: false) { [weak self] type, event in
            guard event.getIntegerValueField(.mouseEventButtonNumber) == 3 else {
                return Unmanaged.passUnretained(event)
            }
            if type == .otherMouseDown { self?.mappedCount += 1 }
            return nil
        }
        tap.isEnabled = enabled
        return tap
    }

    private func install(isHost: Bool, handler: @escaping MouseEventTapHandler) -> PriorityTap {
        nextID += 1
        let tap = PriorityTap(id: nextID, isHost: isHost, handler: handler)
        taps.insert(tap, at: 0)
        return tap
    }

    func mouse(_ type: CGEventType, button: Int = 3, x: CGFloat = 0) {
        let event = CGEvent(mouseEventSource: nil, mouseType: type,
                            mouseCursorPosition: CGPoint(x: x, y: 0), mouseButton: .center)!
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        for tap in taps where tap.isEnabled {
            if tap.handler(type, event) == nil { return }
        }
        appEvents.append(type)
    }
}

private final class PriorityTap: MouseEventTapConnection {
    let id: UInt32
    let isHost: Bool
    let handler: MouseEventTapHandler
    var isEnabled = true

    init(id: UInt32, isHost: Bool, handler: @escaping MouseEventTapHandler) {
        self.id = id
        self.isHost = isHost
        self.handler = handler
    }

    func enable() { isEnabled = true }
    func invalidate() { isEnabled = false }
}
