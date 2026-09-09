import AppKit
import SpinnetCore

struct MenuAppearanceConfiguration: Equatable {
    enum Theme: String, CaseIterable, Hashable {
        case system = "System"
        case light = "Light"
        case dark = "Dark"
    }

    enum Accent: String, CaseIterable, Hashable {
        case system = "System"
        case blue = "Blue"
        case purple = "Purple"
        case pink = "Pink"
        case orange = "Orange"
        case green = "Green"
    }

    enum Size: String, CaseIterable, Hashable {
        case small = "Small"
        case medium = "Medium"
        case large = "Large"

        var scale: CGFloat {
            switch self {
            case .small: return 0.86
            case .medium: return 1
            case .large: return 1.08
            }
        }
    }

    struct MenuFont: RawRepresentable, Equatable, Hashable {
        let rawValue: String

        init(rawValue: String) {
            self.rawValue = rawValue
        }

        static let system = MenuFont(rawValue: "System")

        func makeFont(
            ofSize size: CGFloat,
            weight: MenuFontWeight = .semibold
        ) -> NSFont {
            let systemFont = NSFont.systemFont(ofSize: size, weight: weight.nsWeight)

            if rawValue == Self.system.rawValue {
                return systemFont
            }

            return NSFontManager.shared.font(
                withFamily: rawValue,
                traits: [],
                weight: weight.fontManagerWeight,
                size: size
            ) ?? systemFont
        }
    }

    enum MenuFontWeight: String, CaseIterable, Hashable {
        case regular = "Regular"
        case medium = "Medium"
        case semibold = "Semibold"
        case bold = "Bold"

        var nsWeight: NSFont.Weight {
            switch self {
            case .regular: return .regular
            case .medium: return .medium
            case .semibold: return .semibold
            case .bold: return .bold
            }
        }

        var fontManagerWeight: Int {
            switch self {
            case .regular: return 4
            case .medium: return 6
            case .semibold: return 8
            case .bold: return 9
            }
        }
    }

    static let defaultConfiguration = MenuAppearanceConfiguration()
    static let themeOptions = Theme.allCases.map(\.rawValue)
    static let accentOptions = Accent.allCases.map(\.rawValue)
    static let menuSizeOptions = Size.allCases.map(\.rawValue)
    static let fontOptions: [String] = {
        let families = NSFontManager.shared.availableFontFamilies
            .filter { $0 != MenuFont.system.rawValue }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return [MenuFont.system.rawValue] + families
    }()
    static let fontWeightOptions = MenuFontWeight.allCases.map(\.rawValue)

    static let themeDefaultsKey = "appearance.theme"
    static let accentDefaultsKey = "appearance.accent"
    static let menuSizeDefaultsKey = "appearance.menu-size"
    static let fontDefaultsKey = "appearance.font"
    static let fontWeightDefaultsKey = "appearance.font-weight"

    let theme: String
    let accent: String
    let menuSize: String
    let font: String
    let fontWeight: String

    init(
        theme: String = Theme.system.rawValue,
        accent: String = Accent.system.rawValue,
        menuSize: String = Size.medium.rawValue,
        font: String = MenuFont.system.rawValue,
        fontWeight: String = MenuFontWeight.semibold.rawValue
    ) {
        self.theme = Theme(rawValue: theme)?.rawValue ?? Theme.system.rawValue
        self.accent = Accent(rawValue: accent)?.rawValue ?? Accent.system.rawValue
        self.menuSize = Size(rawValue: menuSize)?.rawValue ?? Size.medium.rawValue
        self.font = Self.normalizedFontFamily(font)
        self.fontWeight = MenuFontWeight(rawValue: fontWeight)?.rawValue ?? MenuFontWeight.semibold.rawValue
    }

    private static func normalizedFontFamily(_ font: String) -> String {
        let legacyFontMapping = [
            "Rounded": "Avenir Next",
            "Serif": "Georgia",
            "Monospaced": "SF Mono"
        ]
        let candidate = legacyFontMapping[font] ?? font
        return fontOptions.contains(candidate) ? candidate : MenuFont.system.rawValue
    }

    init(defaults: UserDefaults) {
        self.init(
            theme: defaults.string(forKey: Self.themeDefaultsKey) ?? Theme.system.rawValue,
            accent: defaults.string(forKey: Self.accentDefaultsKey) ?? Accent.system.rawValue,
            menuSize: defaults.string(forKey: Self.menuSizeDefaultsKey) ?? Size.medium.rawValue,
            font: defaults.string(forKey: Self.fontDefaultsKey) ?? MenuFont.system.rawValue,
            fontWeight: defaults.string(forKey: Self.fontWeightDefaultsKey) ?? MenuFontWeight.semibold.rawValue
        )
    }

    func save(to defaults: UserDefaults) {
        defaults.set(theme, forKey: Self.themeDefaultsKey)
        defaults.set(accent, forKey: Self.accentDefaultsKey)
        defaults.set(menuSize, forKey: Self.menuSizeDefaultsKey)
        defaults.set(font, forKey: Self.fontDefaultsKey)
        defaults.set(fontWeight, forKey: Self.fontWeightDefaultsKey)
    }

    var appearance: NSAppearance? {
        switch Theme(rawValue: theme) ?? .system {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    var accentColor: NSColor {
        switch Accent(rawValue: accent) ?? .system {
        case .system: return .controlAccentColor
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .pink: return .systemPink
        case .orange: return .systemOrange
        case .green: return .systemGreen
        }
    }

    var scale: CGFloat {
        (Size(rawValue: menuSize) ?? .medium).scale
    }

    var menuFont: MenuFont {
        MenuFont(rawValue: font)
    }

    var menuFontWeight: MenuFontWeight {
        MenuFontWeight(rawValue: fontWeight) ?? .semibold
    }

    func titleFont(
        ofSize size: CGFloat,
        weight: MenuFontWeight? = nil
    ) -> NSFont {
        menuFont.makeFont(ofSize: size, weight: weight ?? menuFontWeight)
    }

    func layout(slotCount: Int) -> RadialMenuLayout {
        RadialMenuLayout(
            itemCount: max(slotCount, 1),
            innerRadius: 38 * scale,
            outerRadius: 142 * scale,
            itemCenterRadius: 90 * scale
        )
    }
}
