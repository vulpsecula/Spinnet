import AppKit
import XCTest
import SpinnetCore
@testable import SpinnetHost

final class SelectedTextThreadingTests: XCTestCase {
    func testWorkerSelectionTraversesOwnTextControlOnlyOnMain() {
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        text.string = "a selected message here"
        text.setSelectedRange(NSRange(location: 2, length: 16))
        let fixture = SelectionAccessibilityFixture(text: text)
        let client = AppKitSelectedTextAXClient(accessibility: fixture.native)
        let done = expectation(description: "worker reads selected text")
        DispatchQueue.global().async {
            do { XCTAssertEqual(try SelectedTextLookup().read(using: client), "selected message") }
            catch { XCTFail("Selected text failed: \(error)") }
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
        XCTAssertGreaterThan(fixture.callbacks, 0)
        XCTAssertEqual(fixture.offMainCallbacks, 0, "Local AX text callbacks must run on main")
        XCTAssertEqual(fixture.arrayRequests, [1, 1], "Traversal remains bounded by the native child count")
        XCTAssertGreaterThan(fixture.timeoutCalls, 0)
    }

    func testGlobalFocusResultIsReclassifiedBeforeReadingLocalText() {
        let text = NSTextView()
        text.string = "a selected message here"
        text.setSelectedRange(NSRange(location: 2, length: 16))
        let fixture = SelectionAccessibilityFixture(text: text)
        fixture.directFocus = true
        let client = AppKitSelectedTextAXClient(accessibility: fixture.native)
        let done = expectation(description: "global result routed by its owner")
        DispatchQueue.global().async {
            do { XCTAssertEqual(try SelectedTextLookup().read(using: client), "selected message") }
            catch { XCTFail("Global focus selected text failed: \(error)") }
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(fixture.fieldCallbacks, 1)
        XCTAssertEqual(fixture.offMainCallbacks, 0)
        XCTAssertTrue(fixture.arrayRequests.isEmpty)
    }

    func testBlockedExternalSelectionLeavesMainResponsiveAndRunsOnWorker() {
        let fixture = SelectionAccessibilityFixture(text: NSTextView())
        fixture.owner = 1101
        let entered = expectation(description: "external AX read entered")
        let heartbeat = expectation(description: "main responds during blocked AX")
        let done = expectation(description: "external selection completes")
        let release = DispatchSemaphore(value: 0)
        fixture.beforeSelection = {
            fixture.beforeSelection = nil
            entered.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 3), .success)
        }
        let client = AppKitSelectedTextAXClient(accessibility: fixture.native)
        DispatchQueue.global().async {
            do { XCTAssertEqual(try SelectedTextLookup().read(using: client), "selected message") }
            catch { XCTFail("External selected text failed: \(error)") }
            done.fulfill()
        }
        wait(for: [entered], timeout: 3)
        DispatchQueue.main.async { heartbeat.fulfill(); release.signal() }
        wait(for: [heartbeat, done], timeout: 3)
        XCTAssertGreaterThan(fixture.callbacks, 0)
    }

    func testUnknownDescendantOwnershipFailsWithoutInvokingItsNativeCallbacks() {
        for invalidPID: pid_t? in [nil, 0] {
            let fixture = SelectionAccessibilityFixture(text: NSTextView())
            fixture.unknownField = true
            fixture.unknownPID = invalidPID
            let client = AppKitSelectedTextAXClient(accessibility: fixture.native)
            let done = expectation(description: "unknown descendant refused")
            DispatchQueue.global().async {
                do {
                    _ = try SelectedTextLookup().read(using: client)
                    XCTFail("Unknown descendant must fail")
                } catch {
                    guard case .failed = error as? PluginHostServiceError else {
                        XCTFail("Expected existing selected-text failure, got \(error)")
                        done.fulfill()
                        return
                    }
                }
                done.fulfill()
            }
            wait(for: [done], timeout: 3)
            XCTAssertGreaterThan(fixture.callbacks, 0, "Lookup reached known local ancestors")
            XCTAssertEqual(fixture.fieldCallbacks, 0, "Unknown child must not invoke reads, timeout, count or array callbacks")
            XCTAssertEqual(fixture.offMainCallbacks, 0)
        }
    }

