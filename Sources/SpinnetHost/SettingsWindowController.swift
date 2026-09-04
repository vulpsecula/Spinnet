import AppKit
import SwiftUI
import SpinnetCore

final class SettingsWindowController: NSWindowController {
    private let model: SettingsWindowModel
    private var hostingView: NSHostingView<SettingsRootView>!

    var onConfigurationChanged: ((HostConfiguration) -> Void)?

    var currentPage: SettingsPage {
        model.page
    }

    init(
        editor: HostConfigurationEditor,
        metadata: ApplicationMetadata = .current,
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        model = SettingsWindowModel(editor: editor, metadata: metadata)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_360, height: 820),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        hostingView = NSHostingView(
            rootView: SettingsRootView(model: model, openURL: openURL)
        )
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        window.title = "Spinnet Settings"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 1_080, height: 680)
        window.setAccessibilityLabel("Spinnet Settings")
        window.setAccessibilityHelp(
            "Use the Settings navigation to switch between Menu, Appearance, Privacy & Permissions, and About."
        )
        let contentView = NSView()
        contentView.addSubview(hostingView)
        window.contentView = contentView
        window.initialFirstResponder = hostingView
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: contentView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
        model.onConfigurationChanged = { [weak self] configuration in
            self?.onConfigurationChanged?(configuration)
        }
        model.onAppearanceChanged = { [weak window] theme in
            window?.appearance = Self.windowAppearance(for: theme)
        }
        window.appearance = Self.windowAppearance(for: model.appearanceTheme)
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsWindowController is not decoded from a nib")
    }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if let hostingView {
            window?.makeFirstResponder(hostingView)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The observable Settings window seam used by host-level UI tests.
    var presentationSnapshot: SettingsWindowSnapshot {
        var visibleRegions: [SettingsRegion] = [.navigation]
        if currentPage.showsEditorMode {
            visibleRegions.append(.editorMode)
        }
        visibleRegions.append(.pageContent)

        return SettingsWindowSnapshot(
            page: currentPage,
            navigationPages: SettingsPage.allCases,
            visibleRegions: visibleRegions,
            focusOrder: SettingsPage.allCases.map { .navigation($0) } + [.pageContent],
            initialFocus: .navigation(currentPage),
            editorModeIsNonExecuting: true,
            accessibleNames: model.accessibleNames
        )
    }

    func select(page: SettingsPage) {
        model.page = page
        if window?.isVisible == true, let hostingView {
            window?.makeFirstResponder(hostingView)
        }
    }

    private static func windowAppearance(for theme: String) -> NSAppearance? {
        switch theme {
        case "Light": return NSAppearance(named: .aqua)
        case "Dark": return NSAppearance(named: .darkAqua)
        default: return nil
        }
    }
}
