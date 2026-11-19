import SwiftUI

/// The restart beside a Screen Recording grant that waits for one, for a
/// user who chose Later in System Settings' Quit & Reopen prompt.
struct RestartSpinnetLink: View {
    let action: () -> Void

    var body: some View {
        Button(localized("Restart Spinnet"), action: action)
            .buttonStyle(.link)
            .controlSize(.small)
            .accessibilityLabel(localized("Restart Spinnet to finish enabling Screen Recording"))
    }
}
