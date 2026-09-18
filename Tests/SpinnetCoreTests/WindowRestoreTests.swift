import XCTest
@testable import SpinnetCore

/// Restore returns the focused window to where it was before Spinnet last
/// moved it. The Host remembers those frames; the Plugin never sees a window.
final class WindowRestoreTests: XCTestCase {

    private let original = WindowRect(x: 100, y: 120, width: 600, height: 400)
    private let maximised = WindowRect(x: 0, y: 25, width: 1440, height: 875)
    private let leftHalf = WindowRect(x: 0, y: 25, width: 720, height: 875)

    // MARK: - Remembered frames

    func testAWindowSpinnetNeverMovedHasNothingToRestore() {
        let frames = RememberedWindowFrames<String>()
        XCTAssertNil(frames.frameToRestore(for: "finder"))
    }

    func testConsecutiveLayoutsKeepTheFrameFromBeforeTheFirst() {
        var frames = RememberedWindowFrames<String>()
        frames.recordMove(of: "finder", from: original, to: maximised)
        frames.recordMove(of: "finder", from: maximised, to: leftHalf)
        XCTAssertEqual(frames.frameToRestore(for: "finder"), original)
    }

    /// A window the user moved after a layout is remembered from where the
    /// user left it, not from where Spinnet first found it.
    func testALayoutAfterTheUserMovedTheWindowRemembersTheUsersFrame() {
        var frames = RememberedWindowFrames<String>()
        let userMoved = WindowRect(x: 300, y: 300, width: 500, height: 500)
        frames.recordMove(of: "finder", from: original, to: maximised)
        frames.recordMove(of: "finder", from: userMoved, to: leftHalf)
        XCTAssertEqual(frames.frameToRestore(for: "finder"), userMoved)
    }

    func testEachWindowKeepsItsOwnFrame() {
        var frames = RememberedWindowFrames<String>()
        let other = WindowRect(x: 50, y: 60, width: 300, height: 200)
        frames.recordMove(of: "finder", from: original, to: maximised)
        frames.recordMove(of: "safari", from: other, to: maximised)
        XCTAssertEqual(frames.frameToRestore(for: "finder"), original)
        XCTAssertEqual(frames.frameToRestore(for: "safari"), other)
    }

    func testARestoredOrClosedWindowIsForgotten() {
        var frames = RememberedWindowFrames<String>()
        frames.recordMove(of: "finder", from: original, to: maximised)
        frames.recordMove(of: "safari", from: original, to: maximised)
        frames.recordMove(of: "notes", from: original, to: maximised)
        frames.forget("finder")
        frames.forget { $0 == "safari" }
        XCTAssertNil(frames.frameToRestore(for: "finder"))
        XCTAssertNil(frames.frameToRestore(for: "safari"))
        XCTAssertEqual(frames.frameToRestore(for: "notes"), original)
        XCTAssertEqual(frames.windows, ["notes"])
    }

    /// Only the most recently moved windows are kept; moving a window again
    /// makes it the most recent.
    func testOnlyTheMostRecentlyMovedWindowsAreKept() {
        var frames = RememberedWindowFrames<Int>(capacity: 3)
        for window in 1...3 { frames.recordMove(of: window, from: original, to: maximised) }
        frames.recordMove(of: 1, from: maximised, to: leftHalf)
        frames.recordMove(of: 4, from: original, to: maximised)
        XCTAssertEqual(frames.windows, [3, 1, 4])
        XCTAssertNil(frames.frameToRestore(for: 2))
        XCTAssertEqual(frames.frameToRestore(for: 1), original)
        XCTAssertEqual(RememberedWindowFrames<Int>().capacity, 50)
    }

    // MARK: - Broker

    func testRestoringRequiresTheGrantAndAccessibility() throws {
        let package = try loadWindowPosition()
        let action = try restoreAction(in: package)
        let grants = PluginCapabilityGrantStore()
        var accessibility = true
        var restores = 0
        let broker = makeBroker(grants: grants, accessibility: { accessibility }, restore: { restores += 1 })

        XCTAssertThrowsError(try broker.execute(request: request(.null, action), for: package, action: action)) {
            XCTAssertEqual($0 as? PluginHostServiceError, .capabilityDenied(.positionFocusedWindow))
        }
        grant(package, in: grants)
        accessibility = false
        XCTAssertThrowsError(try broker.execute(request: request(.null, action), for: package, action: action)) {
            XCTAssertEqual($0 as? PluginHostServiceError, .systemPermissionDenied(.accessibility))
        }
        XCTAssertEqual(restores, 0)

        accessibility = true
        XCTAssertEqual(try broker.execute(request: request(.null, action), for: package, action: action), .null)
        XCTAssertEqual(restores, 1)
    }

