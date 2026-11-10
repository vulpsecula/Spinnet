import AppKit
import XCTest
@testable import SpinnetHost

/// The trackpad trigger classifies recorded touch frames: what the trackpad
/// reported at each moment, as non-resting finger positions on its surface.
final class TrackpadTapTriggerTests: XCTestCase {
    // MARK: Classification

    func testThreeFingersLandingAndLiftingTogetherIsATap() {
        var classifier = TrackpadTapClassifier(fingerCount: 3)
        let outcomes = classifier.receive(Recording.threeFingerTap)
        XCTAssertEqual(outcomes, [.began, .tap])
    }

    func testFourFingersTapOnlyForTheFourFingerTrigger() {
        var three = TrackpadTapClassifier(fingerCount: 3)
        XCTAssertEqual(three.receive(Recording.fourFingerTap), [.began, .cancelled],
                       "A fourth finger makes it someone else's gesture")
        var four = TrackpadTapClassifier(fingerCount: 4)
        XCTAssertEqual(four.receive(Recording.fourFingerTap), [.began, .tap])
        XCTAssertEqual(four.receive(Recording.threeFingerTap), [], "Too few fingers never begin")
    }

    func testASwipeIsNotATap() {
        var classifier = TrackpadTapClassifier(fingerCount: 3)
        XCTAssertEqual(classifier.receive(Recording.threeFingerSwipe), [.began, .cancelled])
    }

    func testFingersThatStayTooLongAreNotATap() {
        var classifier = TrackpadTapClassifier(fingerCount: 3)
        XCTAssertEqual(classifier.receive(Recording.threeFingerRest), [.began, .cancelled])
    }

    func testFingersLandingOneByOneAreNotATap() {
        var classifier = TrackpadTapClassifier(fingerCount: 3)
        XCTAssertEqual(classifier.receive(Recording.threeFingersOneByOne), [],
                       "Two fingers scrolling, then a third, is not a tap")
    }

    func testAFingerReturningWhileTheOthersLiftIsNotATap() {
        var classifier = TrackpadTapClassifier(fingerCount: 3)
        let frames = Array(Recording.threeFingerTap.dropLast()) + [
            Recording.frame(10.150, Recording.b, Recording.c, Recording.a2)
        ]
        XCTAssertEqual(classifier.receive(frames), [.began, .cancelled])
    }

    func testRejectionLastsUntilEveryFingerLiftsThenTheNextTapCounts() {
        var classifier = TrackpadTapClassifier(fingerCount: 3)
        let later = Recording.threeFingerTap.map { Recording.shifted($0, by: 1) }
        XCTAssertEqual(classifier.receive(Recording.threeFingerSwipe + later),
                       [.began, .cancelled, .began, .tap])
    }

    func testAClaimedHoldEndsWithoutATap() {
        var classifier = TrackpadTapClassifier(fingerCount: 3)
        XCTAssertEqual(classifier.receive(Array(Recording.threeFingerTap.prefix(3))), [.began])
        XCTAssertTrue(classifier.claimHold())
        XCTAssertFalse(classifier.claimHold(), "One hold opens once")
        XCTAssertEqual(classifier.receive(Array(Recording.threeFingerTap.dropFirst(3))), [])
    }

    // MARK: The trigger

    func testHoldingTheFingersStillForTheTrackpadDelayOpensTheMenu() {
        let rig = TrackpadRig(MenuTriggerConfiguration(trackpadTrigger: .threeFingers))
        rig.feed(Recording.threeFingerTap)
        rig.clock.advance(by: 1)
        XCTAssertEqual(rig.log, [], "A tap is shorter than the delay and stays with the system")
        rig.feed(Array(Recording.threeFingerRest.prefix(2)))
        rig.clock.advance(by: 0.2)
        XCTAssertEqual(rig.log, [])
        rig.clock.advance(by: 0.05)
        XCTAssertEqual(rig.log, ["menu"], "Held for 250 ms, the Menu opens where the pointer is")
        rig.feed(Array(Recording.threeFingerRest.dropFirst(2)))
        XCTAssertEqual(rig.log, ["menu"], "Lifting after the Menu opened does nothing more")
    }

