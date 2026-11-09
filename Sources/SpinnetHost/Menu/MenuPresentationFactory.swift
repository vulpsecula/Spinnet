import Foundation
import SpinnetCore

enum MenuPresentationFactory {
    /// The Slots presented while `app` is the Current App, nil for the
    /// default Menu; the saved configuration resolves its App Overrides.
    /// `plugins` names, describes, pictures and checks each Action.
    static func makeSlots(
        configuration: HostConfiguration,
        app: AppBundleIdentifier? = nil,
        plugins: InstalledPlugins
    ) -> [MenuSlotPresentation] {
        let actions = Dictionary(uniqueKeysWithValues: configuration.actions.map { ($0.id, $0) })
        func presentation(for actionID: ActionID) -> MenuActionPresentation {
            guard let action = actions[actionID] else {
                return MenuActionPresentation(
                    actionID: actionID,
                    title: localized("Unavailable Action"),
                    availability: .unavailable(.commandMissing)
                )
            }
            let availability = plugins.availability(of: action)
            return MenuActionPresentation(
                actionID: action.id,
                title: action.title,
                availability: availability,
                explanation: plugins.command(for: action)?.explanation,
                icon: MenuItemIcon.resolve(of: action, in: plugins, availability: availability)
            )
        }
        return configuration.menu.slots(for: app).map { slot in
            guard let item = slot.item else {
                return MenuSlotPresentation(configuration: slot, item: nil)
            }
            let primary = presentation(for: item.primaryActionID)
            let alternates = item.alternateActionIDs.map(presentation(for:))
            let primaryAction = actions[item.primaryActionID]
            return MenuSlotPresentation(
                configuration: slot,
                item: MenuItemPresentation(
                    configuration: item,
                    primaryAction: primary,
                    alternateActions: alternates,
                    defaultTitle: primaryAction.flatMap { plugins.presetName($0.pluginID) },
                    icon: MenuItemIcon.resolve(
                        ownIcon: item.icon, of: primaryAction, in: plugins, availability: primary.availability
                    )
                )
            )
        }
    }
}