    /// The Plugin names no window and no frame; any input is refused before
    /// the Host touches a window.
    func testRestoringAcceptsOnlyNull() throws {
        let package = try loadWindowPosition()
        let action = try restoreAction(in: package)
        let grants = PluginCapabilityGrantStore()
        grant(package, in: grants)
        var restores = 0
        let broker = makeBroker(grants: grants, accessibility: { true }, restore: { restores += 1 })
        let invalid: [JSONValue] = [
            .object([:]),
            .string("finder"),
            .object(["x": .number(0), "y": .number(0), "width": .number(10), "height": .number(10)])
        ]
        for input in invalid {
            XCTAssertThrowsError(try broker.execute(request: request(input, action), for: package, action: action)) { error in
                guard case .invalidInput = error as? PluginHostServiceError else {
                    return XCTFail("Expected invalid input for \(input), got \(error)")
                }
            }
        }
        XCTAssertEqual(restores, 0)
    }

    func testNothingToRestoreReachesThePluginAsAStableFailure() throws {
        let package = try loadWindowPosition()
        let action = try restoreAction(in: package)
        let grants = PluginCapabilityGrantStore()
        grant(package, in: grants)
        let broker = makeBroker(grants: grants, accessibility: { true }, restore: {
            throw PluginHostServiceError.nothingToRestore
        })
        XCTAssertThrowsError(try broker.execute(request: request(.null, action), for: package, action: action)) {
            XCTAssertEqual($0 as? PluginHostServiceError, .nothingToRestore)
            XCTAssertEqual(($0 as? PluginHostServiceError)?.runtimeFailureCategory, .hostServiceFailed)
        }
        XCTAssertEqual(PluginHostServiceError.nothingToRestore,
                       .unavailable("Spinnet has not moved the focused window, so there is nothing to restore"))
    }

    // MARK: - Support

    private func loadWindowPosition() throws -> PluginPackage {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let loaded = try PluginManifestLoader.load(packageAt: root.appendingPathComponent("Plugins/WindowPosition.spinnetplugin"))
        return PluginPackage(rootURL: loaded.rootURL, manifest: loaded.manifest, origin: .bundled)
    }

    private func grant(_ package: PluginPackage, in grants: PluginCapabilityGrantStore) {
        grants.setDecision(.granted, for: package.manifest.id, pluginVersion: package.manifest.version,
                           capability: .positionFocusedWindow,
                           scope: package.manifest.scope(for: .positionFocusedWindow))
    }

    private func restoreAction(in package: PluginPackage) throws -> ActionConfiguration {
        let command = try XCTUnwrap(package.manifest.commands.first { $0.id.rawValue == "window.restore" })
        return try ActionConfiguration(id: ActionID("restore"), pluginID: package.manifest.id, command: command, input: .null)
    }

    private func makeBroker(
        grants: PluginCapabilityGrantStore,
        accessibility: @escaping () -> Bool,
        restore: @escaping () throws -> Void
    ) -> CapabilityCheckedHostServiceBroker {
        CapabilityCheckedHostServiceBroker(
            grantStore: grants, systemPermissionCheck: { _ in accessibility() },
            selectedTextProvider: { "" }, clipboardWriter: { _ in },
            focusedWindowProvider: { XCTFail("Restoring should not read the window"); throw PluginHostServiceError.unavailable("") },
            focusedWindowFrameSetter: { _ in XCTFail("Restoring should not set a Plugin frame") },
            focusedWindowFrameRestorer: restore
        )
    }

    private func request(_ input: JSONValue, _ action: ActionConfiguration) -> PluginRuntimeHostServiceRequest {
        PluginRuntimeHostServiceRequest(invocationID: UUID().uuidString, actionID: action.id,
                                        requestID: UUID().uuidString, service: .restoreFocusedWindowFrame, input: input)
    }
}