    func testTheTrackpadDelayIsSeparateAndNeverUnder250Milliseconds() throws {
        let configuration = MenuTriggerConfiguration(openingDelay: 0, trackpadTrigger: .threeFingers,
                                                     trackpadOpeningDelay: 0)
        XCTAssertEqual(configuration.trackpadOpeningDelay, 0.25)
        XCTAssertEqual(MenuTriggerConfiguration(openingDelay: 0.6).trackpadOpeningDelay, 0.25,
                       "The mouse and keyboard delay does not set it")
        let rig = TrackpadRig(MenuTriggerConfiguration(openingDelay: 0.1, trackpadTrigger: .threeFingers,
                                                       trackpadOpeningDelay: 0.4))
        rig.feed(Array(Recording.threeFingerRest.prefix(2)))
        rig.clock.advance(by: 0.3)
        XCTAssertEqual(rig.log, [])
        rig.clock.advance(by: 0.1)
        XCTAssertEqual(rig.log, ["menu"])

        let suite = "TrackpadTapTriggerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(MenuTriggerConfiguration(defaults: defaults).trackpadOpeningDelay, 0.25)
        MenuTriggerConfiguration(trackpadOpeningDelay: 0.5).save(to: defaults)
        XCTAssertEqual(MenuTriggerConfiguration(defaults: defaults).trackpadOpeningDelay, 0.5)
        defaults.set(0.1, forKey: "trigger.trackpad-opening-delay")
        XCTAssertEqual(MenuTriggerConfiguration(defaults: defaults).trackpadOpeningDelay, 0.25)
    }

    func testOnlyTheChosenFingerCountOpensTheMenu() {
        let rig = TrackpadRig(MenuTriggerConfiguration(trackpadTrigger: .fourFingers))
        rig.feed(Array(Recording.threeFingerRest.prefix(2)) + [Recording.frame(10.7)])
        rig.clock.advance(by: 1)
        XCTAssertEqual(rig.log, [])
        rig.feed(Array(Recording.fourFingerTap.prefix(4)))
        rig.clock.advance(by: 0.25)
        XCTAssertEqual(rig.log, ["menu"])
    }

    func testLiftingBeforeTheDelayDoesNothing() {
        let rig = TrackpadRig(MenuTriggerConfiguration(trackpadTrigger: .threeFingers, trackpadOpeningDelay: 0.3))
        rig.feed(Recording.threeFingerTap)
        rig.clock.advance(by: 1)
        XCTAssertEqual(rig.log, [], "An early lift goes on to the App as it was")
        XCTAssertEqual(rig.clock.pending, 0)
    }

    func testMovingBeforeTheDelayIsTheSystemsGesture() {
        let rig = TrackpadRig(MenuTriggerConfiguration(clickDragEnabled: true, trackpadTrigger: .threeFingers))
        rig.feed(Array(Recording.threeFingerSwipe.prefix(3)))
        rig.clock.advance(by: 1)
        XCTAssertEqual(rig.log, [], "A swipe never opens the Menu, with Click & Drag too")
    }

    func testATapWhileTheMenuIsOpenClosesItAtOnce() {
        let rig = TrackpadRig(MenuTriggerConfiguration(openingDelay: 0.3, trackpadTrigger: .threeFingers))
        rig.menuIsOpen = true
        rig.feed(Recording.threeFingerTap)
        XCTAssertEqual(rig.log, ["menu"], "The delay governs opening only")
    }

    // MARK: Click & Drag

