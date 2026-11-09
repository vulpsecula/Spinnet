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
                Image(systemName: shown.drawable.symbolName)
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
                 ? localized("Shows the Plugin's icon.")
                 : localized("Your icon replaces the Plugin's icon wherever this Menu Item appears."))
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
                let symbols = MenuItemIconChoice.symbols(matching: search)
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
}
