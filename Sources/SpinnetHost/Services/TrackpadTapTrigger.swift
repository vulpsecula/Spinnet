import AppKit

/// The trackpad gesture that opens the Menu, chosen under Settings → Menu.
enum TrackpadTrigger: String, CaseIterable, Equatable {
    case off
    case threeFingerTap = "three-finger-tap" // Not localized: a file path or saved key
    case fourFingerTap = "four-finger-tap" // Not localized: a file path or saved key

    /// How many fingers tap together, or nil when the trackpad does not open
    /// the Menu.
    var fingerCount: Int? {
        switch self {
        case .off: return nil
        case .threeFingerTap: return 3
        case .fourFingerTap: return 4
        }
    }

    var displayName: String {
        switch self {
        case .off: return localized("Off")
        case .threeFingerTap: return localized("Three-Finger Tap")
        case .fourFingerTap: return localized("Four-Finger Tap")
        }
    }
}

/// One finger on the trackpad: its identity for as long as it touches, and
/// where it is, from 0 to 1 across the trackpad's surface.
struct TrackpadTouch: Equatable {
    let id: Int
    let position: CGPoint
}

/// What the trackpad reported at one moment: every finger touching it that
/// is not resting. An empty frame means every finger has lifted.
struct TrackpadTouchFrame: Equatable {
    /// A built-in MacBook trackpad, about 16 by 10 cm, for frames that do not
    /// say.
    static let typicalDeviceSize = CGSize(width: 453, height: 283)

    let time: TimeInterval
    let touches: [TrackpadTouch]
    /// The trackpad's physical size in points of 1/72 inch.
    var deviceSize = typicalDeviceSize

    /// Where each finger is, by its identity.
    var positions: [Int: CGPoint] {
        Dictionary(touches.map { ($0.id, $0.position) }, uniquingKeysWith: { first, _ in first })
    }
}

/// What the trackpad tap sees: the fingers on the trackpad, and the
/// left-button events the system makes from them, such as three-finger drag.
enum TrackpadInput: Equatable {
    case frame(TrackpadTouchFrame)
    /// A left-button event and where it puts the pointer, in AppKit screen
    /// coordinates.
    case leftMouse(CGEventType, at: CGPoint)
}

enum TrackpadTapEvent: Equatable {
    /// The chosen number of fingers landed together and are still: a tap or
    /// a hold may follow.
    case began
    /// They lifted together soon enough, without moving.
    case tap
    /// What began is no longer a tap or a hold: a finger moved, another
    /// landed, or the fingers stayed too long.
    case cancelled
}

/// Recognizes a tap of a fixed number of fingers in recorded touch frames.
///
/// The fingers must land within `landingWindow` of the first, none may move
/// further than `movementLimit` across the surface, no other finger may join,
/// and every finger must lift within `tapDuration` of the first landing. A
/// hold is claimed by the trigger while the fingers are still down; the lift
/// that follows it is then nobody's tap.
struct TrackpadTapClassifier {
    static let landingWindow: TimeInterval = 0.15
    static let tapDuration: TimeInterval = 0.35
    static let movementLimit: CGFloat = 0.04

    let fingerCount: Int

    private enum Phase {
        case idle
        /// Fingers are landing, fewer than `fingerCount` so far.
        case landing
        /// Exactly `fingerCount` fingers are down and still.
        case down
        /// Some of those fingers have lifted, none has landed.
        case lifting
        /// Not a tap: ignore everything until every finger lifts.
        case rejected
    }

    private var phase = Phase.idle
    private var firstLanding: TimeInterval = 0
    private var origins: [Int: CGPoint] = [:]

    init(fingerCount: Int) {
        self.fingerCount = fingerCount
    }

    mutating func receive(_ frame: TrackpadTouchFrame) -> TrackpadTapEvent? {
        let touches = frame.touches
        if touches.isEmpty { return lift(at: frame.time) }
        switch phase {
        case .rejected:
            return nil
        case .idle:
            phase = .landing
            firstLanding = frame.time
            origins = [:]
        case .landing, .down, .lifting:
            break
        }

        let landed = touches.filter { origins[$0.id] == nil }
        if phase == .down || phase == .lifting, !landed.isEmpty { return reject() }
        for touch in landed { origins[touch.id] = touch.position }
        if touches.contains(where: { moved($0) }) || touches.count > fingerCount { return reject() }

        switch phase {
        case .landing:
            guard frame.time - firstLanding <= Self.landingWindow else { return reject() }
            guard touches.count == fingerCount else { return nil }
            phase = .down
            return .began
        case .down:
            if touches.count < fingerCount { phase = .lifting }
            return nil
        default:
            return nil
        }
    }

