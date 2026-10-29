import SpinnetCore
import SwiftUI

/// The Screenshot entry's options in its Plugin Settings. They apply to
/// every Screenshot Menu Item; a Plugin that asks for a capture brings its own.
struct ScreenshotSettingsView: View {
    @ObservedObject var model: ScreenshotSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localized("After Capture")).font(.headline)
            Picker(localized("After Capture"), selection: $model.afterCapture) {
                ForEach(ScreenshotSettings.AfterCapture.allCases, id: \.self) { Text($0.localizedTitle).tag($0) }
            }
            .labelsHidden()
            .accessibilityLabel(localized("After Capture"))

            VStack(alignment: .leading, spacing: 10) {
                Text(localized("Saved File")).font(.headline)
                Picker(localized("Format"), selection: $model.format) {
                    ForEach(ScreenshotSettings.FileFormat.allCases, id: \.self) { format in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(format.localizedTitle)
                            Text(format.localizedSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .tag(format)
                        .accessibilityLabel("\(format.localizedTitle): \(format.localizedSummary)")
                    }
                }
                .pickerStyle(.radioGroup)
                .accessibilityLabel(localized("Format"))
                HStack {
                    Text(localized("Save Folder"))
                    Text((model.saveFolder as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(localized("Save Folder"))
                        .accessibilityValue(model.saveFolder)
                    Spacer()
                    Button(localized("Choose…"), action: model.chooseFolder)
                        .accessibilityLabel(localized("Choose Save Folder"))
                }
                if let problem = model.folderProblem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(model.afterCapture.saves
                     ? localized("Copied screenshots are always lossless.")
                     : localized("Saving is off: screenshots are only copied, losslessly. Choose Save to Folder or Copy and Save to use these."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Kept editable, so the choice is ready when saving is turned on.
            .opacity(model.afterCapture.saves ? 1 : 0.6)
        }
        .padding(14)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localized("Screenshot Settings"))
    }
}
