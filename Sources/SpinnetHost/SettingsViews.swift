import AppKit
import SwiftUI
import SpinnetCore

final class SettingsWindowModel: ObservableObject {
    let editor: HostConfigurationEditor
    let metadata: ApplicationMetadata

    @Published var page: SettingsPage = .menu
    @Published private(set) var refreshToken = 0

    var onConfigurationChanged: ((HostConfiguration) -> Void)?

    init(editor: HostConfigurationEditor, metadata: ApplicationMetadata) {
        self.editor = editor
        self.metadata = metadata
    }

    var menuItems: [MenuItemPresentation] {
        MenuPresentationFactory.makeItems(configuration: editor.configuration) {
            editor.availability(for: $0.id) ?? .unavailable(.commandMissing)
        }
    }

    var accessibleNames: [String] {
        var names = SettingsPage.allCases.map(\.title)
        if page.showsEditorMode {
            names.append("Editor Mode")
        }
        names.append(contentsOf: page.contentAccessibilityNames(metadata: metadata))
        return names
    }

    func configurationDidChange(_ configuration: HostConfiguration) {
        refreshToken += 1
        onConfigurationChanged?(configuration)
    }
}

struct SettingsRootView: View {
    @ObservedObject var model: SettingsWindowModel
    let openURL: (URL) -> Bool

    @FocusState private var focusedPage: SettingsPage?

