import AppKit
import SpinnetCore
import SpinnetTestSupport
import XCTest
@testable import SpinnetHost

/// What icon a Menu Item shows, in the Library, the Menu Editor and on the
/// radial Menu: its Plugin's Plugin Icon, else a neutral Host symbol.
final class MenuItemIconTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private let pluginID = PluginID("com.example.iconic")

    private func manifest(icon: IconDeclaration?, version: String = "1.0.0", name: String = "Iconic",
                          id: PluginID? = nil) throws -> PluginManifest {
        try PluginManifest(
            id: id ?? pluginID, name: name, version: version, icon: icon,
            commands: [CommandDeclaration(id: CommandID("run"), title: "Run", execution: .javascript,
                                          isConfigurable: false, script: "run.js")],
            preset: MenuItemPresetDeclaration(readiness: .readyToUse, isConfigurable: false)
        )
    }

    private func makeEditor(icon: IconDeclaration?) throws -> (MenuEditorModel, PluginRegistry) {
        let registry = PluginRegistry()
        let manifest = try manifest(icon: icon)
        try registry.register(PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/iconic.spinnetplugin"), manifest: manifest))
        let action = try ActionConfiguration(id: ActionID("run"), pluginID: pluginID,
                                             command: manifest.commands[0], input: .null)
        let configuration = try HostConfiguration(
            actions: [action],
            menu: MenuConfiguration(slots: [.occupied(MenuItemConfiguration(primaryActionID: action.id)), .empty])
        )
        return (MenuEditorModel(editor: HostConfigurationEditor(registry: registry, configuration: configuration)), registry)
    }

    // MARK: Resolution

    func testAMenuItemShowsItsPluginIcon() throws {
        let (model, _) = try makeEditor(icon: .symbol("music.note"))
        XCTAssertEqual(model.menuSlots[0].item?.icon, MenuItemIcon(symbolName: "music.note"))
    }

    func testAMenuItemFromAPluginWithoutAnIconShowsTheNeutralSymbol() throws {
        let (model, _) = try makeEditor(icon: nil)
        XCTAssertEqual(model.menuSlots[0].item?.icon, .neutral)
        XCTAssertFalse(MenuItemIcon.neutral.symbolName.isEmpty)
    }

    func testAMenuItemOfARemovedPluginShowsTheNeutralSymbolWhileUnavailable() throws {
        let (model, registry) = try makeEditor(icon: .symbol("music.note"))
        registry.unregister(pluginID)
        model.refreshMenuSlots()
        let item = try XCTUnwrap(model.menuSlots[0].item)
        XCTAssertEqual(item.icon, .neutral)
        XCTAssertFalse(item.primaryAction.isAvailable)
    }

    /// The resolution itself, for every unavailable state that leaves no
    /// Plugin to take an icon from.
    func testUnavailablePluginsAndCommandsResolveToTheNeutralSymbol() {
        let icon = IconDeclaration.symbol("music.note")
        XCTAssertEqual(MenuItemIcon.resolve(pluginIcon: icon, primaryAvailability: .available),
                       MenuItemIcon(symbolName: "music.note"))
        for reason: ActionUnavailableReason in [.pluginMissing, .pluginRefused("Needs a newer Spinnet"), .commandMissing] {
            XCTAssertEqual(MenuItemIcon.resolve(pluginIcon: icon, primaryAvailability: .unavailable(reason)),
                           .neutral, "\(reason)")
        }
        // An installed Plugin whose Action waits on access keeps its icon.
        XCTAssertEqual(MenuItemIcon.resolve(pluginIcon: icon, primaryAvailability: .unavailable(.capabilityDenied)),
                       MenuItemIcon(symbolName: "music.note"))
        XCTAssertEqual(MenuItemIcon.resolve(pluginIcon: nil, primaryAvailability: .available), .neutral)
    }

    func testARefusedPluginsMenuItemShowsTheNeutralSymbol() throws {
        let (model, registry) = try makeEditor(icon: .symbol("music.note"))
        registry.unregister(pluginID)
        registry.recordRefused(RefusedPlugin(id: pluginID, manifest: nil, reason: "Needs a newer Spinnet"))
        model.refreshMenuSlots()
        let item = try XCTUnwrap(model.menuSlots[0].item)
        XCTAssertEqual(item.primaryAction.availability.reason, .pluginRefused("Needs a newer Spinnet"))
        XCTAssertEqual(item.icon, .neutral)
    }

    func testTheLibraryShowsEachPresetWithItsPluginIconOrTheNeutralSymbol() throws {
        let (model, registry) = try makeEditor(icon: .symbol("music.note"))
        try registry.register(PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/plain.spinnetplugin"),
                                            manifest: manifest(icon: nil, name: "Plain", id: PluginID("com.example.plain"))))
        let presets = model.libraryPresets(matching: "")
        XCTAssertEqual(presets.map(\.name), ["Iconic", "Plain"])
        XCTAssertEqual(presets.map(MenuItemIcon.init(preset:)), [MenuItemIcon(symbolName: "music.note"), .neutral])
    }

    // MARK: Plugin Update and installation

    /// An icon-only Plugin Update keeps every configured Action available,
    /// edits no Menu Item, and the Menu Item shows the new icon.
    func testAnIconOnlyPluginUpdateKeepsActionsAvailableAndEditsNoMenuItems() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let registry = PluginRegistry()
        let store = PluginInstallationStore(directory: directory.appendingPathComponent("Installed"), registry: registry,
                                            grants: PluginCapabilityGrantStore(), persistGrants: {})
        func package(_ manifest: PluginManifest, _ name: String) throws -> URL {
            let url = directory.appendingPathComponent(name).appendingPathComponent("Iconic.spinnetplugin")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try JSONEncoder().encode(manifest).write(to: url.appendingPathComponent("manifest.json"))
            try Data("null".utf8).write(to: url.appendingPathComponent("run.js"))
            return url
        }
        try store.install(from: package(manifest(icon: nil), "v1"))
        let editor = HostConfigurationEditor(
            registry: registry, configuration: try HostConfiguration(actions: [], menu: MenuConfiguration(slots: [.empty, .empty])))
        let model = MenuEditorModel(editor: editor)
        model.reviewPluginInstallation = { try store.review($0) }
        model.installPlugin = { try store.install(from: $0) }
        XCTAssertTrue(model.placePreset(pluginID: pluginID.rawValue, at: 0))
        let arranged = model.editor.configuration
        XCTAssertEqual(model.menuSlots[0].item?.icon, .neutral)

        model.installPluginPackage(at: try package(manifest(icon: .symbol("star"), version: "1.1.0"), "v2"))
        if let pending = model.pendingInstallation { try model.installReviewed(pending) }

        XCTAssertEqual(registry.package(for: pluginID)?.manifest.version, "1.1.0")
        XCTAssertEqual(model.editor.configuration, arranged, "Installing or updating edits no Menu Items")
        let item = try XCTUnwrap(model.menuSlots[0].item)
        XCTAssertTrue(item.primaryAction.isAvailable)
        XCTAssertEqual(item.icon, MenuItemIcon(symbolName: "star"))
        XCTAssertNil(model.menuSlots[1].item, "Installing places nothing into an empty Slot")
    }

    // MARK: The radial Menu

    private func iconicItem(available: Bool = true, symbol: String = "music.note") throws -> MenuSlotPresentation {
        let id = ActionID("run")
        return .occupied(MenuItemPresentation(
            configuration: try MenuItemConfiguration(primaryActionID: id),
            primaryAction: MenuActionPresentation(actionID: id, title: "Play Music",
                                                  availability: available ? .available : .unavailable(.pluginMissing)),
            alternateActions: [],
            icon: MenuItemIcon(symbolName: symbol)
        ))
    }

    func testTheMenuDrawsEachMenuItemsIconWithItsTitle() throws {
        for mode in [RadialMenuPresentationMode.runtime, .editor] {
            let view = RadialMenuView(slots: [try iconicItem(), .empty, try iconicItem(symbol: "star"), .empty], mode: mode)
            XCTAssertNil(view.menuIcon(at: 1), "An empty Slot draws no icon")
            let drawn = try XCTUnwrap(view.menuIcon(at: 0))
            XCTAssertEqual(drawn.symbolName, "music.note")
            XCTAssertEqual(view.menuIcon(at: 2)?.symbolName, "star")
            let title = view.menuTitleRect(at: 0)
            XCTAssertFalse(drawn.rect.intersects(title), "\(mode): the icon sits clear of the title")
            XCTAssertGreaterThanOrEqual(drawn.rect.minY, title.maxY, "\(mode): the icon sits above the title")
            XCTAssertEqual(drawn.rect.midX, title.midX, accuracy: 1)
            XCTAssertTrue(view.bounds.contains(drawn.rect))
        }
    }

    func testAnUnknownSymbolStillDrawsTheNeutralSymbol() throws {
        let view = RadialMenuView(slots: [try iconicItem(symbol: "no.such.symbol.anywhere")], mode: .runtime)
        XCTAssertEqual(view.menuIcon(at: 0)?.symbolName, MenuItemIcon.neutral.symbolName)
    }

    func testIconsScaleWithTheMenuSize() throws {
        func side(_ size: String) throws -> CGFloat {
            let view = RadialMenuView(slots: [try iconicItem(), .empty, .empty, .empty], mode: .runtime)
            view.applyAppearance(MenuAppearanceConfiguration(menuSize: size))
            return try XCTUnwrap(view.menuIcon(at: 0)).rect.width
        }
        let small = try side("Small"), large = try side("Large")
        XCTAssertGreaterThan(small, 10)
        XCTAssertEqual(large / small, 2, accuracy: 0.15)
        XCTAssertGreaterThan(try side("Medium"), small)
    }

    func testIconsFollowTheAccentAndTheLightOrDarkTheme() throws {
        func colour(theme: String, accent: String, available: Bool = true) throws -> NSColor {
            let view = RadialMenuView(slots: [try iconicItem(available: available)], mode: .runtime)
            view.applyAppearance(MenuAppearanceConfiguration(theme: theme, accent: accent))
            return try XCTUnwrap(view.menuIcon(at: 0)).color
        }
        XCTAssertNotEqual(try colour(theme: "Light", accent: "Green"), try colour(theme: "Light", accent: "Pink"),
                          "An available icon takes the Menu's accent")
        XCTAssertNotEqual(try colour(theme: "Light", accent: "Green", available: false),
                          try colour(theme: "Dark", accent: "Green", available: false),
                          "An unavailable icon follows the Menu's Light or Dark theme")
        XCTAssertEqual(try colour(theme: "Light", accent: "Green", available: false),
                       try colour(theme: "Light", accent: "Pink", available: false),
                       "An unavailable icon keeps the unavailable treatment whatever the accent")
    }

    // MARK: Package pictures

    /// A package on disk holding `files`, registered with `icon`.
    private func pictureEditor(icon: IconPicture, files: [String: Data])
        throws -> (MenuEditorModel, PluginRegistry, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("Iconic.spinnetplugin")
        addTeardownBlock { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        for (path, data) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let registry = PluginRegistry()
        let manifest = try manifest(icon: .picture(icon))
        try registry.register(PluginPackage(rootURL: root, manifest: manifest))
        let action = try ActionConfiguration(id: ActionID("run"), pluginID: pluginID,
                                             command: manifest.commands[0], input: .null)
        let configuration = try HostConfiguration(
            actions: [action],
            menu: MenuConfiguration(slots: [.occupied(MenuItemConfiguration(primaryActionID: action.id)), .empty])
        )
        return (MenuEditorModel(editor: HostConfigurationEditor(registry: registry, configuration: configuration)),
                registry, root)
    }

    func testAMenuItemAndItsPresetShowThePackagePicture() throws {
        let picture = IconPicture(path: "icons/mark.pdf", darkPath: "icons/mark-dark.png")
        let (model, _, root) = try pictureEditor(icon: picture, files: [
            "icons/mark.pdf": IconPictureFixtures.pdf(), "icons/mark-dark.png": IconPictureFixtures.bitmap(width: 64, height: 64)
        ])
        let expected = MenuItemIcon.Picture(url: root.appendingPathComponent("icons/mark.pdf"),
                                            darkURL: root.appendingPathComponent("icons/mark-dark.png"), isTemplate: false)
        XCTAssertEqual(model.menuSlots[0].item?.icon.picture, expected)
        XCTAssertEqual(model.libraryPresets(matching: "").map { MenuItemIcon(preset: $0).picture }, [expected])
    }

    /// The Host keeps no copy of a package picture: once the Plugin is
    /// gone, its Menu Items show the neutral symbol.
    func testAMenuItemOfARemovedPluginWithAPictureFallsBackToTheNeutralSymbol() throws {
        let (model, registry, root) = try pictureEditor(icon: IconPicture(path: "mark.png", isTemplate: true),
                                                        files: ["mark.png": IconPictureFixtures.bitmap(width: 64, height: 64)])
        XCTAssertNotNil(model.menuSlots[0].item?.icon.picture)
        registry.unregister(pluginID)
        try FileManager.default.removeItem(at: root)
        model.refreshMenuSlots()
        XCTAssertEqual(model.menuSlots[0].item?.icon, .neutral)
        XCTAssertEqual(MenuItemIcon.resolve(pluginIcon: .picture(IconPicture(path: "mark.png")),
                                            primaryAvailability: .unavailable(.pluginMissing)), .neutral)
    }

    private func pictureItem(_ picture: MenuItemIcon.Picture, available: Bool = true) throws -> MenuSlotPresentation {
        let id = ActionID("run")
        return .occupied(MenuItemPresentation(
            configuration: try MenuItemConfiguration(primaryActionID: id),
            primaryAction: MenuActionPresentation(actionID: id, title: "Play Music",
                                                  availability: available ? .available : .unavailable(.capabilityDenied)),
            alternateActions: [],
            icon: MenuItemIcon(picture: picture)
        ))
    }

    private func writePictures(_ files: [String: Data]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for (name, data) in files { try data.write(to: root.appendingPathComponent(name)) }
        return root
    }

    func testAFullColourPictureUsesItsDarkPictureInADarkMenu() throws {
        let root = try writePictures(["light.png": IconPictureFixtures.bitmap(width: 64, height: 64),
                                      "dark.png": IconPictureFixtures.bitmap(width: 64, height: 64)])
        let picture = MenuItemIcon.Picture(url: root.appendingPathComponent("light.png"),
                                           darkURL: root.appendingPathComponent("dark.png"), isTemplate: false)
        func drawn(theme: String, _ picture: MenuItemIcon.Picture) throws -> RadialMenuView.MenuIconDrawing {
            let view = RadialMenuView(slots: [try pictureItem(picture)], mode: .runtime)
            view.applyAppearance(MenuAppearanceConfiguration(theme: theme))
            return try XCTUnwrap(view.menuIcon(at: 0))
        }
        XCTAssertEqual(try drawn(theme: "Light", picture).pictureURL, picture.url)
        XCTAssertEqual(try drawn(theme: "Dark", picture).pictureURL, picture.darkURL)
        let lightOnly = MenuItemIcon.Picture(url: picture.url, darkURL: nil, isTemplate: false)
        XCTAssertEqual(try drawn(theme: "Dark", lightOnly).pictureURL, picture.url, "Without a dark picture, the picture")
        XCTAssertFalse(try drawn(theme: "Dark", picture).isTemplate)
    }

    /// A template picture is tinted the way the Menu tints a system symbol:
    /// its shape takes the accent, whatever colours the file holds.
    func testATemplatePictureIsTintedLikeASymbol() throws {
        let root = try writePictures(["mark.pdf": IconPictureFixtures.pdf()])
        let picture = MenuItemIcon.Picture(url: root.appendingPathComponent("mark.pdf"), darkURL: nil, isTemplate: true)
        let view = RadialMenuView(slots: [try pictureItem(picture)], mode: .runtime)
        view.applyAppearance(MenuAppearanceConfiguration(theme: "Dark", accent: "Green"))
        let drawing = try XCTUnwrap(view.menuIcon(at: 0))
        XCTAssertTrue(drawing.isTemplate)
        let symbol = RadialMenuView(slots: [try iconicItem()], mode: .runtime)
        symbol.applyAppearance(MenuAppearanceConfiguration(theme: "Dark", accent: "Green"))
        XCTAssertEqual(drawing.color, try XCTUnwrap(symbol.menuIcon(at: 0)).color)

        let bitmap = try render(XCTUnwrap(view.menuIconImage(at: 0)), scale: 2)
        let opaque = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 4, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        let tint = try XCTUnwrap(drawing.color.usingColorSpace(.sRGB))
        XCTAssertEqual(opaque.alphaComponent, 1, accuracy: 0.05)
        XCTAssertEqual(opaque.redComponent, tint.redComponent, accuracy: 0.05)
        XCTAssertEqual(opaque.greenComponent, tint.greenComponent, accuracy: 0.05)
        XCTAssertEqual(opaque.blueComponent, tint.blueComponent, accuracy: 0.05)
        XCTAssertEqual(bitmap.colorAt(x: bitmap.pixelsWide * 3 / 4, y: bitmap.pixelsHigh / 2)?.alphaComponent ?? 1, 0,
                       accuracy: 0.05, "The picture's clear half stays clear")
    }

    /// Drawn at the Retina scale of each Menu Size, the PDF's edge stays a
    /// hard edge (drawn as vectors), and a PNG is drawn from its own pixels.
    func testPicturesStaySharpAtEveryMenuSize() throws {
        let root = try writePictures(["mark.pdf": IconPictureFixtures.pdf(),
                                      "mark.png": IconPictureFixtures.bitmap(width: 256, height: 256)])
        for name in ["mark.pdf", "mark.png"] {
            for size in ["Small", "Medium", "Large"] {
                let picture = MenuItemIcon.Picture(url: root.appendingPathComponent(name), darkURL: nil, isTemplate: false)
                let view = RadialMenuView(slots: [try pictureItem(picture), .empty, .empty, .empty], mode: .runtime)
                view.applyAppearance(MenuAppearanceConfiguration(menuSize: size))
                let image = try XCTUnwrap(view.menuIconImage(at: 0), "\(name) \(size)")
                XCTAssertEqual(image.size.width, try XCTUnwrap(view.menuIcon(at: 0)).rect.width, accuracy: 0.5)
                let bitmap = try render(image, scale: 2)
                let row = bitmap.pixelsHigh / 2
                XCTAssertEqual(bitmap.colorAt(x: bitmap.pixelsWide / 4, y: row)?.alphaComponent ?? 0, 1, accuracy: 0.05)
                XCTAssertEqual(bitmap.colorAt(x: bitmap.pixelsWide * 3 / 4, y: row)?.alphaComponent ?? 1, 0, accuracy: 0.05)
                let blurred = (0..<bitmap.pixelsWide).filter {
                    let alpha = bitmap.colorAt(x: $0, y: row)?.alphaComponent ?? 0
                    return alpha > 0.1 && alpha < 0.9
                }
                XCTAssertLessThanOrEqual(blurred.count, 1, "\(name) \(size): edge spans \(blurred)")
            }
        }
    }

    func testAPictureGoneFromDiskDrawsTheNeutralSymbol() throws {
        let picture = MenuItemIcon.Picture(url: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)/mark.png"),
                                           darkURL: nil, isTemplate: false)
        let view = RadialMenuView(slots: [try pictureItem(picture)], mode: .runtime)
        let drawing = try XCTUnwrap(view.menuIcon(at: 0))
        XCTAssertNil(drawing.pictureURL)
        XCTAssertEqual(drawing.symbolName, MenuItemIcon.neutral.symbolName)
        XCTAssertNotNil(view.menuIconImage(at: 0))
    }

    private func render(_ image: NSImage, scale: CGFloat) throws -> NSBitmapImageRep {
        let width = Int((image.size.width * scale).rounded()), height = Int((image.size.height * scale).rounded())
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    func testVoiceOverKeepsReadingTitles() throws {
        let view = RadialMenuView(slots: [try iconicItem(), .empty], mode: .editor)
        view.selectEditorItem(at: 0)
        XCTAssertEqual(view.accessibilityValue() as? String, "Play Music")
    }
}
