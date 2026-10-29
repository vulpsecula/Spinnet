import SpinnetCore

// Host-owned English that SpinnetCore defines, shown in the interface
// language. SpinnetCore has no resources, so its English is the catalog key;
// `LocalizationCompletenessTests` checks every case has a translation.

extension PluginCapability {
    var localizedTitle: String { localized(key: title) }
    var localizedExplanation: String { localized(key: explanation) }
}

extension PluginCapabilityGrantDecision {
    var localizedTitle: String { localized(key: title) }
}

extension PluginSystemPermission {
    var localizedTitle: String { localized(key: title) }
    var localizedExplanation: String { localized(key: explanation) }
}

extension PluginConsentGroup {
    var localizedTitle: String { localized(key: rawValue) }
}

extension MenuItemPresetReadiness {
    var localizedLabel: String { localized(key: label) }
}

extension CommandConfigurationFieldKind {
    var localizedTitle: String { localized(key: title) }
}

extension ScreenshotSettings.AfterCapture {
    var localizedTitle: String { localized(key: title) }
}

extension ScreenshotSettings.FileFormat {
    var localizedTitle: String { localized(key: title) }
    var localizedSummary: String { localized(key: summary) }
}

extension MenuItemPreset {
    var localizedStateLabel: String {
        guard unavailableReason == nil else { return localized("Unavailable") }
        return needsPluginSettings ? localized("Needs Plugin Settings") : readiness.localizedLabel
    }

    var localizedConfigurationLabel: String {
        isConfigurable ? localized("Configurable") : localized("No Configuration")
    }

    /// The Plugin's name and Command titles stay as the Plugin provides them.
    var localizedAccessibilityLabel: String {
        let commandNames = commands.map(\.title).joined(separator: localized(", "))
        let state = [name, localizedStateLabel, localizedConfigurationLabel]
            + (unavailableReason.map { [$0.localizedDescription] } ?? [])
        return localized("\(state.joined(separator: localized(", "))), Commands: \(commandNames)")
    }
}

extension ActionUnavailableReason {
    /// A Refused Plugin's reason is the refusal the Host recorded and stays
    /// as recorded.
    var localizedDescription: String {
        switch self {
        case .pluginMissing: return localized("Plugin is not registered")
        case .pluginDisabled: return localized("Plugin is disabled")
        case .pluginRefused(let reason): return reason
        case .commandMissing: return localized("Command is no longer registered")
        case .commandChanged: return localized("Command definition changed")
        case .resourceMissing: return localized("Referenced resource is missing")
        case .externalAppMissing(let app): return localized("Install \(app) to use \(app) Commands")
        case .externalAppConnectionRequired(let app): return localized("Connect \(app) in Plugin Settings")
        case .externalAppNotRunning(let app): return localized("Start \(app) to use its Commands")
        case .externalAppOperationUnsupported:
            return localized("This External App operation is not supported by Spinnet")
        case .capabilityDenied: return localized("Grant Access in Plugin Settings")
        case .systemPermissionDenied: return localized("Enable Accessibility in Privacy & Permissions")
        case .hostServiceUnavailable: return localized("Required Host Service is not available in this version")
        case .screenRecordingDenied: return localized("Enable Screen Recording in Privacy & Permissions")
        case .pluginSettingsIncomplete: return localized("Complete this Plugin's Plugin Settings in the Library")
        case .saveFolderUnavailable:
            return localized("Screenshot save folder is missing or not writable; choose it again in Screenshot Plugin Settings")
        }
    }
}
