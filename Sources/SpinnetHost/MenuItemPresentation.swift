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

    var title: String { primaryAction.displayTitle }

    init(
        configuration: MenuItemConfiguration,
        primaryAction: MenuActionPresentation,
        alternateActions: [MenuActionPresentation]
    ) {
        self.configuration = configuration
        self.primaryAction = primaryAction
        self.alternateActions = alternateActions
    }
}

struct MenuSlotPresentation {
    let configuration: MenuSlotConfiguration
    let item: MenuItemPresentation?

    var isEmpty: Bool { item == nil }
    var title: String { item?.title ?? "Empty Slot" }

    static var empty: Self {
        Self(configuration: .empty, item: nil)
    }

    static func occupied(_ item: MenuItemPresentation) -> Self {
        Self(configuration: .occupied(item.configuration), item: item)
    }
}