    func testOwnSelectedTextReadAlreadyOnMainDoesNotDispatchSynchronouslyAgain() {
        let text = NSTextView()
        text.string = "a selected message here"
        text.setSelectedRange(NSRange(location: 2, length: 16))
        let fixture = SelectionAccessibilityFixture(text: text)
        let client = AppKitSelectedTextAXClient(accessibility: fixture.native)
        guard case .value(let value) = client.selectedText(in: fixture.field, messagingTimeout: 0.05) else {
            return XCTFail("Local selection was not returned")
        }
        XCTAssertEqual(value, "selected message")
        XCTAssertEqual(fixture.fieldCallbacks, 2)
        XCTAssertEqual(fixture.offMainCallbacks, 0)
    }
}

private final class SelectionAccessibilityFixture {
    let application = AXUIElementCreateApplication(1101)
    let window = AXUIElementCreateApplication(1102)
    let group = AXUIElementCreateApplication(1103)
    let field = AXUIElementCreateApplication(1104)
    private let text: NSTextView
    private let lock = NSLock()
    private(set) var callbacks = 0
    private(set) var offMainCallbacks = 0
    private(set) var timeoutCalls = 0
    private(set) var arrayRequests: [Int] = []
    var owner: pid_t? = ProcessInfo.processInfo.processIdentifier
    var directFocus = false
    var unknownField = false
    var unknownPID: pid_t?
    private(set) var fieldCallbacks = 0
    var beforeSelection: (() -> Void)?

    init(text: NSTextView) { self.text = text }
    private func callback(_ element: AXUIElement) {
        lock.lock(); defer { lock.unlock() }
        callbacks += 1
        if CFEqual(element, field) { fieldCallbacks += 1 }
        if owner == ProcessInfo.processInfo.processIdentifier, !Thread.isMainThread { offMainCallbacks += 1 }
        if let owner, owner != ProcessInfo.processInfo.processIdentifier {
            XCTAssertFalse(Thread.isMainThread, "External AX callbacks must stay on worker")
        }
    }
    var native: HostAccessibility.Native {
        var native = HostAccessibility.Native()
        let systemWide = native.systemWide
        native.processIdentifier = { [self] element in unknownField && CFEqual(element, field) ? unknownPID : owner }
        native.copy = { [self] element, attribute in
            if CFEqual(element, systemWide) {
                XCTAssertFalse(Thread.isMainThread, "Global server query stays on worker")
                if directFocus, attribute as String == kAXFocusedUIElementAttribute { return (.success, field) }
                return attribute as String == kAXFocusedApplicationAttribute ? (.success, application) : (.noValue, nil)
            }
            callback(element)
            switch attribute as String {
            case kAXFocusedUIElementAttribute: return (.noValue, nil)
            case kAXFocusedWindowAttribute: return (.success, window)
            case kAXSelectedTextAttribute:
                beforeSelection?()
                guard CFEqual(element, field) else { return (.attributeUnsupported, nil) }
                // A guarded real AppKit text callback catches thread violations
                // without sending unsafe calls into AppKit on the red run.
                if Thread.isMainThread {
                    return (.success, (text.string as NSString).substring(with: text.selectedRange()) as CFString)
                }
                return (.success, "selected message" as CFString)
            default: return (.attributeUnsupported, nil)
            }
        }
        native.timeout = { [self] element, _ in callback(element); timeoutCalls += 1; return .success }
        native.count = { [self] element, _ in callback(element); return (.success, 1) }
        native.values = { [self] element, _, count in
            callback(element); arrayRequests.append(count)
            return (.success, [CFEqual(element, window) ? group : field] as CFArray)
        }
        return native
    }
}