    func testWithClickAndDragTheFingersOpenTheMenuAndLiftOverAnItemToRunIt() throws {
        let rig = TrackpadRig(MenuTriggerConfiguration(clickDragEnabled: true, trackpadTrigger: .threeFingers))
        rig.holdOpen()
        XCTAssertEqual(rig.log, ["menu"], "The Menu opens once the fingers are held still")

        rig.feed([Recording.frame(10.050, Recording.moved(Recording.a, 0.005),
                                  Recording.moved(Recording.b, 0.005), Recording.moved(Recording.c, 0.005))])
        XCTAssertEqual(rig.log, ["menu"], "A few points of motion are not yet a drag")

        rig.feed([
            Recording.frame(10.100, Recording.moved(Recording.a, 0.1),
                            Recording.moved(Recording.b, 0.1), Recording.moved(Recording.c, 0.1)),
            Recording.frame(10.160, Recording.moved(Recording.b, 0.1), Recording.moved(Recording.c, 0.1)),
            Recording.frame(10.170)
        ])
        XCTAssertEqual(rig.log, ["menu", "drag", "release"])
        let end = try XCTUnwrap(rig.releasePoint)
        XCTAssertEqual(rig.dragPoints.last, end, "Lifting runs what the selection reached")
        XCTAssertGreaterThan(end.x, TrackpadRig.pointer.x + 8, "Selection follows the fingers to the right")
        XCTAssertEqual(end.y, TrackpadRig.pointer.y, accuracy: 0.001)
        XCTAssertEqual(rig.cursor.last, end, "The pointer follows, so the next Menu opens where this one ended")
    }

    func testTheDragStaysOnTheScreenTheMenuOpenedOn() throws {
        let rig = TrackpadRig(MenuTriggerConfiguration(clickDragEnabled: true, trackpadTrigger: .threeFingers))
        rig.holdOpen()
        rig.feed([Recording.frame(10.05, Recording.moved(Recording.a, 0.5),
                                  Recording.moved(Recording.b, 0.5), Recording.moved(Recording.c, 0.5))])
        XCTAssertEqual(rig.cursor.last?.x, TrackpadRig.screen.maxX - 1)
        rig.feed([Recording.frame(10.10, Recording.moved(Recording.a, 0.45),
                                  Recording.moved(Recording.b, 0.45), Recording.moved(Recording.c, 0.45))])
        XCTAssertLessThan(try XCTUnwrap(rig.cursor.last?.x), TrackpadRig.screen.maxX - 1,
                          "Coming back moves at once, with no distance lost past the edge")
    }

    func testAFasterDragTravelsFurtherLikeThePointer() throws {
        func travel(frames: Int, over seconds: TimeInterval) throws -> CGFloat {
            let rig = TrackpadRig(MenuTriggerConfiguration(clickDragEnabled: true, trackpadTrigger: .threeFingers))
            rig.holdOpen()
            for step in 1...frames {
                let distance = 0.1 * CGFloat(step) / CGFloat(frames)
                rig.feed([Recording.frame(10 + seconds * Double(step) / Double(frames),
                                          Recording.moved(Recording.a, distance),
                                          Recording.moved(Recording.b, distance),
                                          Recording.moved(Recording.c, distance))])
            }
            return try XCTUnwrap(rig.dragPoints.last).x - TrackpadRig.pointer.x
        }
        let slow = try travel(frames: 25, over: 1.0)
        let fast = try travel(frames: 5, over: 0.05)
        XCTAssertGreaterThan(slow, 8, "A slow drag still moves")
        XCTAssertGreaterThan(fast, slow * 1.5, "Faster motion is accelerated, as the pointer is")
    }

    func testAFingerLiftingFirstDoesNotJumpTheSelection() throws {
        let rig = TrackpadRig(MenuTriggerConfiguration(clickDragEnabled: true, trackpadTrigger: .threeFingers))
        rig.holdOpen()
        rig.feed([
            Recording.frame(10.100, Recording.moved(Recording.a, 0.1), Recording.b, Recording.moved(Recording.c, 0.1))
        ])
        let before = try XCTUnwrap(rig.dragPoints.last)
        rig.feed([Recording.frame(10.110, Recording.b, Recording.moved(Recording.c, 0.1))])
        XCTAssertEqual(rig.dragPoints.last, before, "Only motion moves the selection")
    }

