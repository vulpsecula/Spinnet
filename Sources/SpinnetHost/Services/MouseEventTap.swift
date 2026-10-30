import AppKit

typealias MouseEventTapHandler = (CGEventType, CGEvent) -> Unmanaged<CGEvent>?

/// The lifetime of one active mouse filter. Keeping the native connection
/// here lets input tests exercise installation order as well as dispatch.
protocol MouseEventTapConnection: AnyObject {
    var isEnabled: Bool { get }
    func enable()
    func invalidate()
}

final class QuartzMouseEventTap: MouseEventTapConnection {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let handler: MouseEventTapHandler

    private init(handler: @escaping MouseEventTapHandler) {
        self.handler = handler
    }

    static func connect(handler: @escaping MouseEventTapHandler) -> MouseEventTapConnection? {
        let connection = QuartzMouseEventTap(handler: handler)
        let mask = (CGEventMask(1) << CGEventType.otherMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.otherMouseUp.rawValue)
            | (CGEventMask(1) << CGEventType.otherMouseDragged.rawValue)
            | (CGEventMask(1) << CGEventType.mouseMoved.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: GlobalTriggerController.mouseEventTapLocation,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return Unmanaged<QuartzMouseEventTap>.fromOpaque(context)
                    .takeUnretainedValue().handler(type, event)
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

    /// Watch only active HID button filters in other processes. Device
    /// changes can enable an existing driver tap without changing its ID.
    static func otherButtonTapIDs() -> Set<UInt32>? {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success else { return nil }
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count) + 8)
        guard CGGetEventTapList(UInt32(taps.count), &taps, &count) == .success else { return nil }
        let buttonMask = (CGEventMask(1) << CGEventType.otherMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.otherMouseUp.rawValue)
        return Set(taps.prefix(Int(count)).filter {
            $0.tappingProcess != ProcessInfo.processInfo.processIdentifier
                && $0.tapPoint == GlobalTriggerController.mouseEventTapLocation
                && $0.enabled
                && $0.options.rawValue & CGEventTapOptions.listenOnly.rawValue == 0
                && $0.eventsOfInterest & buttonMask != 0
        }.map(\.eventTapID))
    }
}
