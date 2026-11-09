import AppKit
import SwiftUI

/// The Configuration Sheet's choice of the user's own Menu Item Icon: a
/// system symbol picker, and a reset to the Plugin's default.
struct MenuItemIconPicker: View {
    @Binding var icon: String?
    let defaultIcon: MenuItemIcon

    @State private var isPicking = false
    @State private var search = ""

    private var shown: MenuItemIcon {
        icon.map(MenuItemIcon.init(symbolName:)) ?? defaultIcon
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(localized("Menu Item Icon"))
                .font(.headline)
            HStack(spacing: 10) {
                MenuItemIconImage(icon: shown, side: 20)
                    .font(.system(size: 18))
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
                    .accessibilityHidden(true)
                Button(localized("Choose Icon…")) { isPicking = true }
                    .popover(isPresented: $isPicking, arrowEdge: .bottom) { picker }
                Button(localized("Use Default")) { icon = nil }
                    .disabled(icon == nil)
            }
            Text(icon == nil
                 ? localized("Shows the Primary Action's Command Icon, else the Plugin Icon.")
                 : localized("Your icon replaces the Command Icon and Plugin Icon wherever this Menu Item appears."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localized("Menu Item Icon"))
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(localized("Search or type a symbol name"), text: $search)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                let symbols = Self.symbols(matching: search)
                if symbols.isEmpty {
                    Text(localized("No matching symbols"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 6), count: 8), spacing: 6) {
                    ForEach(symbols, id: \.self) { symbol in
                        Button {
                            icon = symbol
                            isPicking = false
                        } label: {
                            Image(systemName: symbol)
                                .font(.system(size: 16))
                                .frame(width: 34, height: 34)
                                .background(RoundedRectangle(cornerRadius: 6)
                                    .fill(symbol == icon ? Color.accentColor.opacity(0.25) : Color.clear))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(symbol)
                        .accessibilityLabel(symbol)
                    }
                }
            }
            .frame(height: 220)
        }
        .padding(12)
        .frame(width: 8 * 42 + 24)
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
