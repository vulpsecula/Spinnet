import SpinnetCore
import SwiftUI

/// The Screenshots settings page. One setting covers every capture, from the
/// Screenshot Menu Items and from any Plugin allowed to ask for one.
struct ScreenshotSettingsView: View {
    @ObservedObject var model: ScreenshotSettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                pageHeader(
                    title: SettingsPage.screenshots.title,
                    description: "Choose what Spinnet does with every screenshot, whether a Screenshot Menu Item or a Plugin you allowed took it. Plugins never receive the image."
                )
                Form {
                    Picker("After Capture", selection: $model.afterCapture) {
                        ForEach(ScreenshotSettings.AfterCapture.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .accessibilityLabel("After Capture")
                    Section {
                        Picker("Format", selection: $model.format) {
                            ForEach(ScreenshotSettings.FileFormat.allCases, id: \.self) { format in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(format.title)
                                    Text(format.summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .tag(format)
                                .accessibilityLabel("\(format.title): \(format.summary)")
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .accessibilityLabel("Format")
                        LabeledContent("Save Folder") {
                            HStack {
                                Text((model.saveFolder as NSString).abbreviatingWithTildeInPath)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .accessibilityLabel("Save Folder")
                                    .accessibilityValue(model.saveFolder)
                                Button("Choose…", action: model.chooseFolder)
                                    .accessibilityLabel("Choose Save Folder")
                            }
                        }
                        if let problem = model.folderProblem {
                            Label(problem, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } header: {
                        Text("Saved File")
                    } footer: {
                        Text(model.afterCapture.saves
                             ? "Copied screenshots are always lossless."
                             : "Saving is off: screenshots are only copied, losslessly. Choose Save to Folder or Copy and Save to use these.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // Kept editable, so the choice is ready when saving is turned on.
                    .opacity(model.afterCapture.saves ? 1 : 0.6)
                }
                .formStyle(.grouped)
                Text("Screenshots need Screen Recording, which Spinnet asks for only when you choose Enable Screen Recording in Privacy & Permissions or in a Screenshot Menu Item's sheet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