    /// The trigger opened the Menu on a hold: the fingers' lift is not a tap.
    mutating func claimHold() -> Bool {
        guard phase == .down else { return false }
        phase = .rejected
        return true
    }

    private mutating func lift(at time: TimeInterval) -> TrackpadTapEvent? {
        let previous = phase
        phase = .idle
        origins = [:]
        switch previous {
        case .down, .lifting:
            return time - firstLanding <= Self.tapDuration ? .tap : .cancelled
        case .idle, .landing, .rejected:
            return nil
        }
    }

    private mutating func reject() -> TrackpadTapEvent? {
        let began = phase == .down || phase == .lifting
        phase = .rejected
        return began ? .cancelled : nil
    }

    private func moved(_ touch: TrackpadTouch) -> Bool {
        guard let origin = origins[touch.id] else { return false }
        return hypot(touch.position.x - origin.x, touch.position.y - origin.y) > Self.movementLimit
    }
}

/// Reads the fingers on the trackpad from the gesture events the window
/// server sends while a trackpad is touched, through the public `NSTouch`
/// interface. Touches always pass on unchanged: a tap of three or four
/// fingers has no action of its own for an App, so there is nothing to hold
/// back. Left-button events pass too, except those the handler keeps while
/// Spinnet has taken the fingers, so that the system's three-finger drag
/// does not click the Menu. An active tap, rather than a listen-only one,
/// keeps the required System Permission at Accessibility, as for the mouse
/// trigger.
final class QuartzTrackpadTouchTap: MouseEventTapConnection {
    /// `NSEvent.EventType.gesture`, which `CGEventType` does not name.
    static let gestureEventType = UInt32(NSEvent.EventType.gesture.rawValue)

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let handler: (TrackpadInput) -> Bool

    private init(handler: @escaping (TrackpadInput) -> Bool) {
        self.handler = handler
    }

    static func connect(handler: @escaping (TrackpadInput) -> Bool) -> MouseEventTapConnection? {
        let connection = QuartzTrackpadTouchTap(handler: handler)
        let mask = (CGEventMask(1) << CGEventMask(gestureEventType))
            | (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseDragged.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let keeps = Unmanaged<QuartzTrackpadTouchTap>.fromOpaque(context)
                    .takeUnretainedValue().receive(type: type, event: event)
                return keeps ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(connection).toOpaque()
        ) else { return nil }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        connection.tap = tap
        connection.source = source
        connection.enable()
        return connection
    }

    /// Whether the event is kept from the App.
    private func receive(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            enable()
            return false
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            let location = NSEvent(cgEvent: event)?.locationInWindow ?? NSEvent.mouseLocation
            return handler(.leftMouse(type, at: location))
        default:
            guard type.rawValue == Self.gestureEventType,
                  let gesture = NSEvent(cgEvent: event) else { return false }
            _ = handler(.frame(Self.frame(of: gesture)))
            return false
        }
    }

    /// The fingers touching the trackpad in `event`, without resting ones
    /// such as a thumb lying at its edge.
    static func frame(of event: NSEvent) -> TrackpadTouchFrame {
        let fingers = event.allTouches()
            .filter { !$0.isResting && !$0.phase.isDisjoint(with: [.began, .moved, .stationary]) }
        let touches = fingers
            .map { TrackpadTouch(id: ($0.identity as AnyObject).hash, position: $0.normalizedPosition) }
            .sorted { $0.id < $1.id }
        let size = fingers.first?.deviceSize ?? .zero
        return TrackpadTouchFrame(time: event.timestamp, touches: touches,
                                  deviceSize: size.width > 0 && size.height > 0 ? size : TrackpadTouchFrame.typicalDeviceSize)
    }

    var isEnabled: Bool {
        tap.map { CFMachPortIsValid($0) && CGEvent.tapIsEnabled(tap: $0) } ?? false
    }

    func enable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    func invalidate() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
    }

    deinit { invalidate() }
}
