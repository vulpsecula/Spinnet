import AppKit
import SpinnetCore

/// Adapts Core resource checks to macOS APIs that are only available in Host.
/// The same resolver drives the runtime menu, invocation guard, and settings
/// sheet so Bundle ID availability cannot drift between those surfaces.
enum HostResourceAvailability {
    static func missingReason(for action: ActionConfiguration) -> ActionUnavailableReason? {
        missingReason(for: action, screenshotSettings: ScreenshotSettings(defaults: .standard))
    }

    /// The capture Host Commands depend on the Screenshots save folder, but
    /// only while the settings save.
    static func missingReason(
        for action: ActionConfiguration,
        screenshotSettings: ScreenshotSettings
    ) -> ActionUnavailableReason? {
        ActionResourceAvailability.missingReason(
            for: action,
            applicationExists: applicationExists
        ) ?? screenshotSettings.unavailableReason(for: action)
    }

    static func resourceExists(
        kind: CommandConfigurationFieldKind,
        value: String
    ) -> Bool {
        ActionResourceAvailability.resourceExists(
            kind: kind,
            value: value,
            applicationExists: applicationExists
        )
    }

    private static func applicationExists(_ bundleIdentifier: String) -> Bool {
        NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) != nil
    }
}
