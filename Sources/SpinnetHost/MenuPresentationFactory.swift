import SpinnetCore

enum MenuPresentationFactory {
    static func makeItems(
        configuration: HostConfiguration,
        availability: (ActionConfiguration) -> ActionAvailability
    ) -> [MenuItemPresentation] {
        let actions = Dictionary(uniqueKeysWithValues: configuration.actions.map { ($0.id, $0) })
        return configuration.menu.items.map { item in
            let primary = presentation(
                for: item.primaryActionID,
                actions: actions,
                availability: availability
            )
            let alternates = item.alternateActionIDs.map { actionID in
                presentation(for: actionID, actions: actions, availability: availability)
            }
            return MenuItemPresentation(
                configuration: item,
                primaryAction: primary,
                alternateActions: alternates
            )
        }
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
