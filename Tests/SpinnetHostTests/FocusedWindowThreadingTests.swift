import AppKit
import XCTest
import SpinnetCore
@testable import SpinnetHost

final class FocusedWindowThreadingTests: XCTestCase {
    func testWorkerWindowServicesRunLocalAppKitCallbacksOnMainAndPreserveRestore() throws {
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 400, height: 300),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.setFrame(NSRect(x: 80, y: 80, width: 400, height: 300), display: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let fixture = WindowAccessibilityFixture(local: true, window: window)
        let sweep = expectation(description: "closed-window sweep uses same local routing")
        fixture.sweep = sweep
        let provider = AppKitPluginHostServiceProvider(accessibility: fixture.environment)
        let completed = expectation(description: "worker window services complete")
        let heartbeat = expectation(description: "main stays available during worker operation")
        DispatchQueue.global().async {
            defer { completed.fulfill() }
            do {
                let original = try provider.readFocusedWindow().frame
                let moved = WindowRect(x: original.x + 20, y: original.y + 20, width: 420, height: 320)
                try provider.setFocusedWindowFrame(moved)
                XCTAssertEqual(try provider.readFocusedWindow().frame, moved)
                try provider.restoreFocusedWindowFrame()
                XCTAssertEqual(try provider.readFocusedWindow().frame, original)
                try provider.toggleFocusedWindowFullScreen()
            } catch { XCTFail("Window service failed: \(error)") }
        }
        DispatchQueue.main.async { heartbeat.fulfill() }
        wait(for: [completed, heartbeat, sweep], timeout: 5)
        XCTAssertGreaterThan(fixture.localCallbacks, 0)
        XCTAssertEqual(fixture.offMainLocalCallbacks, 0,
            "Local AX window callbacks can enter AppKit and must never run on a Plugin worker")
        XCTAssertEqual(window.frame.size, NSSize(width: 400, height: 300))
    }
}

private final class WindowAccessibilityFixture {
    private let lock = NSLock()
    private let local: Bool
    private let window: NSWindow?
    let application = AXUIElementCreateApplication(1001)
    let element = AXUIElementCreateApplication(2001)
    private var frame = WindowRect(x: 80, y: 80, width: 400, height: 300)
    private var fullScreen = false
    var sweep: XCTestExpectation?
    var beforeCopy: ((String) -> Void)?
    var unknownOwner = false
    var systemFocusMissing = false
    var failPositionOnce = false
    var focusedElement: AXUIElement?
    private(set) var localCallbacks = 0
    private(set) var offMainLocalCallbacks = 0

    init(local: Bool, window: NSWindow? = nil) { self.local = local; self.window = window }
    private func callback() {
        lock.lock(); defer { lock.unlock() }
        if local {
            localCallbacks += 1
            if !Thread.isMainThread { offMainLocalCallbacks += 1 }
        } else { XCTAssertFalse(Thread.isMainThread, "External application AX must stay on worker") }
    }
    var environment: AppKitPluginHostServiceProvider.Accessibility {
        var environment = AppKitPluginHostServiceProvider.Accessibility()
        environment.trusted = { true }
        environment.frontmost = { 1001 }
        environment.processIdentifier = { [self] _ in unknownOwner ? nil : (local ? ProcessInfo.processInfo.processIdentifier : 1001) }
        let systemWide = environment.systemWide
        environment.copy = { [self] target, attribute in
            if CFEqual(target, systemWide) {
                XCTAssertFalse(Thread.isMainThread, "System-wide focus lookup must stay on worker")
                return systemFocusMissing ? (.noValue, nil) : (.success, application)
            }
            beforeCopy?(attribute as String)
            callback()
            switch attribute as String {
            case kAXFocusedWindowAttribute: return (.success, focusedElement ?? element)
            case kAXPositionAttribute:
                var point = CGPoint(x: frame.x, y: frame.y); return (.success, AXValueCreate(.cgPoint, &point))
            case kAXSizeAttribute:
                var size = CGSize(width: frame.width, height: frame.height); return (.success, AXValueCreate(.cgSize, &size))
            case "AXFullScreen": return (.success, fullScreen ? kCFBooleanTrue : kCFBooleanFalse)
            case kAXRoleAttribute: sweep?.fulfill(); return (.success, kAXWindowRole as CFString)
            default: return (.attributeUnsupported, nil)
            }
        }
        environment.settable = { [self] _, _ in callback(); return (.success, true) }
        environment.timeout = { [self] _, _ in callback(); return .success }
        environment.set = { [self] _, attribute, value in
            callback()
            switch attribute as String {
            case kAXPositionAttribute:
                if failPositionOnce { failPositionOnce = false; return .cannotComplete }
                var point = CGPoint.zero; AXValueGetValue((value as! AXValue), .cgPoint, &point)
                frame = WindowRect(x: point.x, y: point.y, width: frame.width, height: frame.height)
            case kAXSizeAttribute:
                var size = CGSize.zero; AXValueGetValue((value as! AXValue), .cgSize, &size)
                frame = WindowRect(x: frame.x, y: frame.y, width: size.width, height: size.height)
            case "AXFullScreen": fullScreen = CFBooleanGetValue((value as! CFBoolean))
            default: return .attributeUnsupported
            }
            // Only execute AppKit when safe; the recorded violation makes the
            // original implementation fail without wedging the test process.
            if Thread.isMainThread, let window, attribute as String != "AXFullScreen" {
                window.setFrame(NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height), display: false)
            }
            return .success
        }
        return environment
    }
}


