import AppKit
import XCTest
@testable import SpinnetCore
@testable import SpinnetHost

/// The Current App's icon for the Menu's centre (#111): looked up once per
/// App and cached, read away from the main thread so the Menu never waits
/// for it, and handed back on the main thread when it arrives.
final class CurrentAppIconsTests: XCTestCase {
    private var loads: [String] = []
    private var background: [() -> Void] = []
    private var main: [() -> Void] = []

    private func icons() -> CurrentAppIcons {
        CurrentAppIcons(environment: .init(
            load: { [unowned self] app in
                loads.append(app.name)
                return NSImage(size: NSSize(width: 16, height: 16))
            },
            background: { [unowned self] in background.append($0) },
            main: { [unowned self] in main.append($0) }))
    }

    private func app(_ pid: Int32, _ bundle: String?, _ name: String) -> CurrentApp {
        CurrentApp(identity: RunningAppIdentity(processIdentifier: pid, bundleIdentifier: bundle,
                                                launchDate: Date(timeIntervalSince1970: 1), name: name),
                   bundleURL: nil)
    }

    private func drain() {
        while !background.isEmpty || !main.isEmpty {
            if !background.isEmpty { background.removeFirst()() }
            while !main.isEmpty { main.removeFirst()() }
        }
    }

    func testAnUncachedIconIsLoadedInTheBackgroundAndDeliveredOnMain() {
        let icons = icons()
        var delivered: [NSImage] = []
        XCTAssertNil(icons.icon(for: app(43, "com.apple.Safari", "Safari")) { delivered.append($0) })
        XCTAssertEqual(loads, [], "The lookup must not load on the invoking thread")
        XCTAssertEqual(background.count, 1)

        background.removeFirst()()
        XCTAssertEqual(loads, ["Safari"])
        XCTAssertEqual(delivered.count, 0, "Delivery happens on the main thread")
        main.removeFirst()()
        XCTAssertEqual(delivered.count, 1)
    }

    func testAnAppsIconIsLoadedOnceAndCachedAcrossInvocationsAndRelaunches() {
        let icons = icons()
        icons.prefetch(app(43, "com.apple.Safari", "Safari"))
        XCTAssertNil(icons.icon(for: app(43, "com.apple.Safari", "Safari")) { _ in })
        drain()
        XCTAssertEqual(loads, ["Safari"], "A lookup while loading waits for the same load")

        XCTAssertNotNil(icons.icon(for: app(43, "com.apple.Safari", "Safari")) { _ in XCTFail() })
        XCTAssertNotNil(icons.icon(for: app(99, "com.apple.Safari", "Safari")) { _ in XCTFail() })
        XCTAssertTrue(background.isEmpty)
        XCTAssertEqual(loads, ["Safari"])

        XCTAssertNil(icons.icon(for: app(45, "com.apple.finder", "Finder")) { _ in })
        drain()
        XCTAssertEqual(loads, ["Safari", "Finder"])
    }
}
