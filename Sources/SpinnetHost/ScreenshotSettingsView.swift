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
                    Picker("Format", selection: $model.format) {
                        Text("PNG").tag(ScreenCaptureFormat.png)
                        Text("JPEG").tag(ScreenCaptureFormat.jpg)
                    }
                    .accessibilityLabel("Format")
                    LabeledContent("Save Folder") {
                        HStack {
                            Text((model.saveFolder as NSString).abbreviatingWithTildeInPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(model.afterCapture.saves ? .primary : .secondary)
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
                    } else if !model.afterCapture.saves {
                        Text("Used only when After Capture saves.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
