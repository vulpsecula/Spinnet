import SpinnetCore

enum MenuPresentationFactory {
    static func makeSlots(
        configuration: HostConfiguration,
        availability: (ActionConfiguration) -> ActionAvailability,
        presetName: (PluginID) -> String? = { _ in nil },
        explanation: (ActionConfiguration) -> String? = { _ in nil }
    ) -> [MenuSlotPresentation] {
        let actions = Dictionary(uniqueKeysWithValues: configuration.actions.map { ($0.id, $0) })
        return configuration.menu.slots.map { slot in
            guard let item = slot.item else {
                return MenuSlotPresentation(configuration: slot, item: nil)
            }
            let primary = presentation(
                for: item.primaryActionID,
                actions: actions,
                availability: availability,
                explanation: explanation
            )
            let alternates = item.alternateActionIDs.map { actionID in
                presentation(for: actionID, actions: actions, availability: availability, explanation: explanation)
            }
            let defaultTitle = actions[item.primaryActionID].flatMap {
                presetName($0.pluginID)
            }
            return MenuSlotPresentation(
                configuration: slot,
                item: MenuItemPresentation(
                    configuration: item,
                    primaryAction: primary,
                    alternateActions: alternates,
                    defaultTitle: defaultTitle
                )
            )
        }
    }

    static func makeItems(
        configuration: HostConfiguration,
        availability: (ActionConfiguration) -> ActionAvailability,
        presetName: (PluginID) -> String? = { _ in nil },
        explanation: (ActionConfiguration) -> String? = { _ in nil }
    ) -> [MenuItemPresentation] {
        makeSlots(
            configuration: configuration,
            availability: availability,
            presetName: presetName,
            explanation: explanation
        ).compactMap(\.item)
    }

    private static func presentation(
        for actionID: ActionID,
        actions: [ActionID: ActionConfiguration],
        availability: (ActionConfiguration) -> ActionAvailability,
        explanation: (ActionConfiguration) -> String?
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
            availability: availability(action),
            explanation: explanation(action)
        )
    }
}
