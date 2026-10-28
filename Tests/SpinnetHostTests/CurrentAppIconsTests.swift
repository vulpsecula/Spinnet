import AppKit
import XCTest
@testable import SpinnetCore
@testable import SpinnetHost

/// The Current App's icon for the Menu's centre (#111): read the first time
/// the Menu is invoked over that App, away from the main thread and already
/// drawn at the size the centre needs, so the Menu never waits for it; handed
/// back on the main thread; kept for a few recent Apps only (ADR 0004), and
/// remembered as missing when an App has none, so it is not read again.
final class CurrentAppIconsTests: XCTestCase {
    private var loads: [String] = []
    private var background: [() -> Void] = []
    private var main: [() -> Void] = []
    /// The Apps whose icon reads find none.
    private var missing: Set<String> = []

    private func icons() -> CurrentAppIcons {
        CurrentAppIcons(environment: .init(
            load: { [unowned self] app, side in
                loads.append("\(app.name)@\(side)")
                return missing.contains(app.name) ? nil : NSImage(size: NSSize(width: side, height: side))
            },
            background: { [unowned self] in background.append($0) },
            main: { [unowned self] in main.append($0) }))
    }

    private func app(_ pid: Int32, _ bundle: String?, _ name: String, launched: TimeInterval = 1,
                     at path: String? = nil) -> CurrentApp {
        CurrentApp(identity: RunningAppIdentity(processIdentifier: pid, bundleIdentifier: bundle,
                                                launchDate: Date(timeIntervalSince1970: launched), name: name),
                   bundleURL: path.map { URL(fileURLWithPath: $0) })
    }

    private func drain() {
        while !background.isEmpty || !main.isEmpty {
            if !background.isEmpty { background.removeFirst()() }
            while !main.isEmpty { main.removeFirst()() }
        }
    }

    /// Looks `app` up and lets any read finish; the icon a later lookup finds.
    @discardableResult
    private func lookUp(_ app: CurrentApp, in icons: CurrentAppIcons, side: Int = 64) -> NSImage? {
        let found = icons.icon(for: app, pixelSide: side) { _ in }
        drain()
        return found
    }

    func testAnUncachedIconIsLoadedInTheBackgroundAndDeliveredOnMain() {
        let icons = icons()
        var delivered: [NSImage] = []
        XCTAssertNil(icons.icon(for: app(43, "com.apple.Safari", "Safari"), pixelSide: 64) { delivered.append($0) })
        XCTAssertEqual(loads, [], "The lookup must not load on the invoking thread")
        XCTAssertEqual(background.count, 1)

        background.removeFirst()()
        XCTAssertEqual(loads, ["Safari@64"], "Read at the size the centre draws it")
        XCTAssertEqual(delivered.count, 0, "Delivery happens on the main thread")
        main.removeFirst()()
        XCTAssertEqual(delivered.count, 1)
    }

    func testAnAppsIconIsLoadedOnceAndCachedAcrossInvocations() {
        let icons = icons()
        XCTAssertNil(icons.icon(for: app(43, "com.apple.Safari", "Safari"), pixelSide: 64) { _ in })
        XCTAssertNil(icons.icon(for: app(43, "com.apple.Safari", "Safari"), pixelSide: 64) { _ in })
        drain()
        XCTAssertEqual(loads, ["Safari@64"], "A lookup while loading waits for the same load")

        XCTAssertNotNil(icons.icon(for: app(43, "com.apple.Safari", "Safari"), pixelSide: 64) { _ in XCTFail() })
        XCTAssertTrue(background.isEmpty)

        lookUp(app(45, "com.apple.finder", "Finder"), in: icons)
        XCTAssertEqual(loads, ["Safari@64", "Finder@64"])
    }

    /// An update reaches a running App only when it is launched again, and
    /// may move its bundle; either reads the icon again. So does a centre of
    /// another size.
    func testANewLaunchAMovedBundleOrAnotherSizeReadsTheIconAgain() {
        let icons = icons()
        lookUp(app(43, "com.apple.Safari", "Safari", at: "/Applications/Safari.app"), in: icons)
        XCTAssertNotNil(lookUp(app(43, "com.apple.Safari", "Safari", at: "/Applications/Safari.app"), in: icons))
        XCTAssertNil(lookUp(app(99, "com.apple.Safari", "Safari", launched: 5, at: "/Applications/Safari.app"), in: icons))
        XCTAssertNil(lookUp(app(99, "com.apple.Safari", "Safari", launched: 5, at: "/Applications/Old/Safari.app"),
                            in: icons))
        XCTAssertNil(lookUp(app(99, "com.apple.Safari", "Safari", launched: 5, at: "/Applications/Old/Safari.app"),
                            in: icons, side: 128))
        XCTAssertEqual(loads, ["Safari@64", "Safari@64", "Safari@64", "Safari@128"])
    }

    func testAnAppWithoutAnIconIsNotReadAgain() {
        missing = ["Helper"]
        let icons = icons()
        var delivered = 0
        XCTAssertNil(icons.icon(for: app(50, "com.example.helper", "Helper"), pixelSide: 64) { _ in delivered += 1 })
        drain()
        XCTAssertNil(icons.icon(for: app(50, "com.example.helper", "Helper"), pixelSide: 64) { _ in delivered += 1 })
        XCTAssertTrue(background.isEmpty, "A known missing icon starts no read")
        XCTAssertEqual(loads, ["Helper@64"])
        XCTAssertEqual(delivered, 0)
    }

    /// Only the most recently shown Apps keep their icons in memory.
    func testOnlyTheMostRecentlyShownAppsKeepTheirIcons() {
        let icons = icons()
        let apps = (0...CurrentAppIcons.capacity).map { app(Int32(100 + $0), "com.example.\($0)", "App\($0)") }
        for app in apps.prefix(CurrentAppIcons.capacity) { lookUp(app, in: icons) }
        XCTAssertNotNil(lookUp(apps[0], in: icons), "App0 shown again, so App1 is now the oldest")
        lookUp(apps[CurrentAppIcons.capacity], in: icons)
        loads = []

        XCTAssertNotNil(lookUp(apps[0], in: icons))
        XCTAssertNil(lookUp(apps[1], in: icons), "The least recently shown App's icon was dropped")
        XCTAssertEqual(loads, ["App1@64"])
    }

    /// The live read draws the icon into a bitmap of the requested size, so
    /// the Menu's first draw does not render the icon file on the main thread.
    func testTheLiveReadDrawsTheIconIntoABitmapOfTheCentresSize() throws {
        let finder = app(1, "com.apple.finder", "Finder", at: "/System/Library/CoreServices/Finder.app")
        let icon = try XCTUnwrap(CurrentAppIcons.Environment.live.load(finder, 96))
        XCTAssertEqual(icon.representations.count, 1)
        let bitmap = try XCTUnwrap(icon.representations.first as? NSBitmapImageRep)
        XCTAssertEqual(bitmap.pixelsWide, 96)
        XCTAssertEqual(bitmap.pixelsHigh, 96)
    }
}
