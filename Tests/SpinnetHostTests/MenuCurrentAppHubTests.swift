import AppKit
import XCTest
@testable import SpinnetCore
@testable import SpinnetHost

/// The Menu's centre in Runtime Mode shows the Current App's icon (#111):
/// fitted to the centre at every Menu Size and theme, named to VoiceOver,
/// with the centre's press unchanged. Without a Current App it keeps
/// "Spinnet"; Editor Mode keeps "MENU". The Current App is resolved at each
/// invocation, and an icon that arrives late never reaches a Menu opened
/// for another App.
final class MenuCurrentAppHubTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private static let safari = CurrentApp(
        identity: RunningAppIdentity(processIdentifier: 43, bundleIdentifier: "com.apple.Safari",
                                     launchDate: Date(timeIntervalSince1970: 1), name: "Safari"),
        bundleURL: nil)
    private static let finder = CurrentApp(
        identity: RunningAppIdentity(processIdentifier: 45, bundleIdentifier: "com.apple.finder",
                                     launchDate: Date(timeIntervalSince1970: 2), name: "Finder"),
        bundleURL: nil)

    /// A solid red square, unmistakable in a rendered Menu.
    private static func redIcon() -> NSImage {
        NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).setFill()
            rect.fill()
            return true
        }
    }

    private func isRed(atCentreOf view: NSView) throws -> Bool {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
        let colour = try XCTUnwrap(bitmap.colorAt(x: Int(view.bounds.midX * scale), y: Int(view.bounds.midY * scale))?
            .usingColorSpace(.sRGB))
        return colour.redComponent > 0.9 && colour.greenComponent < 0.2 && colour.blueComponent < 0.2
    }

    /// Icons answered at once, as when cached.
    private static func immediateIcons(_ loads: @escaping (CurrentApp, Int) -> NSImage? = { _, _ in redIcon() }) -> CurrentAppIcons {
        CurrentAppIcons(environment: .init(load: loads, background: { $0() }, main: { $0() }))
    }

    func testTheCurrentAppsIconFitsTheCentreAtEveryMenuSizeAndTheme() throws {
        let sizes = MenuAppearanceConfiguration.menuSizeOptions + ["50", "200"]
        for size in sizes {
            for theme in MenuAppearanceConfiguration.themeOptions {
                for slotCount in [1, 6, 12] {
                    let view = RadialMenuView(slots: Array(repeating: .empty, count: slotCount))
                    view.applyAppearance(MenuAppearanceConfiguration(theme: theme, menuSize: size))
                    view.showCurrentApp(Self.safari, icon: Self.redIcon())
                    let context = "\(size) \(theme) \(slotCount)"

                    let icon = try XCTUnwrap(view.hubIconRect, context)
                    let centre = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
                    let inner = view.geometryLayout.innerRadius
                    XCTAssertEqual(icon.midX, centre.x, accuracy: 0.5, context)
                    XCTAssertEqual(icon.midY, centre.y, accuracy: 0.5, context)
                    XCTAssertEqual(icon.width, icon.height, context)
                    XCTAssertLessThanOrEqual(hypot(icon.width, icon.height) / 2, inner, "fits the centre: \(context)")
                    XCTAssertGreaterThanOrEqual(icon.width, inner, "fills the centre: \(context)")
                    XCTAssertTrue(try isRed(atCentreOf: view), "draws the icon: \(context)")
                }
            }
        }
    }

    func testTheCentreNamesTheCurrentAppToVoiceOver() {
        let view = RadialMenuView(slots: [.empty, .empty])
        XCTAssertEqual(view.accessibilityLabel(), "Spinnet Menu")
        view.showCurrentApp(Self.safari, icon: Self.redIcon())
        XCTAssertEqual(view.accessibilityLabel(), "Spinnet Menu for Safari")
        view.showCurrentApp(Self.finder, icon: nil)
        XCTAssertEqual(view.accessibilityLabel(), "Spinnet Menu for Finder")
        view.showCurrentApp(nil, icon: nil)
        XCTAssertEqual(view.accessibilityLabel(), "Spinnet Menu")
    }

    func testWithoutACurrentAppTheCentreKeepsSpinnet() throws {
        let view = RadialMenuView(slots: [.empty, .empty, .empty])
        view.showCurrentApp(Self.safari, icon: Self.redIcon())
        view.showCurrentApp(nil, icon: nil)
        XCTAssertNil(view.hubIconRect)
        XCTAssertEqual(view.hubLabel, "Spinnet")
        XCTAssertFalse(try isRed(atCentreOf: view))
    }

    func testEditorModeKeepsMenuInTheCentre() throws {
        let view = RadialMenuView(slots: [.empty, .empty, .empty], mode: .editor)
        view.showCurrentApp(Self.safari, icon: Self.redIcon())
        XCTAssertNil(view.hubIconRect)
        XCTAssertEqual(view.hubLabel, "MENU")
        XCTAssertEqual(view.accessibilityLabel(), "Editor Mode Menu")
        XCTAssertFalse(try isRed(atCentreOf: view))
    }

    /// Each invocation shows the App in front then; a press in the centre
    /// still closes the Menu.
    func testEachInvocationShowsItsCurrentAppAndAPressInTheCentreStillCloses() throws {
        let menu = MenuPresentationController(items: [.empty, .empty, .empty], icons: Self.immediateIcons())
        defer { menu.dismiss() }
        let screen = try XCTUnwrap(NSScreen.main)
        let point = CGPoint(x: screen.frame.midX, y: screen.frame.midY)

        menu.open(at: point, currentApp: Self.safari)
        XCTAssertEqual(menu.hubSnapshot, .init(appName: "Safari", showsIcon: true, label: nil))
        let panel = try XCTUnwrap(NSApp.windows.first { $0.level == .popUpMenu && $0.isVisible })
        try press(at: NSPoint(x: panel.frame.width / 2, y: panel.frame.height / 2), in: panel)
        XCTAssertFalse(menu.isOpen)

        menu.open(at: point, currentApp: nil)
        XCTAssertEqual(menu.hubSnapshot, .init(appName: nil, showsIcon: false, label: "Spinnet"))
    }

    /// The Menu opens at once while an uncached icon is read; the icon
    /// joins the Menu when it arrives, unless the Menu has since opened for
    /// another App.
    func testAnUncachedIconNeverDelaysTheMenuAndALateOneGoesOnlyToItsApp() throws {
        var background: [() -> Void] = []
        let icons = CurrentAppIcons(environment: .init(load: { _, _ in Self.redIcon() },
                                                       background: { background.append($0) }, main: { $0() }))
        let menu = MenuPresentationController(items: [.empty, .empty], icons: icons)
        defer { menu.dismiss() }
        let screen = try XCTUnwrap(NSScreen.main)
        let point = CGPoint(x: screen.frame.midX, y: screen.frame.midY)

        menu.open(at: point, currentApp: Self.safari)
        XCTAssertTrue(menu.isOpen)
        XCTAssertEqual(menu.hubSnapshot, .init(appName: "Safari", showsIcon: false, label: "Spinnet"),
                       "The centre is never blank while the icon is read")
        background.removeFirst()()
        XCTAssertEqual(menu.hubSnapshot, .init(appName: "Safari", showsIcon: true, label: nil))

        menu.dismiss()
        menu.open(at: point, currentApp: Self.finder)
        menu.dismiss()
        menu.open(at: point, currentApp: nil)
        background.removeFirst()()
        XCTAssertEqual(menu.hubSnapshot, .init(appName: nil, showsIcon: false, label: "Spinnet"))
    }

    /// An App without an icon keeps "Spinnet" in the centre, and its icon
    /// is not read again at the next invocation.
    func testAnAppWithoutAnIconKeepsSpinnetInTheCentre() throws {
        var reads = 0
        let menu = MenuPresentationController(items: [.empty, .empty], icons: Self.immediateIcons { _, _ in
            reads += 1
            return nil
        })
        defer { menu.dismiss() }
        let screen = try XCTUnwrap(NSScreen.main)
        let point = CGPoint(x: screen.frame.midX, y: screen.frame.midY)

        menu.open(at: point, currentApp: Self.safari)
        XCTAssertEqual(menu.hubSnapshot, .init(appName: "Safari", showsIcon: false, label: "Spinnet"))
        menu.dismiss()
        menu.open(at: point, currentApp: Self.safari)
        XCTAssertEqual(menu.hubSnapshot, .init(appName: "Safari", showsIcon: false, label: "Spinnet"))
        XCTAssertEqual(reads, 1)
    }

    /// The icon is read at the size the centre draws it on the Menu's
    /// screen, so drawing it scales nothing.
    func testTheIconIsReadAtTheCentresPixelSize() throws {
        var sides: [Int] = []
        let menu = MenuPresentationController(items: [.empty, .empty], icons: Self.immediateIcons { _, side in
            sides.append(side)
            return Self.redIcon()
        })
        defer { menu.dismiss() }
        let screen = try XCTUnwrap(NSScreen.main)
        menu.open(at: CGPoint(x: screen.frame.midX, y: screen.frame.midY), currentApp: Self.safari)
        let view = RadialMenuView(slots: [.empty, .empty])
        let side = try XCTUnwrap(view.hubIconSide)
        XCTAssertEqual(sides, [Int((side * screen.backingScaleFactor).rounded(.up))])
    }

    /// The centre is its own element to VoiceOver, named after the Current
    /// App whether its icon or "Spinnet" is drawn, and placed over the centre.
    func testTheCentreIsAnAccessibilityElementNamingTheCurrentApp() throws {
        let view = RadialMenuView(slots: [.empty, .empty, .empty])
        func centre() throws -> NSAccessibilityElement {
            let elements = (view.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
            XCTAssertEqual(elements.count, 1)
            return try XCTUnwrap(elements.first)
        }
        XCTAssertEqual(try centre().accessibilityLabel(), "Spinnet")

        view.showCurrentApp(Self.safari, icon: nil)
        XCTAssertEqual(try centre().accessibilityLabel(), "Safari")
        XCTAssertEqual(try centre().accessibilityRole(), .staticText)

        view.showCurrentApp(Self.safari, icon: Self.redIcon())
        XCTAssertEqual(try centre().accessibilityLabel(), "Safari")
        XCTAssertEqual(try centre().accessibilityRole(), .image)
        let frame = try centre().accessibilityFrameInParentSpace()
        let icon = try XCTUnwrap(view.hubIconRect)
        XCTAssertTrue(frame.contains(icon), "\(frame) covers the drawn icon \(icon)")
        XCTAssertEqual(frame.midX, view.bounds.midX, accuracy: 0.5)
        XCTAssertEqual(frame.midY, view.bounds.midY, accuracy: 0.5)
        XCTAssertEqual(view.accessibilityLabel(), "Spinnet Menu for Safari")

        view.showCurrentApp(nil, icon: nil)
        XCTAssertEqual(try centre().accessibilityLabel(), "Spinnet")

        let editor = RadialMenuView(slots: [.empty, .empty, .empty], mode: .editor)
        XCTAssertFalse((editor.accessibilityChildren() ?? []).contains { $0 is NSAccessibilityElement })
    }

    private func press(at point: NSPoint, in window: NSWindow) throws {
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        NSApp.postEvent(event, atStart: false)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline,
              let next = NSApp.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
            NSApp.sendEvent(next)
            if next.type == .leftMouseDown { break }
        }
    }
}
