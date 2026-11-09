import AppKit
import SpinnetCore

/// What a Configuration Sheet offers for the user's own Menu Item Icon: the
/// icon chosen so far, and the default the Menu Item shows without it.
struct MenuItemIconChoice: Equatable {
    /// The user's own icon, a system symbol name, or nil for the default.
    let ownIcon: String?
    /// What the Menu Item shows when the user has chosen no icon.
    let defaultIcon: MenuItemIcon

    /// The Menu Item `app` sees at `slotIndex`, nil for the default Menu.
    init(editor: HostConfigurationEditor, app: AppBundleIdentifier? = nil, slotIndex: Int) {
        let slots = editor.configuration.menu.slots(for: app)
        let item = slots.indices.contains(slotIndex) ? slots[slotIndex].item : nil
        let primary = item.flatMap { item in editor.configuration.actions.first { $0.id == item.primaryActionID } }
        ownIcon = item?.icon
        defaultIcon = MenuItemIcon.resolve(
            pluginIcon: primary.flatMap { action in editor.pluginManifests.first { $0.id == action.pluginID }?.icon },
            primaryAvailability: primary.flatMap { editor.availability(for: $0.id) } ?? .unavailable(.commandMissing)
        )
    }

    /// The symbols the picker offers for `query`: those whose name contains
    /// it, after the query itself when it names a symbol this macOS draws.
    static func symbols(matching query: String) -> [String] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let offered = catalog.filter { query.isEmpty || $0.contains(query) }
        guard !query.isEmpty, !offered.contains(query), isDrawable(query) else { return offered }
        return [query] + offered
    }

    static func isDrawable(_ name: String) -> Bool {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }

    /// Common system symbols, by the kinds of thing a Menu Item does.
    private static let catalog: [String] = [
        "star", "star.fill", "heart", "heart.fill", "bolt", "bolt.fill", "flag", "bookmark", "tag", "bell",
        "app", "square.grid.2x2", "macwindow", "rectangle.split.2x1", "arrow.up.left.and.arrow.down.right",
        "arrow.down.right.and.arrow.up.left", "rectangle.lefthalf.filled", "rectangle.righthalf.filled",
        "music.note", "play", "pause", "playpause", "forward", "backward", "speaker.wave.2", "speaker.slash",
        "mic", "camera", "camera.viewfinder", "photo", "film", "headphones",
        "text.cursor", "textformat", "character.bubble", "globe", "translate", "doc.text", "note.text",
        "pencil", "highlighter", "quote.bubble", "list.bullet", "checklist",
        "doc.on.clipboard", "clipboard", "doc.on.doc", "scissors", "paperclip",
        "folder", "doc", "archivebox", "tray", "trash", "externaldrive", "square.and.arrow.up",
        "safari", "link", "magnifyingglass", "network", "envelope", "paperplane", "message", "phone",
        "terminal", "chevron.left.forwardslash.chevron.right", "hammer", "wrench.and.screwdriver", "ladybug",
        "shippingbox", "cpu", "memorychip", "gearshape", "slider.horizontal.3", "power", "lock", "key",
        "moon", "sun.max", "cup.and.saucer", "display", "keyboard", "computermouse", "battery.100",
        "wifi", "clock", "timer", "calendar", "alarm", "house", "person", "person.2", "map", "location",
        "cart", "creditcard", "chart.bar", "function", "sparkles", "wand.and.stars", "lightbulb", "leaf",
    ].filter(isDrawable)
}
