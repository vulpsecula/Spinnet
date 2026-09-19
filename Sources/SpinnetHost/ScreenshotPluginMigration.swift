import Foundation
import SpinnetCore

/// Screenshots were a Bundled Plugin, `com.spinnet.screenshot`, before they
/// became Host Commands. Its Actions move onto the Host Commands with their
/// IDs unchanged, so every Menu Slot, alias and Alternate Action stays as the user
/// arranged it. The Screenshot Plugin Settings apply to all of its captures now, so the
/// first Menu Item's after-capture values seed them once.
enum ScreenshotPluginMigration {
    static let retiredPluginID = PluginID("com.spinnet.screenshot")
    static let retiredPluginVersion = "1.0.0"

    private static let replacements: [CommandID: CommandDeclaration] = {
        let retired: [String: HostCommand] = [
            "screenshot.capture_area": .captureArea,
            "screenshot.capture_full_screen": .captureFullScreen,
            "screenshot.capture_window": .captureWindow
        ]
        return Dictionary(uniqueKeysWithValues: retired.compactMap { id, hostCommand in
            BuiltInPresetCatalog.screenshotCommands.first { $0.hostCommand == hostCommand }.map { (CommandID(id), $0) }
        })
    }()

    /// The configuration with the retired Plugin's Actions replaced, or nil
    /// when it has none. A Command the Plugin never shipped is left for the
    /// registry to report as missing.
    static func migrate(_ configuration: HostConfiguration) throws -> HostConfiguration? {
        var changed = false
        let actions = try configuration.actions.map { action -> ActionConfiguration in
            guard action.pluginID == retiredPluginID, let command = replacements[action.commandID] else { return action }
            changed = true
            return try ActionConfiguration(
                id: action.id, pluginID: BuiltInPresetCatalog.screenshotPluginID, command: command, input: .null
            )
        }
        return changed ? try HostConfiguration(actions: actions, menu: configuration.menu) : nil
    }

    /// The after-capture values of the first Menu Item's Primary Action built
    /// from the retired Plugin, as Screenshot Plugin Settings, or nil when there is
    /// none or its values no longer read.
    static func settings(from configuration: HostConfiguration) -> ScreenshotSettings? {
        let actions = Dictionary(uniqueKeysWithValues: configuration.actions.map { ($0.id, $0) })
        guard let primary = configuration.menu.items.lazy.compactMap({ actions[$0.primaryActionID] })
                .first(where: { $0.pluginID == retiredPluginID }),
              case .object(let values) = primary.input,
              case .string(let after) = values["after_capture"],
              let afterCapture = ScreenshotSettings.AfterCapture.allCases.first(where: { $0.title == after }),
              case .string(let format) = values["format"], ["PNG", "JPEG"].contains(format),
              case .string(let folder) = values["folder"] else { return nil }
        return ScreenshotSettings(afterCapture: afterCapture, format: format == "JPEG" ? .jpeg : .png, saveFolder: folder)
    }

    /// Stores `settings(from:)` unless the user already has Screenshot
    /// Plugin Settings. Run before `migrate`, which drops the values.
    static func seedSettings(from configuration: HostConfiguration, in defaults: UserDefaults) {
        guard defaults.object(forKey: ScreenshotSettings.defaultsKey) == nil,
              let seeded = settings(from: configuration) else { return }
        seeded.save(to: defaults)
    }

    /// Carries a screen capture grant the user gave the retired Plugin over
    /// to the Host Commands, unless the user already decided for those. Run
    /// before decisions for Plugins that are gone are discarded.
    static func carryGrant(in grants: PluginCapabilityGrantStore) {
        let target = BuiltInPresetCatalog.screenshotPluginID
        let version = BuiltInPresetCatalog.screenshotPluginVersion
        guard grants.decision(for: retiredPluginID, pluginVersion: retiredPluginVersion, capability: .captureScreen) == .granted,
              grants.decision(for: target, pluginVersion: version, capability: .captureScreen) == .notDetermined else { return }
        grants.setDecision(.granted, for: target, pluginVersion: version, capability: .captureScreen)
    }
}
