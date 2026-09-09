import SpinnetCore

struct MenuActionPresentation {
    let actionID: ActionID
    let title: String
    let availability: ActionAvailability

    var isAvailable: Bool { availability.isAvailable }

    var displayTitle: String {
        guard let reason = availability.reason else { return title }
        return "\(title) (Unavailable: \(reason.description))"
    }

    var accessibilityLabel: String {
        guard let reason = availability.reason else { return title }
        return "\(title), unavailable: \(reason.description)"
    }
}

struct MenuItemPresentation {
    let configuration: MenuItemConfiguration
    let primaryAction: MenuActionPresentation
    let alternateActions: [MenuActionPresentation]
    /// The Menu Item Preset name used when the user has not supplied an
    /// explicit Alias. This stays separate from an Action's availability
    /// annotation so a missing resource cannot replace the Slot title.
    let defaultTitle: String?

    var title: String { defaultTitle ?? primaryAction.title }

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

struct MenuSlotPresentation {
    let configuration: MenuSlotConfiguration
    let item: MenuItemPresentation?

    var isEmpty: Bool { item == nil }
    /// Uses the user's Menu Item Alias when present; otherwise the Slot uses
    /// its Preset name and falls back to the Primary Action title or the
    /// empty-state label.
    var title: String {
        configuration.alias ?? item?.title ?? "Empty Slot"
    }

    static var empty: Self {
        Self(configuration: .empty, item: nil)
    }

    static func occupied(_ item: MenuItemPresentation) -> Self {
        Self(configuration: .occupied(item.configuration), item: item)
    }
}
