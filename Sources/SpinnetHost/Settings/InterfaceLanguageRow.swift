import SwiftUI

/// General's language choice: System, English or 简体中文, applied when
/// Spinnet relaunches.
struct InterfaceLanguageRow: View {
    @ObservedObject var language: InterfaceLanguageModel

    static func accessibleNames(for language: InterfaceLanguageModel) -> [String] {
        var names = [localized("Language")]
        if language.offersRelaunch {
            names.append(localized("Relaunch"))
        } else if language.needsRelaunch {
            names.append(quitNote)
        }
        return names
    }

    private static var quitNote: String {
        localized("Quit and open Spinnet again to use the new language.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(localized("Language")).font(.body.weight(.medium))
                    Text(localized("Spinnet's own text. Plugins show their text as they provide it."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Picker(localized("Language"), selection: $language.choice) {
                    ForEach(InterfaceLanguage.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel(localized("Language"))
            }
            if language.offersRelaunch {
                HStack(spacing: 12) {
                    Text(localized("Relaunch Spinnet to use the new language."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Button(localized("Relaunch"), action: language.relaunch)
                        .controlSize(.small)
                        .accessibilityLabel(localized("Relaunch"))
                }
            } else if language.needsRelaunch {
                Text(Self.quitNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }
}
