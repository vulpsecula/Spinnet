import AppKit
import SpinnetCore

enum SettingsPage: String, CaseIterable, Hashable {
    /// App-wide preferences. In a DEBUG Host its last section is Developer.
    case general
    case menu
    case appearance
    case privacyAndPermissions = "privacy-and-permissions"
    case about
}

enum SettingsRegion: String, Equatable {
    case navigation
    case editorMode
    case pageContent
}

enum SettingsFocusTarget: Equatable {
    case navigation(SettingsPage)
    case pageContent
}

struct SettingsWindowSnapshot: Equatable {
    let page: SettingsPage
    let navigationPages: [SettingsPage]
    let visibleRegions: [SettingsRegion]
    let focusOrder: [SettingsFocusTarget]
    let initialFocus: SettingsFocusTarget
    let editorModeIsNonExecuting: Bool
    let accessibleNames: [String]
}

struct ApplicationMetadata {
    let name: String
    let version: String
    let build: String
    let description: String
    let sourceURL: URL
    let licence: String
    let acknowledgements: String
    let copyright: String

    var versionAndBuild: String {
        localized("Version \(version) (Build \(build))")
    }

    static var current: ApplicationMetadata { ApplicationMetadata(
        name: "Spinnet",
        version: "0.1",
        build: localized("Development"),
        description: localized("A mouse-first macOS action environment centered on a radial Menu."),
        sourceURL: URL(string: "https://github.com/vulpsecula/Spinnet")!,
        licence: "GPL-3.0-only", // Not localized: a licence identifier
        acknowledgements: localized("Built with Swift and AppKit."),
        copyright: "© 2026 vulpsecula" // Not localized: a name
    ) }
}

private struct SettingsPageDescriptor {
    let title: String
    let showsEditorMode: Bool
    let accessibilityIdentifier: NSUserInterfaceItemIdentifier
    let contentAccessibilityNames: (ApplicationMetadata) -> [String]
}

extension SettingsPage {
    private var descriptor: SettingsPageDescriptor {
        switch self {
        case .general:
            return SettingsPageDescriptor(
                title: localized("General"),
                showsEditorMode: false,
                accessibilityIdentifier: NSUserInterfaceItemIdentifier("settings.page.general"),
                contentAccessibilityNames: { _ in
                    [localized("General"), localized("Launch at Login"), localized("Show Status Item"), localized("Open Welcome Guide")]
                }
            )
        case .menu:
            return SettingsPageDescriptor(
                title: localized("Menu"),
                showsEditorMode: true,
                accessibilityIdentifier: NSUserInterfaceItemIdentifier("settings.page.menu"),
                contentAccessibilityNames: { _ in
                    [
                        localized("Menu"),
                        localized("Menu Editor"),
                        localized("Menu Trigger"),
                        localized("Mouse trigger"),
                        localized("Click & Drag"),
                        localized("Keyboard shortcut optional"),
                        localized("Accessibility status"),
                        localized("Library"),
                        localized("Browse Plugins…"),
                        localized("Menu Item Alias"),
                        localized("Add empty Slot"),
                        localized("Edit on the Menu")
                    ]
                }
            )
        case .appearance:
            return SettingsPageDescriptor(
                title: localized("Appearance"),
                showsEditorMode: true,
                accessibilityIdentifier: NSUserInterfaceItemIdentifier("settings.page.appearance"),
                contentAccessibilityNames: { _ in
                    [
                        localized("Appearance"), localized("Alternate Actions"), localized("Menu Theme"), localized("Accent Colour"), localized("Menu Size"), localized("Menu Font"), localized("Menu Font Weight"),
                        localized("Undo Appearance change"), localized("Redo Appearance change"), localized("Reset Appearance")
                    ]
                }
            )
        case .privacyAndPermissions:
            return SettingsPageDescriptor(
                title: localized("Privacy & Permissions"),
                showsEditorMode: false,
                accessibilityIdentifier: NSUserInterfaceItemIdentifier("settings.page.privacy-and-permissions"),
                contentAccessibilityNames: { _ in
                    [
                        localized("Privacy & Permissions"),
                        localized("System Permissions"),
                        localized("Sensitive Data Collection"),
                        localized("Collect Clipboard History"),
                        localized("Pause Clipboard History collection"),
                        localized("Clipboard retention"),
                        localized("Plugin Access"),
                        localized("Plugin Access & Data")
                    ] + PluginSystemPermission.allCases.map {
                        localized("Open \($0.localizedTitle) Settings")
                    }
                }
            )
        case .about:
            return SettingsPageDescriptor(
                title: localized("About"),
                showsEditorMode: false,
                accessibilityIdentifier: NSUserInterfaceItemIdentifier("settings.page.about"),
                contentAccessibilityNames: { metadata in
                    [
                        metadata.name,
                        metadata.versionAndBuild,
                        metadata.description,
                        localized("Source on GitHub"),
                        localized("Licence"),
                        metadata.licence,
                        localized("Acknowledgements"),
                        metadata.acknowledgements,
                        localized("Copyright"),
                        metadata.copyright
                    ]
                }
            )
        }
    }

    var title: String { descriptor.title }

    var systemImageName: String {
        switch self {
        case .general: return "gearshape"
        case .menu: return "circle.hexagongrid"
        case .appearance: return "paintbrush"
        case .privacyAndPermissions: return "hand.raised"
        case .about: return "info.circle"
        }
    }

    var showsEditorMode: Bool { descriptor.showsEditorMode }

    var accessibilityIdentifier: NSUserInterfaceItemIdentifier {
        descriptor.accessibilityIdentifier
    }

    func contentAccessibilityNames(metadata: ApplicationMetadata) -> [String] {
        descriptor.contentAccessibilityNames(metadata)
    }
}