    func testWithClickAndDragLiftingWithoutMovingLeavesTheMenuOpenForPointing() {
        let rig = TrackpadRig(MenuTriggerConfiguration(clickDragEnabled: true, trackpadTrigger: .threeFingers))
        rig.holdOpen()
        rig.feed([Recording.frame(10.400)])
        XCTAssertEqual(rig.log, ["menu"])
        XCTAssertNil(rig.releasePoint)
    }

    func testWithClickAndDragAndADelayTheDragStartsOnceTheMenuHasOpened() {
        let rig = TrackpadRig(MenuTriggerConfiguration(clickDragEnabled: true, trackpadTrigger: .threeFingers,
                                                       trackpadOpeningDelay: 0.3))
        rig.feed([Recording.frame(10.000, Recording.a, Recording.b, Recording.c)])
        XCTAssertEqual(rig.log, [])
        rig.clock.advance(by: 0.3)
        XCTAssertEqual(rig.log, ["menu"])
        rig.feed([
            Recording.frame(10.400, Recording.moved(Recording.a, -0.1),
                            Recording.moved(Recording.b, -0.1), Recording.moved(Recording.c, -0.1)),
            Recording.frame(10.450)
        ])
        XCTAssertEqual(rig.log, ["menu", "drag", "release"])

        rig.log = []
        rig.feed(Recording.threeFingerSwipe.map { Recording.shifted($0, by: 1) })
        rig.clock.advance(by: 1)
        XCTAssertEqual(rig.log, [], "Moving before the delay is the system's swipe, not a selection")
    }

    func testWithClickAndDragFingersLandingOnAnOpenMenuCloseItAtOnce() {
        let rig = TrackpadRig(MenuTriggerConfiguration(clickDragEnabled: true, trackpadTrigger: .threeFingers))
        rig.menuIsOpen = true
        rig.feed(Recording.threeFingerSwipe)
        XCTAssertEqual(rig.log, ["menu"], "Closing never drags")
    }

    func testFingersSpinnetTookKeepTheSystemsThreeFingerDragClicksFromTheMenu() {
        let rig = TrackpadRig(MenuTriggerConfiguration(clickDragEnabled: true, trackpadTrigger: .threeFingers))
        rig.holdOpen()
        XCTAssertTrue(rig.leftMouse(.leftMouseDown), "Three-finger drag's press would close the Menu")
        rig.feed([Recording.frame(10.100, Recording.moved(Recording.a, 0.1),
                                  Recording.moved(Recording.b, 0.1), Recording.moved(Recording.c, 0.1))])
        XCTAssertTrue(rig.leftMouse(.leftMouseDragged))
        rig.feed([Recording.frame(10.150)])
        XCTAssertTrue(rig.leftMouse(.leftMouseUp), "Its release follows the press")
        XCTAssertFalse(rig.leftMouse(.leftMouseDown), "The next click is the user's")
        XCTAssertFalse(rig.leftMouse(.leftMouseUp))
        XCTAssertEqual(rig.log, ["menu", "drag", "release"])
    }

    func testWhenTheSystemDragsThePointerTheSelectionFollowsItExactly() throws {
        let rig = TrackpadRig(MenuTriggerConfiguration(clickDragEnabled: true, trackpadTrigger: .threeFingers))
        rig.holdOpen()
        XCTAssertTrue(rig.leftMouse(.leftMouseDown))
        let systemPointer = CGPoint(x: TrackpadRig.pointer.x + 40, y: TrackpadRig.pointer.y - 30)
        XCTAssertTrue(rig.leftMouse(.leftMouseDragged, at: systemPointer), "Three-finger drag moves the pointer")
        let moves = rig.cursor.count
        rig.feed([Recording.frame(10.100, Recording.moved(Recording.a, 0.1),
                                  Recording.moved(Recording.b, 0.1), Recording.moved(Recording.c, 0.1))])
        XCTAssertEqual(rig.cursor.count, moves, "Spinnet no longer moves a pointer the system moves")
        XCTAssertEqual(rig.dragPoints.last, systemPointer)
        rig.feed([Recording.frame(10.150)])
        XCTAssertEqual(rig.releasePoint, systemPointer)
        XCTAssertEqual(rig.log, ["menu", "drag", "release"])
    }

