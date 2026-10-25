import Foundation

/// Where each window was before Spinnet last moved it, so Restore can put it
/// back. The Host keeps this in memory only; a Plugin never sees a window key
/// or a remembered frame.
///
/// `Window` is an opaque key the Host chooses for a window. There is at most
/// one remembered frame per window, and only the `capacity` most recently
/// moved windows are kept.
public struct RememberedWindowFrames<Window: Hashable> {
    private struct Entry {
        let window: Window
        /// The frame the window had before the first of Spinnet's consecutive moves.
        let original: WindowRect
        /// The frame the window had after Spinnet's most recent move.
        let applied: WindowRect
    }

    public let capacity: Int
    /// Least recently moved first.
    private var entries: [Entry] = []

    public init(capacity: Int = 50) {
        self.capacity = max(1, capacity)
    }

    /// The windows with a remembered frame, least recently moved first.
    public var windows: [Window] { entries.map(\.window) }

    /// Records that Spinnet moved `window` from `previous` to `applied`. A
    /// window still where Spinnet last put it keeps the frame it had before
    /// that earlier move, so consecutive layouts restore to the first one's
    /// starting point; a window the user has moved since is remembered from
    /// where the user left it.
    public mutating func recordMove(of window: Window, from previous: WindowRect, to applied: WindowRect) {
        let existing = entries.firstIndex { $0.window == window }.map { entries.remove(at: $0) }
        let original = existing.map { Self.isUnmoved(previous, since: $0.applied) ? $0.original : previous } ?? previous
        entries.append(Entry(window: window, original: original, applied: applied))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    /// Applications round or nudge a frame after it is set, so a window within
    /// this many points of where Spinnet put it has not been moved since.
    public static var unmovedTolerance: Double { 2 }

    private static func isUnmoved(_ frame: WindowRect, since applied: WindowRect) -> Bool {
        [frame.x - applied.x, frame.y - applied.y, frame.width - applied.width, frame.height - applied.height]
            .allSatisfy { abs($0) <= unmovedTolerance }
    }

    /// The frame `window` had before Spinnet last moved it, or `nil` when
    /// Spinnet has not moved it or has already put it back.
    public func frameToRestore(for window: Window) -> WindowRect? {
        entries.last { $0.window == window }?.original
    }

    /// Forgets a window that was restored.
    public mutating func forget(_ window: Window) {
        entries.removeAll { $0.window == window }
    }

    /// Forgets every window matching `isGone`, such as windows that closed.
    public mutating func forget(where isGone: (Window) -> Bool) {
        entries.removeAll { isGone($0.window) }
    }
}

extension PluginHostServiceError {
    /// Restore was asked for a window Spinnet has not moved, or has already
    /// put back. Nothing moves.
    public static let nothingToRestore = PluginHostServiceError.unavailable(
        "Spinnet has not moved the focused window, so there is nothing to restore"
    )
}
