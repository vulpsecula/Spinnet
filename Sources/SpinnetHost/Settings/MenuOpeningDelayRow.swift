import SwiftUI

/// General's Menu opening delay. Zero opens the Menu on the trigger press;
/// above zero a shorter press goes to the Current App as if Spinnet had not
/// seen it.
struct MenuOpeningDelayRow: View {
    @ObservedObject var trigger: MenuTriggerModel
    @ObservedObject var privacy: PrivacyPermissionsModel

    static var title: String { localized("Menu Opening Delay") }
    static let step: TimeInterval = 0.05
    private static var detail: String { localized("Hold the trigger this long to open the Menu. A shorter press goes to the App, so Side Button 1 still goes Back.") }

    static func valueText(for delay: TimeInterval) -> String {
        delay <= 0 ? localized("Opens at once") : localized("\(Int((delay * 1000).rounded())) ms")
    }

    static func accessibleName(for delay: TimeInterval) -> String {
        "\(title): \(valueText(for: delay))"
    }

    /// With a delay the keyboard shortcut is read from the event tap, which
    /// needs Accessibility; without it the shortcut stays a hot key that
    /// opens at once.
    static func shortcutNote(trigger: MenuTriggerModel, accessibilityGranted: Bool) -> String? {
        guard trigger.openingDelay > 0, trigger.keyboardShortcut != nil, !accessibilityGranted else { return nil }
        return localized("Without Accessibility, the keyboard shortcut still opens the Menu at once.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(Self.title).font(.body.weight(.medium))
                Spacer(minLength: 12)
                Text(Self.valueText(for: trigger.openingDelay))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Slider(
                value: $trigger.openingDelay,
                in: MenuTriggerConfiguration.openingDelayRange,
                step: Self.step
            )
            .accessibilityLabel(Self.title)
            .accessibilityValue(Self.valueText(for: trigger.openingDelay))
            .accessibilityHint(Self.detail)
            Text(Self.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let note = Self.shortcutNote(trigger: trigger, accessibilityGranted: privacy.accessibilityPermissionGranted) {
                Label(note, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(note)
            }
        }
        .padding(.vertical, 12)
    }
}
