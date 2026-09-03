import AppKit

enum SettingsPage: String, CaseIterable, Hashable {
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
        "Version \(version) (Build \(build))"
    }

    static let current = ApplicationMetadata(
        name: "Spinnet",
        version: "0.1",
        build: "Development",
        description: "A mouse-first macOS action environment centered on a radial Menu.",
        sourceURL: URL(string: "https://github.com/vulpsecula/Spinnet")!,
        licence: "GPL with a Plugin Exception",
        acknowledgements: "Built with Swift and AppKit.",
        copyright: "© 2026 Spinnet contributors"
    )
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
        case .menu:
            return SettingsPageDescriptor(
                title: "Menu",
                showsEditorMode: true,
                accessibilityIdentifier: NSUserInterfaceItemIdentifier("settings.page.menu"),
                contentAccessibilityNames: { _ in
                    [
                        "Menu",
                        "Menu Editor",
                        "Available Plugin Commands",
                        "Configured Actions",
                        "Bind Actions to a Menu Item"
                    ]
                }
            )
        case .appearance:
            return SettingsPageDescriptor(
                title: "Appearance",
                showsEditorMode: true,
                accessibilityIdentifier: NSUserInterfaceItemIdentifier("settings.page.appearance"),
                contentAccessibilityNames: { _ in
                    ["Appearance", "Theme", "Accent Colour", "Menu Size", "Reset Appearance"]
                }
            )
        case .privacyAndPermissions:
            return SettingsPageDescriptor(
                title: "Privacy & Permissions",
                showsEditorMode: false,
                accessibilityIdentifier: NSUserInterfaceItemIdentifier("settings.page.privacy-and-permissions"),
                contentAccessibilityNames: { _ in
                    [
                        "Privacy & Permissions",
                        "System Permissions",
                        "Sensitive Data Collection",
                        "Plugin Access",
                        "Open macOS System Settings"
                    ]
                }
            )
        case .about:
            return SettingsPageDescriptor(
                title: "About",
                showsEditorMode: false,
                accessibilityIdentifier: NSUserInterfaceItemIdentifier("settings.page.about"),
                contentAccessibilityNames: { metadata in
                    [
                        metadata.name,
                        metadata.versionAndBuild,
                        metadata.description,
                        "Source on GitHub",
                        "Licence",
                        metadata.licence,
                        "Acknowledgements",
                        metadata.acknowledgements,
                        "Copyright",
                        metadata.copyright
                    ]
                }
            )
        }
    }

    var title: String { descriptor.title }

    var showsEditorMode: Bool { descriptor.showsEditorMode }

    var accessibilityIdentifier: NSUserInterfaceItemIdentifier {
        descriptor.accessibilityIdentifier
    }

    func contentAccessibilityNames(metadata: ApplicationMetadata) -> [String] {
        descriptor.contentAccessibilityNames(metadata)
    }
}
