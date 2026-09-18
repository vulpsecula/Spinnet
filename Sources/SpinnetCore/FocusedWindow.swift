import Foundation

/// A rectangle in global screen coordinates, with the origin at the top-left
/// of the primary display and y growing downwards, as Accessibility reports
/// window frames.
public struct WindowRect: Codable, Equatable, Hashable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    /// No display arrangement reaches this far, so a coordinate beyond it is a
    /// malformed request rather than a window somewhere off to the side.
    public static let coordinateLimit: Double = 100_000

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Reads exactly `x`, `y`, `width`, and `height`, rejecting anything else,
    /// so a request cannot carry a target or an operation alongside its bounds.
    public init?(json: JSONValue) {
        guard case .object(let fields) = json, fields.count == 4,
              case .number(let x) = fields["x"], case .number(let y) = fields["y"],
              case .number(let width) = fields["width"], case .number(let height) = fields["height"],
              [x, y].allSatisfy({ $0.isFinite && abs($0) <= Self.coordinateLimit }),
              [width, height].allSatisfy({ $0.isFinite && $0 > 0 && $0 <= Self.coordinateLimit }) else {
            return nil
        }
        self.init(x: x, y: y, width: width, height: height)
    }
}

/// What a Plugin learns about the focused window: where it is, the part of
/// its screen that windows may occupy, and the same for every display, so a
/// Plugin can move the window to another one. Nothing identifies the window or
/// its application, and nothing else in the accessibility tree is exposed.
public struct FocusedWindow: Codable, Equatable {
    public let frame: WindowRect
    public let visibleFrame: WindowRect
    /// Every display's visible frame, left to right and then top to bottom.
    public let displays: [WindowRect]
    /// The position in `displays` of the display holding the window.
    public let displayIndex: Int

    /// Without a list of displays, the window's own screen is the only one.
    public init(frame: WindowRect, visibleFrame: WindowRect, displays: [WindowRect]? = nil, displayIndex: Int = 0) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.displays = displays ?? [visibleFrame]
        self.displayIndex = displayIndex
    }
}