    func testAPressWhoseReleaseNeverComesIsForgottenSoon() {
        let rig = TrackpadRig(MenuTriggerConfiguration(clickDragEnabled: true, trackpadTrigger: .threeFingers))
        rig.holdOpen()
        XCTAssertTrue(rig.leftMouse(.leftMouseDown))
        rig.feed([Recording.frame(10.150)])
        XCTAssertFalse(rig.leftMouse(.leftMouseDown), "A new press after the lift is the user's click")
        XCTAssertFalse(rig.leftMouse(.leftMouseUp))
    }

    func testAKeptPressesLateReleaseIsKeptOnlyBriefly() {
        let rig = TrackpadRig(MenuTriggerConfiguration(clickDragEnabled: true, trackpadTrigger: .threeFingers))
        rig.holdOpen()
        XCTAssertTrue(rig.leftMouse(.leftMouseDown))
        rig.feed([Recording.frame(10.150)])
        XCTAssertTrue(rig.leftMouse(.leftMouseUp), "Its own release still follows the kept press")
        rig.clock.advance(by: 1)
        XCTAssertFalse(rig.leftMouse(.leftMouseUp))
    }

    func testADragEndsWithoutRunningAnythingWhenTheMenuClosedMeanwhile() {
        let rig = TrackpadRig(MenuTriggerConfiguration(clickDragEnabled: true, trackpadTrigger: .threeFingers))
        rig.holdOpen()
        rig.feed([Recording.frame(10.100, Recording.moved(Recording.a, 0.1),
                                  Recording.moved(Recording.b, 0.1), Recording.moved(Recording.c, 0.1))])
        rig.menuIsOpen = false
        let moves = rig.cursor.count
        rig.feed([Recording.frame(10.200, Recording.moved(Recording.a, 0.2),
                                  Recording.moved(Recording.b, 0.2), Recording.moved(Recording.c, 0.2)),
                  Recording.frame(10.250)])
        XCTAssertEqual(rig.cursor.count, moves, "Escape closed the Menu; the fingers move nothing")
        XCTAssertNil(rig.releasePoint)
    }

    func testAHoldDoesNotCloseAMenuThatOpenedMeanwhile() {
        let rig = TrackpadRig(MenuTriggerConfiguration(trackpadTrigger: .threeFingers, trackpadOpeningDelay: 0.3))
        rig.feed(Array(Recording.threeFingerRest.prefix(2)))
        rig.menuIsOpen = true
        rig.clock.advance(by: 0.3)
        rig.feed(Array(Recording.threeFingerRest.dropFirst(2)))
        XCTAssertEqual(rig.log, [])
    }

    func testChangingTheDelayMidGestureDropsTheWaitingHold() {
        let rig = TrackpadRig(MenuTriggerConfiguration(trackpadTrigger: .threeFingers, trackpadOpeningDelay: 0.3))
        XCTAssertTrue(rig.controller.start(configuration: rig.controller.configuration))
        defer { rig.controller.stop() }
        rig.feed(Array(Recording.threeFingerRest.prefix(2)))
        _ = rig.controller.apply(MenuTriggerConfiguration(trackpadTrigger: .threeFingers, trackpadOpeningDelay: 0.5))
        rig.clock.advance(by: 1)
        XCTAssertEqual(rig.log, [])
        XCTAssertEqual(rig.clock.pending, 0)
    }

    func testClicksAreLeftAloneWhileSpinnetHasNotTakenTheFingers() {
        let rig = TrackpadRig(MenuTriggerConfiguration(trackpadTrigger: .threeFingers))
        XCTAssertFalse(rig.leftMouse(.leftMouseDown))
        XCTAssertFalse(rig.leftMouse(.leftMouseUp))
        rig.feed(Array(Recording.threeFingerTap.prefix(3)))
        XCTAssertFalse(rig.leftMouse(.leftMouseDown), "A tap is not yet Spinnet's while the fingers are down")
        XCTAssertFalse(rig.leftMouse(.leftMouseUp))
    }

