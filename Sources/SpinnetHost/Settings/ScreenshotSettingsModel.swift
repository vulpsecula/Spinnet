import AppKit
import Combine
import SpinnetCore

/// Drives the Screenshot entry's Plugin Settings: what the Host does after a
/// capture from the Screenshot Host Commands. Each change is written at once
/// and reported, so the Menu can recheck availability.
final class ScreenshotSettingsModel: ObservableObject {
    @Published var afterCapture: ScreenshotSettings.AfterCapture { didSet { commit() } }
    @Published var format: ScreenshotSettings.FileFormat { didSet { commit() } }
    @Published var saveFolder: String { didSet { commit() } }

    var onChange: (() -> Void)?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = ScreenshotSettings(defaults: defaults)
        afterCapture = stored.afterCapture
        format = stored.format
        saveFolder = stored.saveFolder
    }

    var settings: ScreenshotSettings {
        ScreenshotSettings(afterCapture: afterCapture, format: format, saveFolder: saveFolder)
    }

    /// Set only while the settings save and the folder cannot be used; a
    /// capture that only copies never looks at it.
    var folderProblem: String? {
        settings.unavailableReason == nil ? nil : "This folder is missing or cannot be written. Choose another to save screenshots."
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: (saveFolder as NSString).expandingTildeInPath, isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveFolder = url.path
    }

    private func commit() {
        settings.save(to: defaults)
        onChange?()
    }
}
