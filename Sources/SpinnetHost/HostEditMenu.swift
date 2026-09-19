import AppKit

/// The main menu of an app with no visible menu bar. Spinnet runs as an
/// accessory, so this menu is never shown, but its key equivalents are how
/// ⌘X, ⌘C, ⌘V, ⌘A and ⌘Z reach a text field, whether in the Settings window
/// or a sheet. Each item has no target, so it goes to the focused field.
enum HostEditMenu {
    static func make() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        let menu = NSMenu(title: "Main")
        menu.addItem(editItem)
        return menu
    }
}