    func testTheTrackpadIsReadOnlyWhileItsTriggerIsChosenAndSpinnetIsOn() {
        let rig = TrackpadRig(MenuTriggerConfiguration())
        XCTAssertTrue(rig.controller.start(configuration: MenuTriggerConfiguration()))
        defer { rig.controller.stop() }
        XCTAssertEqual(rig.liveTaps, 0, "No trackpad trigger, no trackpad tap")

        _ = rig.controller.apply(MenuTriggerConfiguration(trackpadTrigger: .threeFingers))
        XCTAssertEqual(rig.liveTaps, 1)
        rig.deliver(Array(Recording.threeFingerRest.prefix(2)))
        rig.clock.advance(by: 0.25)
        XCTAssertEqual(rig.log, ["menu"])

        _ = rig.controller.apply(MenuTriggerConfiguration(trackpadTrigger: .off))
        XCTAssertEqual(rig.liveTaps, 0)

        _ = rig.controller.apply(MenuTriggerConfiguration(trackpadTrigger: .fourFingers))
        rig.controller.stop()
        XCTAssertEqual(rig.liveTaps, 0, "Switched off, Spinnet stops reading the trackpad")
    }

    func testTheTriggerIsSavedWithTheOtherTriggers() throws {
        let suite = "TrackpadTapTriggerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(MenuTriggerConfiguration(defaults: defaults).trackpadTrigger, .off)
        MenuTriggerConfiguration(trackpadTrigger: .fourFingers).save(to: defaults)
        XCTAssertEqual(MenuTriggerConfiguration(defaults: defaults).trackpadTrigger, .fourFingers)
    }

    // MARK: Settings

    func testSettingsChooseTheGestureAndNameASystemGestureThatUsesIt() throws {
        let suite = "TrackpadTapTriggerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // Look Up & data detectors set to "Tap with three fingers".
        var trackpadSettings = ["TrackpadThreeFingerTapGesture": 2]
        let model = SettingsWindowModel(
            editor: try makeEditor(), metadata: .current, defaults: defaults,
            trackpadConflictCheck: {
                TrackpadGestureConflictDetector(setting: { trackpadSettings[$0] }).detect($0)
            }
        )
        var applied: [TrackpadTrigger] = []
        model.trigger.onChange = { applied.append($0.trackpadTrigger) }
        model.selectPage(.menu)
        let lookUp = "Look Up & data detectors also uses a three-finger tap. "
            + "Set it to Force Click with one finger in System Settings → Trackpad, or choose Four Fingers."

        XCTAssertTrue(model.accessibleNames.contains("Trackpad: Off"))
        XCTAssertFalse(model.accessibleNames.contains(lookUp), "Off conflicts with nothing")

        model.trigger.trackpadTrigger = .threeFingers
        XCTAssertEqual(applied, [.threeFingers])
        XCTAssertEqual(MenuTriggerConfiguration(defaults: defaults).trackpadTrigger, .threeFingers)
        XCTAssertTrue(model.accessibleNames.contains("Trackpad: Three Fingers"))
        XCTAssertTrue(model.accessibleNames.contains(lookUp))
        try HostLocalization.withLanguage(.simplifiedChinese) {
            XCTAssertTrue(model.accessibleNames.contains("触控板：三指"))
        }
        model.selectPage(.general)
        XCTAssertTrue(model.accessibleNames.contains("Trackpad Opening Delay: 250 ms"))
        model.trigger.trackpadOpeningDelay = 0.1
        XCTAssertTrue(model.accessibleNames.contains("Trackpad Opening Delay: 250 ms"), "Never under 250 ms")
        model.trigger.trackpadOpeningDelay = 0.4
        XCTAssertEqual(MenuTriggerConfiguration(defaults: defaults).trackpadOpeningDelay, 0.4)
        model.selectPage(.menu)

        trackpadSettings = [:]
        model.trigger.refreshConflicts()
        XCTAssertFalse(model.accessibleNames.contains(lookUp), "Changed in System Settings meanwhile")

        trackpadSettings = ["TrackpadThreeFingerTapGesture": 2]
        model.trigger.trackpadTrigger = .fourFingers
        XCTAssertFalse(model.accessibleNames.contains(lookUp), "No system gesture taps with four fingers")

        model.trigger.trackpadTrigger = .off
        model.selectPage(.general)
        XCTAssertFalse(model.accessibleNames.contains { $0.hasPrefix("Trackpad Opening Delay") },
                       "Without a trackpad trigger there is no trackpad delay to set")
    }

