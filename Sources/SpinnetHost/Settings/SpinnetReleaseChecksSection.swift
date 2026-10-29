import SwiftUI

/// General's Spinnet release checks: the daily automatic check, Check Now,
/// a newer release with a link to its page, and why the last check did not
/// complete. A failure is reported here only, never as an alert.
struct SpinnetReleaseChecksSection: View {
    @ObservedObject var releases: SpinnetReleaseChecksModel

    private let title = "Check for Spinnet updates automatically"
    private var detail: String {
        releases.isDevelopmentBuild
            ? SpinnetReleaseChecksModel.developmentBuildNote
            : "Once a day, ask GitHub for a newer Spinnet release. Nothing downloads or installs."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.body.weight(.medium))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Toggle(title, isOn: $releases.checksAutomatically)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(releases.isDevelopmentBuild)
                    .accessibilityLabel(title)
                    .accessibilityHint(detail)
            }
            HStack(spacing: 8) {
                Button("Check Now", action: releases.checkNow)
                    .controlSize(.small)
                    .disabled(releases.isChecking)
                    .accessibilityLabel("Check Now for Spinnet updates")
                if releases.isChecking {
                    ProgressView().controlSize(.small)
                }
                Text(releases.summary)
                if releases.availableRelease != nil {
                    Button("View Release", action: releases.openAvailableRelease)
                        .controlSize(.small)
                        .accessibilityHint("Open the release page on GitHub. Nothing is downloaded.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let failure = releases.shownFailure, !releases.isChecking {
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
}