    var body: some View {
        HStack(spacing: 0) {
            navigation
                .frame(width: 190)
                .frame(maxHeight: .infinity, alignment: .topLeading)

            if model.page.showsEditorMode {
                editorMode
                    .frame(width: 360)
                    .frame(maxHeight: .infinity, alignment: .top)
            }

            pageContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(
            minWidth: 1_080,
            maxWidth: .infinity,
            minHeight: 680,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .onAppear {
            focusedPage = model.page
        }
        .onChange(of: model.page) { page in
            focusedPage = page
        }
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Settings")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            ForEach(SettingsPage.allCases, id: \.self) { page in
                Button(page.title) {
                    model.page = page
                    focusedPage = page
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(page.title)
                .accessibilityIdentifier(page.accessibilityIdentifier.rawValue)
                .accessibilityHint("Show \(page.title) settings.")
                .accessibilityValue(page == model.page ? "Selected" : "Not selected")
                .focused($focusedPage, equals: page)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 22)
        .padding(.bottom, 22)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings Navigation")
    }

    private var editorMode: some View {
        VStack(alignment: .center, spacing: 14) {
            Text("Editor Mode")
                .font(.title2.weight(.semibold))
            Text("The current Menu is shown here without executing Actions.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .accessibilityLabel("The current Menu is shown here without executing Actions.")

            MenuEditorModeRepresentable(items: model.menuItems)
                .frame(width: 324, height: 324)
        }
        .padding(.top, 22)
        .padding(.horizontal, 18)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Editor Mode")
    }

    private var pageContent: some View {
        Group {
            switch model.page {
            case .menu:
                MenuEditorView(
                    editor: model.editor,
                    onConfigurationChanged: model.configurationDidChange
                )
                .id(model.refreshToken)
            case .appearance:
                AppearanceSettingsView()
            case .privacyAndPermissions:
                PrivacySettingsView(openURL: openURL)
            case .about:
                AboutSettingsView(metadata: model.metadata)
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, 24)
        .padding(.bottom, 30)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(model.page.title) Page Content")
    }
}

private struct MenuEditorModeRepresentable: NSViewRepresentable {
    let items: [MenuItemPresentation]

    func makeNSView(context: Context) -> RadialMenuView {
        RadialMenuView(items: items, mode: .editor)
    }

    func updateNSView(_ nsView: RadialMenuView, context: Context) {
        nsView.reload(items: items)
    }
}

private struct AppearanceSettingsView: View {
    @State private var theme = "System"
    @State private var accent = Color.accentColor
    @State private var menuSize = "Medium"

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            pageHeader(
                title: SettingsPage.appearance.title,
                description: "Adjust the shared visual presentation of the current Menu."
            )

            GroupBox("Theme") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Use the System appearance or choose Light or Dark for Spinnet.")
                        .foregroundStyle(.secondary)
                    Picker("Theme", selection: $theme) {
                        Text("System").tag("System")
                        Text("Light").tag("Light")
                        Text("Dark").tag("Dark")
                    }
                    .accessibilityLabel("Theme")
                    .accessibilityHint("Choose whether Spinnet follows macOS, Light, or Dark appearance.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Accent Colour") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("The accent colour is used for selected Menu Items and follows the system accent by default.")
                        .foregroundStyle(.secondary)
                    ColorPicker("Accent Colour", selection: $accent, supportsOpacity: false)
                        .accessibilityLabel("Accent Colour")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Menu Size") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Size applies consistently to the Menu's Editor Mode and Runtime Mode geometry.")
                        .foregroundStyle(.secondary)
                    Picker("Menu Size", selection: $menuSize) {
                        Text("Small").tag("Small")
                        Text("Medium").tag("Medium")
                        Text("Large").tag("Large")
                    }
                    .accessibilityLabel("Menu Size")
                    .accessibilityHint("Choose the size of the Menu in Editor and Runtime Modes.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button("Reset Appearance") {
                theme = "System"
                accent = .accentColor
                menuSize = "Medium"
            }
            .accessibilityLabel("Reset Appearance")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PrivacySettingsView: View {
    let openURL: (URL) -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            pageHeader(
                title: SettingsPage.privacyAndPermissions.title,
                description: "Review the separate layers of authority used by Spinnet and its Plugins."
            )

            privacySection(
                title: "System Permissions",
                body: "Accessibility, Screen Recording, and target-specific Automation remain separate macOS permissions. Spinnet requests them only when a configured feature needs them.",
                status: "No optional permission is requested by the current fixture Menu."
            )
            privacySection(
                title: "Sensitive Data Collection",
                body: "Host-owned data such as Clipboard History is opt-in and remains separate from a Plugin's access Capability.",
                status: "Clipboard History collection is Off by default."
            )
            privacySection(
                title: "Plugin Access",
                body: "Each Plugin receives only the Capabilities granted to it. Revoking access leaves its configuration in place and makes affected Actions unavailable.",
                status: "No Plugin Capability grants are configured in this MVP slice."
            )

            Button("Open macOS System Settings…") {
                guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
                    return
                }
                _ = openURL(url)
            }
            .accessibilityLabel("Open macOS System Settings")
            .accessibilityHint("Review the System Permissions used by Spinnet in macOS System Settings.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func privacySection(title: String, body: String, status: String) -> some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 8) {
                Text(body)
                    .foregroundStyle(.secondary)
                Text(status)
                    .accessibilityLabel("\(title): \(status)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AboutSettingsView: View {
    let metadata: ApplicationMetadata

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            pageHeader(
                title: SettingsPage.about.title,
                description: "Application information and project details."
            )

            HStack(alignment: .center, spacing: 16) {
                Image(nsImage: applicationIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .accessibilityLabel("\(metadata.name) application icon")
                VStack(alignment: .leading, spacing: 5) {
                    Text(metadata.name)
                        .font(.title2.weight(.semibold))
                        .accessibilityLabel(metadata.name)
                    Text(metadata.versionAndBuild)
                        .accessibilityLabel(metadata.versionAndBuild)
                }
            }

            Text(metadata.description)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(metadata.description)

            Link("Source on GitHub", destination: metadata.sourceURL)
                .accessibilityLabel("Source on GitHub")
                .accessibilityHint("Open Spinnet's source repository in the default browser.")

            aboutSection(title: "Licence", value: metadata.licence)
            aboutSection(title: "Acknowledgements", value: metadata.acknowledgements)
            aboutSection(title: "Copyright", value: metadata.copyright)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var applicationIcon: NSImage {
        NSApp.applicationIconImage ?? NSImage(named: NSImage.applicationIconName) ?? NSImage(size: NSSize(width: 72, height: 72))
    }

    private func aboutSection(title: String, value: String) -> some View {
        GroupBox(title) {
            Text(value)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(value)
        }
    }
}

func pageHeader(title: String, description: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        Text(title)
            .font(.title.weight(.semibold))
            .accessibilityAddTraits(.isHeader)
        Text(description)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(description)
    }
}
