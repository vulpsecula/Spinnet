import AppKit
import SpinnetCore

/// Session-stable identity travels with the complete editor Slot presentation.
struct EditorMenuSlot: Identifiable, Equatable {
    let id: UUID
    let presentation: MenuSlotPresentation
}

struct MenuActionPresentation: Equatable {
    let actionID: ActionID
    let title: String
    let availability: ActionAvailability
    /// What the Action's Command does, from its Plugin's `description`.
    var explanation: String? = nil

    var isAvailable: Bool { availability.isAvailable }

    var displayTitle: String {
        guard let reason = availability.reason else { return title }
        return localized("\(title) (Unavailable: \(reason.localizedDescription))")
    }

    var accessibilityLabel: String {
        guard let reason = availability.reason else { return title }
        return localized("\(title), unavailable: \(reason.localizedDescription)")
    }

    /// Why an Action is unavailable comes first, then what it does. The title
    /// is already the menu item's text, so it is repeated only when there is
    /// nothing else to say.
    var toolTip: String {
        guard let explanation else { return accessibilityLabel }
        guard let reason = availability.reason else { return explanation }
        return localized("Unavailable: \(reason.localizedDescription)\n\(explanation)")
    }
}

/// The Menu Item Icon a Menu Item shows. The Host resolves it in one place,
/// `resolve(ownIcon:pluginIcon:primaryAvailability:)`, beside the Menu Item's title.
struct MenuItemIcon: Equatable, Hashable {
    /// A system symbol name.
    let symbolName: String

    /// The neutral Host symbol shown when there is no Plugin Icon to show,
    /// so the ring never has a gap.
    static let neutral = MenuItemIcon(symbolName: "puzzlepiece.extension")

    /// The user's own icon for the Menu Item, else the Plugin's Plugin Icon,
    /// else the neutral symbol. The user's icon is saved with the Menu Item,
    /// so it shows whatever the Plugin's state. A Menu Item whose Plugin is
    /// removed or refused, or whose Command is gone, has no Plugin to take
    /// an icon from and otherwise shows the neutral symbol in its
    /// unavailable treatment; the Host keeps no copy of a Plugin's icon.
    static func resolve(
        ownIcon: String? = nil,
        pluginIcon: IconDeclaration?,
        primaryAvailability: ActionAvailability
    ) -> MenuItemIcon {
        if let ownIcon { return MenuItemIcon(symbolName: ownIcon) }
        switch primaryAvailability.reason {
        case .pluginMissing?, .pluginRefused?, .commandMissing?:
            return .neutral
        default:
            return pluginIcon.map { MenuItemIcon(symbolName: $0.symbolName) } ?? .neutral
        }
    }

    /// The icon the Library shows beside a Menu Item Preset.
    init(preset: MenuItemPreset) {
        self = preset.icon.map { MenuItemIcon(symbolName: $0.symbolName) } ?? .neutral
    }

    init(symbolName: String) {
        self.symbolName = symbolName
    }

    /// This icon, or the neutral symbol when the running macOS lacks it.
    var drawable: MenuItemIcon {
        NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) == nil ? .neutral : self
    }
}

struct MenuItemPresentation: Equatable {
    let configuration: MenuItemConfiguration
    let primaryAction: MenuActionPresentation
    let alternateActions: [MenuActionPresentation]
    /// The Menu Item Preset name used when the item has not supplied an
    /// explicit Alias. This stays separate from an Action's availability
    /// annotation so a missing resource cannot replace the Menu Item title.
    let defaultTitle: String?
    /// The Menu Item Icon drawn with the title. VoiceOver reads the title.
    let icon: MenuItemIcon

    var title: String { configuration.alias ?? defaultTitle ?? primaryAction.title }

    init(
        configuration: MenuItemConfiguration,
        primaryAction: MenuActionPresentation,
        alternateActions: [MenuActionPresentation],
        defaultTitle: String? = nil,
        icon: MenuItemIcon = .neutral
    ) {
        self.configuration = configuration
        self.primaryAction = primaryAction
        self.alternateActions = alternateActions
        self.defaultTitle = defaultTitle
        self.icon = icon
    }
}

/// How a Slot shown in the Menu Editor for an App relates to the default
/// Menu: showing the default's Menu Item, or the App's own override.
enum SlotAppOverrideState: Equatable {
    case inherited
    case overridden
}

struct MenuSlotPresentation: Equatable {
    let configuration: MenuSlotConfiguration
    let item: MenuItemPresentation?
    /// Set only while the Menu Editor edits an App; nil in the default Menu
    /// and in Runtime Mode.
    var appOverride: SlotAppOverrideState? = nil

    /// Shown in the inherited style: the default Menu's Menu Item, seen
    /// from an App that does not override the Slot.
    var isInherited: Bool { appOverride == .inherited }

    var isEmpty: Bool { item == nil }
    /// Uses the Menu Item's Alias when present; otherwise it uses its Preset
    /// name and falls back to the Primary Action title or the empty-state
    /// label.
    var title: String {
        item?.title ?? localized("Empty Slot")
    }

    static var empty: Self {
        Self(configuration: .empty, item: nil)
    }

    static func occupied(_ item: MenuItemPresentation) -> Self {
        Self(configuration: .occupied(item.configuration), item: item)
    }
}
