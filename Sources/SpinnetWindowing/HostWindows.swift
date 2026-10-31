import AppKit

/// Desktop scope is a Host invariant, independent of floating, pinning,
/// keyboard focus and window content. Preserve those choices while keeping
/// each window on one Desktop; explicit activation may move it to the current one.
private enum HostDesktopPolicy {
    static func behavior(_ requested: NSWindow.CollectionBehavior) -> NSWindow.CollectionBehavior {
        requested.subtracting(.canJoinAllSpaces).union(.moveToActiveSpace)
    }
}

/// Base for every Host-owned window. Subclasses customize their content and
/// interaction without being able to override the Desktop constraint.
open class HostWindow: NSWindow {
    public override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                         backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        super.collectionBehavior = HostDesktopPolicy.behavior(super.collectionBehavior)
    }

    public final override var collectionBehavior: NSWindow.CollectionBehavior {
        get { super.collectionBehavior }
        set { super.collectionBehavior = HostDesktopPolicy.behavior(newValue) }
    }
}

/// The same Desktop constraint for panels, including non-activating panels
/// shown over a full-screen App. Pinning changes level, never Desktop scope.
open class HostPanel: NSPanel {
    public override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                         backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        super.collectionBehavior = HostDesktopPolicy.behavior(super.collectionBehavior).union(.fullScreenAuxiliary)
    }

    public final override var collectionBehavior: NSWindow.CollectionBehavior {
        get { super.collectionBehavior }
        set { super.collectionBehavior = HostDesktopPolicy.behavior(newValue) }
    }
}

/// Applies the same Desktop policy at the construction boundary of
/// AppKit-owned native dialogs.
public enum HostDialogs {
    public static func makeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.window.collectionBehavior = HostDesktopPolicy.behavior(alert.window.collectionBehavior)
        return alert
    }

    public static func makeOpenPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.collectionBehavior = HostDesktopPolicy.behavior(panel.collectionBehavior)
        return panel
    }
}
