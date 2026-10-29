import AppKit

/// The main menu of an app with no visible menu bar. Spinnet runs as an
/// accessory, so this menu is never shown, but its key equivalents are how
/// ⌘X, ⌘C, ⌘V, ⌘A and ⌘Z reach a text field, whether in the Settings window
/// or a sheet. Each item has no target, so it goes to the focused field.
enum HostEditMenu {
    static func make() -> NSMenu {
        let edit = NSMenu(title: localized("Edit"))
        edit.addItem(withTitle: localized("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: localized("Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: localized("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: localized("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: localized("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: localized("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let editItem = NSMenuItem(title: localized("Edit"), action: nil, keyEquivalent: "")
        editItem.submenu = edit
        let menu = NSMenu(title: "Main") // Not localized: the main menu's own title, never shown
        menu.addItem(editItem)
        return menu
    }
}
