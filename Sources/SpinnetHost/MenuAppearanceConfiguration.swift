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

    static let defaultConfiguration = MenuAppearanceConfiguration()
    static let themeOptions = Theme.allCases.map(\.rawValue)
    static let accentOptions = Accent.allCases.map(\.rawValue)
    static let menuSizeOptions = Size.allCases.map(\.rawValue)

    static let themeDefaultsKey = "appearance.theme"
    static let accentDefaultsKey = "appearance.accent"
    static let menuSizeDefaultsKey = "appearance.menu-size"

    let theme: String
    let accent: String
    let menuSize: String

    init(
        theme: String = Theme.system.rawValue,
        accent: String = Accent.system.rawValue,
        menuSize: String = Size.medium.rawValue
    ) {
        self.theme = Theme(rawValue: theme)?.rawValue ?? Theme.system.rawValue
        self.accent = Accent(rawValue: accent)?.rawValue ?? Accent.system.rawValue
        self.menuSize = Size(rawValue: menuSize)?.rawValue ?? Size.medium.rawValue
    }

    init(defaults: UserDefaults) {
        self.init(
            theme: defaults.string(forKey: Self.themeDefaultsKey) ?? Theme.system.rawValue,
            accent: defaults.string(forKey: Self.accentDefaultsKey) ?? Accent.system.rawValue,
            menuSize: defaults.string(forKey: Self.menuSizeDefaultsKey) ?? Size.medium.rawValue
        )
    }

    func save(to defaults: UserDefaults) {
        defaults.set(theme, forKey: Self.themeDefaultsKey)
        defaults.set(accent, forKey: Self.accentDefaultsKey)
        defaults.set(menuSize, forKey: Self.menuSizeDefaultsKey)
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

    func layout(slotCount: Int) -> RadialMenuLayout {
        RadialMenuLayout(
            itemCount: max(slotCount, 1),
            innerRadius: 38 * scale,
            outerRadius: 142 * scale,
            itemCenterRadius: 90 * scale
        )
    }
}
