import AppKit
import SpinnetCore

struct MenuAppearanceConfiguration: Equatable {
    let theme: String
    let accent: String
    let menuSize: String

    init(
        theme: String = "System",
        accent: String = "System",
        menuSize: String = "Medium"
    ) {
        self.theme = theme
        self.accent = accent
        self.menuSize = menuSize
    }

    init(defaults: UserDefaults) {
        self.init(
            theme: defaults.string(forKey: "appearance.theme") ?? "System",
            accent: defaults.string(forKey: "appearance.accent") ?? "System",
            menuSize: defaults.string(forKey: "appearance.menu-size") ?? "Medium"
        )
    }

    var appearance: NSAppearance? {
        switch theme {
        case "Light": return NSAppearance(named: .aqua)
        case "Dark": return NSAppearance(named: .darkAqua)
        default: return nil
        }
    }

    var accentColor: NSColor {
        switch accent {
        case "Blue": return .systemBlue
        case "Purple": return .systemPurple
        case "Pink": return .systemPink
        case "Orange": return .systemOrange
        case "Green": return .systemGreen
        default: return .controlAccentColor
        }
    }

    var scale: CGFloat {
        switch menuSize {
        case "Small": return 0.86
        case "Large": return 1.08
        default: return 1
        }
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
