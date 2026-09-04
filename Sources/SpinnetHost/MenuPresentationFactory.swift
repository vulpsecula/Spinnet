import SpinnetCore

enum MenuPresentationFactory {
    static func makeSlots(
        configuration: HostConfiguration,
        availability: (ActionConfiguration) -> ActionAvailability
    ) -> [MenuSlotPresentation] {
        let actions = Dictionary(uniqueKeysWithValues: configuration.actions.map { ($0.id, $0) })
        return configuration.menu.slots.map { slot in
            guard let item = slot.item else { return .empty }
            let primary = presentation(
                for: item.primaryActionID,
                actions: actions,
                availability: availability
            )
            let alternates = item.alternateActionIDs.map { actionID in
                presentation(for: actionID, actions: actions, availability: availability)
            }
            return .occupied(MenuItemPresentation(
                configuration: item,
                primaryAction: primary,
                alternateActions: alternates
            ))
        }
    }

    static func makeItems(
        configuration: HostConfiguration,
        availability: (ActionConfiguration) -> ActionAvailability
    ) -> [MenuItemPresentation] {
        makeSlots(configuration: configuration, availability: availability).compactMap(\.item)
    }

    private static func presentation(
        for actionID: ActionID,
        actions: [ActionID: ActionConfiguration],
        availability: (ActionConfiguration) -> ActionAvailability
    ) -> MenuActionPresentation {
        guard let action = actions[actionID] else {
            return MenuActionPresentation(
                actionID: actionID,
                title: "Unavailable Action",
                availability: .unavailable(.commandMissing)
            )
        }
        return MenuActionPresentation(
            actionID: action.id,
            title: action.title,
            availability: availability(action)
        )
    }
}
