import SwiftUI
import SpinnetCore

/// A Library entry's Check for Update and Update controls, shown only for a
/// Plugin that declares an Update Source.
struct PluginUpdateControls: View {
    @ObservedObject var updates: PluginUpdatesModel
    let pluginID: PluginID
    let pluginName: String

    var body: some View {
        if updates.offersUpdates(for: pluginID) {
            HStack(spacing: 8) {
                switch updates.status(for: pluginID) {
                case .checking:
                    ProgressView().controlSize(.small)
                    Text(localized("Checking for update…"))
                case .available:
                    Button(localized("Update to \(updates.availableVersion(for: pluginID) ?? "")")) { updates.update(pluginID) }
                        .controlSize(.small)
                        .accessibilityLabel(localized("Update \(pluginName) to \(updates.availableVersion(for: pluginID) ?? "")"))
                default:
                    Button(localized("Check for Update")) { updates.checkForUpdate(pluginID) }
                        .controlSize(.small)
                        .accessibilityLabel(localized("Check for Update: \(pluginName)"))
                }
                if updates.status(for: pluginID) != .checking, let message = updates.message(for: pluginID) {
                    Text(message)
                        .foregroundStyle(updates.status(for: pluginID) == .failed || updates.status(for: pluginID) == .refused
                                         ? Color.orange : Color.secondary)
                        .lineLimit(2)
                        .help(message)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// The Library's Check All for Updates: the same check of every Plugin as
/// General's Check Now.
struct CheckAllPluginUpdatesButton: View {
    @ObservedObject var updates: PluginUpdatesModel

    var body: some View {
        if updates.canCheckAll {
            HStack(spacing: 8) {
                Button(localized("Check All for Updates"), action: updates.checkNow)
                    .disabled(updates.isCheckingAll)
                if updates.isCheckingAll {
                    ProgressView().controlSize(.small)
                    Text(localized("Checking for updates…")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// General's Plugin Update checks: the daily automatic check, Check Now, how
/// many updates are available and why the last check did not complete. A
/// failure is reported here only, never as an alert.
struct PluginUpdateChecksSection: View {
    @ObservedObject var updates: PluginUpdatesModel
    let showLibrary: () -> Void

    private let detail = localized("Once a day, ask each Plugin's Update Source for a newer version. Nothing installs by itself.")

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(localized("Check for Plugin updates automatically")).font(.body.weight(.medium))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Toggle(localized("Check for Plugin updates automatically"), isOn: $updates.checksAutomatically)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel(localized("Check for Plugin updates automatically"))
                    .accessibilityHint(detail)
            }
            HStack(spacing: 8) {
                Button(localized("Check Now"), action: updates.checkNow)
                    .controlSize(.small)
                    .disabled(updates.isCheckingAll || !updates.canCheckAll)
                if updates.isCheckingAll {
                    ProgressView().controlSize(.small)
                    Text(localized("Checking for updates…"))
                } else {
                    Text(summary)
                    if updates.availableUpdateCount > 0 {
                        Button(localized("Show in Library"), action: showLibrary)
                            .controlSize(.small)
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let failure = updates.runFailure, !updates.isCheckingAll {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(failure)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }

    private var summary: String {
        guard updates.canCheckAll else { return localized("No installed Plugin declares an Update Source.") }
        let available: String
        switch updates.availableUpdateCount {
        case 0: available = updates.lastCheck == nil ? localized("Not checked yet.") : localized("No Plugin updates available.")
        case 1: available = localized("1 Plugin update available.")
        case let count: available = localized("\(count) Plugin updates available.")
        }
        guard let last = updates.shownLastCheck else { return available }
        return localized("\(available) Last checked \(last.formatted(.relative(presentation: .named).locale(HostLocalization.locale))).")
    }
}