    func testClickAndDragNamesTheSystemGesturesThatAlsoFollowTheFingers() {
        let settings = [
            "TrackpadThreeFingerDrag": 1,
            "TrackpadThreeFingerHorizSwipeGesture": 1,
            "TrackpadThreeFingerVertSwipeGesture": 0,
            "TrackpadFourFingerVertSwipeGesture": 2
        ]
        let detector = TrackpadGestureConflictDetector(setting: { settings[$0] })
        func conflicts(_ trigger: TrackpadTrigger, drag: Bool) -> [String] {
            detector.detect(MenuTriggerConfiguration(clickDragEnabled: drag, trackpadTrigger: trigger)).map(\.id)
        }
        XCTAssertEqual(conflicts(.threeFingers, drag: false), [], "A tap does not move the fingers")
        XCTAssertEqual(conflicts(.threeFingers, drag: true), ["three-finger-swipes"],
                       "Three-finger drag is followed, not a conflict")
        XCTAssertEqual(conflicts(.fourFingers, drag: true), ["four-finger-swipes"])
        XCTAssertEqual(conflicts(.off, drag: true), [])
    }
}

private final class TrackpadRig {
    let controller: GlobalTriggerController
    let clock = TrackpadClock()
    var log: [String] = []
    var menuIsOpen = false
    var dragPoints: [CGPoint] = []
    var releasePoint: CGPoint?
    var cursor: [CGPoint] = []
    static let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    static let pointer = CGPoint(x: 500, y: 400)
    private var taps: [(connection: FakeTap, handler: (TrackpadInput) -> Bool)] = []

    var liveTaps: Int { taps.filter { $0.connection.isEnabled }.count }

    init(_ configuration: MenuTriggerConfiguration) {
        let clock = self.clock
        var install: (@escaping (TrackpadInput) -> Bool) -> MouseEventTapConnection? = { _ in nil }
        var moveCursor: (CGPoint) -> Void = { _ in }
        controller = GlobalTriggerController(
            scheduleDelay: { clock.schedule(after: $0, $1) },
            createMouseEventTap: { _ in FakeTap() },
            otherMouseEventTapIDs: { [] },
            createTrackpadTouchTap: { install($0) },
            pointerLocation: { TrackpadRig.pointer }, trackingSpeed: { 1 },
            screenFrame: { _ in TrackpadRig.screen },
            moveCursor: { moveCursor($0) }
        )
        moveCursor = { [weak self] in self?.cursor.append($0) }
        install = { [weak self] handler in
            let tap = FakeTap()
            self?.taps.append((tap, handler))
            return tap
        }
        controller.configuration = configuration
        controller.isMenuOpen = { [weak self] in self?.menuIsOpen ?? false }
        controller.onInvoke = { [weak self] in
            self?.log.append("menu")
            self?.menuIsOpen.toggle()
        }
        controller.onMouseDrag = { [weak self] point in
            self?.dragPoints.append(point)
            if self?.log.last != "drag" { self?.log.append("drag") }
        }
        controller.onMouseDragRelease = { [weak self] point in
            self?.releasePoint = point
            self?.log.append("release")
            self?.menuIsOpen = false
        }
    }

    /// Three fingers land and stay still for the default trackpad delay.
    func holdOpen() {
        feed([Recording.frame(10.000, Recording.a, Recording.b, Recording.c)])
        clock.advance(by: 0.25)
    }

    /// Frames as the classifier receives them, without a tap.
    func feed(_ frames: [TrackpadTouchFrame]) {
        frames.forEach(controller.receiveTrackpadFrame)
    }

