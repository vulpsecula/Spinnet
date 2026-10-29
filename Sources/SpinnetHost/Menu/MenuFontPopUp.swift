import AppKit
import SwiftUI

/// The Menu Font picker: every installed family, each previewed in its own
/// typeface. A SwiftUI menu Picker builds all of those items, and a font for
/// each, whenever the Appearance page appears, which made switching to the
/// page slow. This popup holds only the selected family until it opens.
struct MenuFontPopUp: NSViewRepresentable {
    @Binding var selection: String
    let options: [String]

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.menu?.delegate = context.coordinator
        button.target = context.coordinator
        button.action = #selector(Coordinator.choose(_:))
        button.setAccessibilityLabel(localized("Menu Font"))
        context.coordinator.button = button
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        context.coordinator.showSelection()
    }

    final class Coordinator: NSObject, NSMenuDelegate {
        var parent: MenuFontPopUp
        weak var button: NSPopUpButton?
        private var populated = false

        init(_ parent: MenuFontPopUp) { self.parent = parent }

        func showSelection() {
            guard let button else { return }
            if populated, button.itemTitles.contains(parent.selection) {
                button.selectItem(withTitle: parent.selection)
                return
            }
            populated = false
            button.removeAllItems()
            button.menu?.addItem(Self.item(for: parent.selection))
            button.selectItem(at: 0)
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard !populated else { return }
            populated = true
            menu.removeAllItems()
            for family in parent.options { menu.addItem(Self.item(for: family)) }
            button?.selectItem(withTitle: parent.selection)
        }

        @objc func choose(_ sender: NSPopUpButton) {
            guard let family = sender.titleOfSelectedItem, family != parent.selection else { return }
            parent.selection = family
        }

        private static var previews: [String: NSAttributedString] = [:]

        private static func item(for family: String) -> NSMenuItem {
            let item = NSMenuItem(title: family, action: nil, keyEquivalent: "")
            item.attributedTitle = preview(family)
            return item
        }

        /// Each family's preview title, kept for the life of the process so
        /// reopening the page or the popup does not create its font again.
        private static func preview(_ family: String) -> NSAttributedString {
            // The saved System value stays the item's title; only its shown
            // name is in the interface language.
            let isSystem = family == MenuAppearanceConfiguration.MenuFont.system.rawValue
            let name = isSystem ? localized(key: family) : family
            if let cached = previews[name] { return cached }
            let font = isSystem
                ? NSFont.systemFont(ofSize: 13)
                : NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 13)
                    ?? NSFont.systemFont(ofSize: 13)
            let title = NSAttributedString(string: name, attributes: [.font: font])
            previews[name] = title
            return title
        }
    }
}