extension FocusedWindowThreadingTests {
    func testExternalWindowCallbacksStayOnWorkerAndBlockedReadLeavesMainResponsive() throws {
        let fixture = WindowAccessibilityFixture(local: false)
        let entered = expectation(description: "external read entered")
        let finished = expectation(description: "external worker complete")
        let heartbeat = expectation(description: "main heartbeat while external AX blocked")
        let release = DispatchSemaphore(value: 0)
        fixture.beforeCopy = { attribute in
            if attribute == kAXPositionAttribute {
                entered.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 3), .success)
                fixture.beforeCopy = nil
            }
        }
        let provider = AppKitPluginHostServiceProvider(accessibility: fixture.environment)
        DispatchQueue.global().async {
            do {
                _ = try provider.readFocusedWindow()
                try provider.setFocusedWindowFrame(WindowRect(x: 100, y: 100, width: 420, height: 320))
                try provider.restoreFocusedWindowFrame()
                try provider.toggleFocusedWindowFullScreen()
            } catch { XCTFail("External services: \(error)") }
            finished.fulfill()
        }
        wait(for: [entered], timeout: 3)
        DispatchQueue.main.async { heartbeat.fulfill(); release.signal() }
        wait(for: [heartbeat, finished], timeout: 5)
    }

    func testUnknownOwnerNeverExecutesPotentialLocalCallback() {
        let fixture = WindowAccessibilityFixture(local: true)
        fixture.unknownOwner = true
        let provider = AppKitPluginHostServiceProvider(accessibility: fixture.environment)
        let done = expectation(description: "unknown owner refused")
        DispatchQueue.global().async {
            do { _ = try provider.readFocusedWindow(); XCTFail("Unknown owner must be refused") }
            catch { XCTAssertEqual(error as? PluginHostServiceError, .unavailable("No focused window")) }
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(fixture.localCallbacks, 0)
    }

    func testMissingGlobalFocusFallbackStillRoutesOwnWindowAndRejectsIdentityChange() throws {
        let fixture = WindowAccessibilityFixture(local: true)
        fixture.systemFocusMissing = true
        let provider = AppKitPluginHostServiceProvider(accessibility: fixture.environment)
        let done = expectation(description: "fallback and focused identity preserved")
        DispatchQueue.global().async {
            do {
                _ = try provider.readFocusedWindow()
                fixture.focusedElement = AXUIElementCreateApplication(2002)
                XCTAssertThrowsError(try provider.setFocusedWindowFrame(WindowRect(x: 100, y: 100, width: 420, height: 320))) { error in
                    XCTAssertEqual(error as? PluginHostServiceError, .unavailable("The focused window changed after it was read"))
                }
            } catch { XCTFail("Focused read: \(error)") }
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(fixture.offMainLocalCallbacks, 0)
    }

    func testPartialLocalWriteRollsBackOriginalFrameOnMain() throws {
        let fixture = WindowAccessibilityFixture(local: true)
        let provider = AppKitPluginHostServiceProvider(accessibility: fixture.environment)
        let done = expectation(description: "partial write rolls back")
        DispatchQueue.global().async {
            do {
                let original = try provider.readFocusedWindow().frame
                fixture.failPositionOnce = true
                XCTAssertThrowsError(try provider.setFocusedWindowFrame(WindowRect(x: 100, y: 100, width: 420, height: 320)))
                XCTAssertEqual(try provider.readFocusedWindow().frame, original)
            } catch { XCTFail("Local rollback: \(error)") }
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(fixture.offMainLocalCallbacks, 0)
    }
}