    /// Frames through the installed tap, as the trackpad reports them.
    func deliver(_ frames: [TrackpadTouchFrame]) {
        for frame in frames {
            for tap in taps where tap.connection.isEnabled { _ = tap.handler(.frame(frame)) }
        }
    }

    /// A left-button event as the tap sees it; true when Spinnet keeps it
    /// from the App.
    func leftMouse(_ type: CGEventType, at location: CGPoint = TrackpadRig.pointer) -> Bool {
        controller.receiveTrackpadInput(.leftMouse(type, at: location))
    }
}

private final class FakeTap: MouseEventTapConnection {
    var isEnabled = true
    func enable() { isEnabled = true }
    func invalidate() { isEnabled = false }
}

private final class TrackpadClock {
    private var now: TimeInterval = 0
    private var tasks: [(id: Int, due: TimeInterval, work: () -> Void)] = []
    private var nextID = 0

    var pending: Int { tasks.count }

    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> () -> Void {
        nextID += 1
        let id = nextID
        tasks.append((id, now + delay, work))
        return { [weak self] in self?.tasks.removeAll { $0.id == id } }
    }

    func advance(by interval: TimeInterval) {
        now += interval
        while let index = tasks.firstIndex(where: { $0.due <= now + 1e-9 }) {
            tasks.remove(at: index).work()
        }
    }
}

/// Touch frames shaped like the trackpad's reports: fingers land a few
/// milliseconds apart, stay nearly still, and lift a few milliseconds apart.
private enum Recording {
    static let a = TrackpadTouch(id: 1, position: CGPoint(x: 0.40, y: 0.50))
    static let b = TrackpadTouch(id: 2, position: CGPoint(x: 0.50, y: 0.52))
    static let c = TrackpadTouch(id: 3, position: CGPoint(x: 0.60, y: 0.50))
    static let d = TrackpadTouch(id: 4, position: CGPoint(x: 0.70, y: 0.45))

    static func frame(_ time: TimeInterval, _ touches: TrackpadTouch...) -> TrackpadTouchFrame {
        TrackpadTouchFrame(time: time, touches: touches)
    }

    static let threeFingerTap = [
        frame(10.000, a),
        frame(10.012, a, b),
        frame(10.020, a, b, c),
        frame(10.090, a, b, c),
        frame(10.130, b, c),
        frame(10.140)
    ]

    /// The first finger, landed again after lifting: a new identity.
    static let a2 = TrackpadTouch(id: 5, position: CGPoint(x: 0.40, y: 0.50))

    static let fourFingerTap = [
        frame(10.000, a, b),
        frame(10.010, a, b, c),
        frame(10.018, a, b, c, d),
        frame(10.100, a, b, c, d),
        frame(10.120)
    ]

    static let threeFingerSwipe = [
        frame(10.000, a, b, c),
        frame(10.040, moved(a, 0.02), moved(b, 0.02), moved(c, 0.02)),
        frame(10.080, moved(a, 0.08), moved(b, 0.08), moved(c, 0.08)),
        frame(10.120, moved(a, 0.15), moved(b, 0.15), moved(c, 0.15)),
        frame(10.140)
    ]

    static let threeFingerRest = [
        frame(10.000, a, b, c),
        frame(10.200, a, b, c),
        frame(10.600, a, b, c),
        frame(10.610)
    ]

    static let threeFingersOneByOne = [
        frame(10.000, a, b),
        frame(10.300, a, b, c),
        frame(10.360)
    ]

    static func moved(_ touch: TrackpadTouch, _ distance: CGFloat) -> TrackpadTouch {
        TrackpadTouch(id: touch.id, position: CGPoint(x: touch.position.x + distance, y: touch.position.y))
    }

    static func shifted(_ frame: TrackpadTouchFrame, by seconds: TimeInterval) -> TrackpadTouchFrame {
        TrackpadTouchFrame(time: frame.time + seconds, touches: frame.touches)
    }
}

private extension TrackpadTapClassifier {
    mutating func receive(_ frames: [TrackpadTouchFrame]) -> [TrackpadTapEvent] {
        frames.compactMap { receive($0) }
    }
}
