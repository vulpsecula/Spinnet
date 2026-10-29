import Foundation
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

/// A failure the Host shows itself: a Plugin Update check's or a Spinnet
/// release check's from the catalog, with a reset time written as the
/// interface language writes times; any other as it describes itself.
func localizedFailure(_ error: Error) -> String {
    switch error {
    case let failure as PluginUpdateError: return localized(failure.text(resetTime: localizedResetTime))
    case let failure as SpinnetReleaseCheckError: return localized(failure.text(resetTime: localizedResetTime))
    default: return error.localizedDescription
    }
}

private func localizedResetTime(_ reset: Date) -> String {
    reset.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(HostLocalization.locale))
}

extension PluginUpdateRefusal {
    var localizedReason: String { localized(reasonText) }
}

extension HostConfirmation {
    var localizedTitle: String { localized(titleText) }
    var localizedMessage: String { localized(sentences: messageText) }
    var localizedConfirmTitle: String { localized(confirmTitleText) }
}

extension HostConfirmationDetails {
    var localizedTitle: String { localized(titleText) }
    var localizedSummary: String { localized(sentences: summaryText) }
}

extension HostConfirmationDetails.Row {
    var localizedTitle: String { localized(titleText) }
    var localizedDetail: String { detailText.map { localized($0) }.joined(separator: "\n") }
}

extension HostActivity {
    /// The Plugin's name and a Task's package stay as they are.
    var localizedName: String {
        let plugin = String(pluginName.prefix(128))
        switch kind {
        case "inspection": return localized("\(plugin) — Native Inspection")
        case "task":
            // A Task is named by its operation, then its package.
            guard case .string(let task)? = detail?.value(atPointer: "/name") else { return name }
            var package = ""
            if case .string(let name)? = detail?.value(atPointer: "/package/name") { package = name }
            let operation = String(task.dropLast(package.count)).trimmingCharacters(in: .whitespaces)
            let shown = package.isEmpty ? localized(key: operation) : "\(localized(key: operation)) \(package)"
            return "\(plugin) — \(shown.prefix(128))"
        case "keep_awake": return localized("\(pluginName) — Keep Awake")
        default: return localized("\(pluginName) — Activity")
        }
    }

    /// A Task's stage and outcome stay as the Host's Task runner reports them.
    var localizedStatus: String {
        if let remainingSeconds { return Self.localizedRemaining(remainingSeconds) }
        if kind == "task", case .string(let state)? = detail?.value(atPointer: "/status") {
            var stage = ""
            if case .string(let value)? = detail?.value(atPointer: "/stage") { stage = value }
            switch state {
            case "ended":
                var outcome = ""
                if case .string(let value)? = detail?.value(atPointer: "/result/outcome") { outcome = value }
                return localized("Ended: \(outcome)")
            case "running", "stopping":
                let progress = state == "running" ? localized("Running: \(stage)") : localized("Stopping: \(stage)")
                let sleep = detail?.value(atPointer: "/prevents_idle_sleep") == .bool(true)
                    ? localized(" — prevents idle system sleep") : localized(" — idle sleep prevention unavailable")
                return progress + sleep
            default: break
            }
        }
        if kind == "keep_awake", let app = status.between("While ", and: " is running") { // Not localized: SpinnetCore's English
            return localized("While \(app) is running")
        }
        if kind == "keep_awake", let seconds = status.between("For ", and: " seconds").flatMap({ Int($0) }) { // Not localized: SpinnetCore's English
            return localized("For \(seconds) seconds")
        }
        // Fixed statuses are catalog keys; anything else stays as it is.
        return localized(key: status)
    }

    static func localizedRemaining(_ seconds: Int) -> String {
        let secondsPart = String(format: "%02d", seconds % 60)
        if seconds >= 3_600 {
            let minutesPart = String(format: "%02d", (seconds / 60) % 60)
            return localized("\(seconds / 3_600)h \(minutesPart)m \(secondsPart)s remaining")
        }
        if seconds >= 60 { return localized("\(seconds / 60)m \(secondsPart)s remaining") }
        return localized("\(seconds)s remaining")
    }
}

private extension String {
    func between(_ prefix: String, and suffix: String) -> String? {
        guard hasPrefix(prefix), hasSuffix(suffix), count >= prefix.count + suffix.count else { return nil }
        return String(dropFirst(prefix.count).dropLast(suffix.count))
    }
}

extension ReviewedServicesSurface {
    /// Its status line; a read failure stays as it is.
    var localizedMessage: String {
        if !rows.isEmpty, message.hasSuffix(" services · Changes require Host Confirmation") { // Not localized: SpinnetCore's English
            return localized("\(rows.count) services · Changes require Host Confirmation")
        }
        return localized(key: message)
    }
}
