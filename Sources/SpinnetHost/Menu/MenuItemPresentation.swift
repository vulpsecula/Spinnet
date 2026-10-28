import Foundation
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
        return "\(title) (Unavailable: \(reason.description))"
    }

    var accessibilityLabel: String {
        guard let reason = availability.reason else { return title }
        return "\(title), unavailable: \(reason.description)"
    }

    /// Why an Action is unavailable comes first, then what it does. The title
    /// is already the menu item's text, so it is repeated only when there is
    /// nothing else to say.
    var toolTip: String {
        guard let explanation else { return accessibilityLabel }
        guard let reason = availability.reason else { return explanation }
        return "Unavailable: \(reason.description)\n\(explanation)"
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

    var title: String { configuration.alias ?? defaultTitle ?? primaryAction.title }

    init(
        configuration: MenuItemConfiguration,
        primaryAction: MenuActionPresentation,
        alternateActions: [MenuActionPresentation],
        defaultTitle: String? = nil
    ) {
        self.configuration = configuration
        self.primaryAction = primaryAction
        self.alternateActions = alternateActions
        self.defaultTitle = defaultTitle
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
        item?.title ?? "Empty Slot"
    }

    static var empty: Self {
        Self(configuration: .empty, item: nil)
    }

    static func occupied(_ item: MenuItemPresentation) -> Self {
        Self(configuration: .occupied(item.configuration), item: item)
    }
}
