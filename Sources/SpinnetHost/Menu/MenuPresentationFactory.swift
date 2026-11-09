import Foundation
import SpinnetCore

enum MenuPresentationFactory {
    /// The Slots presented while `app` is the Current App, nil for the
    /// default Menu; the saved configuration resolves its App Overrides.
    static func makeSlots(
        configuration: HostConfiguration,
        app: AppBundleIdentifier? = nil,
        availability: (ActionConfiguration) -> ActionAvailability,
        presetName: (PluginID) -> String? = { _ in nil },
        pluginIcon: (PluginID) -> IconDeclaration? = { _ in nil },
        packageRoot: (PluginID) -> URL? = { _ in nil },
        explanation: (ActionConfiguration) -> String? = { _ in nil },
        commandIcon: (ActionConfiguration) -> IconDeclaration? = { _ in nil }
    ) -> [MenuSlotPresentation] {
        let actions = Dictionary(uniqueKeysWithValues: configuration.actions.map { ($0.id, $0) })
        /// The icon shown for `actionID`'s Action: `ownIcon` for a Menu Item,
        /// else its Command's.
        func icon(for actionID: ActionID, ownIcon: String? = nil, availability: ActionAvailability) -> MenuItemIcon {
            let action = actions[actionID]
            return MenuItemIcon.resolve(
                ownIcon: ownIcon,
                commandIcon: action.flatMap(commandIcon),
                pluginIcon: action.flatMap { pluginIcon($0.pluginID) },
                packageRoot: action.flatMap { packageRoot($0.pluginID) },
                primaryAvailability: availability
            )
        }
        func presentation(for actionID: ActionID) -> MenuActionPresentation {
            var presentation = Self.presentation(
                for: actionID, actions: actions, availability: availability, explanation: explanation
            )
            presentation.icon = icon(for: actionID, availability: presentation.availability)
            return presentation
        }
        return configuration.menu.slots(for: app).map { slot in
            guard let item = slot.item else {
                return MenuSlotPresentation(configuration: slot, item: nil)
            }
            let primary = presentation(for: item.primaryActionID)
            let alternates = item.alternateActionIDs.map(presentation(for:))
            let defaultTitle = actions[item.primaryActionID].flatMap {
                presetName($0.pluginID)
            }
            let icon = icon(for: item.primaryActionID, ownIcon: item.icon, availability: primary.availability)
            return MenuSlotPresentation(
                configuration: slot,
                item: MenuItemPresentation(
                    configuration: item,
                    primaryAction: primary,
                    alternateActions: alternates,
                    defaultTitle: defaultTitle,
                    icon: icon
                )
            )
        }
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
                title: localized("Unavailable Action"),
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
