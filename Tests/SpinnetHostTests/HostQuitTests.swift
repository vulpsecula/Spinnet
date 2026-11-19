import XCTest
@testable import SpinnetHost

final class HostQuitTests: XCTestCase {

    /// System Settings quits an App to apply a System Permission and means to
    /// reopen it; its Privacy & Security pane runs as its own extension.
    /// Nobody else's quit reopens Spinnet, a logout least of all.
    func testOnlySystemSettingsQuitReopensSpinnet() {
        XCTAssertTrue(HostQuit.reopensAfterQuit(requestedBy: "com.apple.systempreferences"))
        XCTAssertTrue(HostQuit.reopensAfterQuit(requestedBy: "com.apple.settings.PrivacySecurity.extension"))
        XCTAssertFalse(HostQuit.reopensAfterQuit(requestedBy: "com.apple.loginwindow"))
        XCTAssertFalse(HostQuit.reopensAfterQuit(requestedBy: "com.apple.dock"))
        XCTAssertFalse(HostQuit.reopensAfterQuit(requestedBy: "com.apple.settingsish"))
        XCTAssertFalse(HostQuit.reopensAfterQuit(requestedBy: nil))
    }

    /// A sender that is no running App is named by the bundle holding it.
    func testASendersBundleIsTheInnermostAppOrExtensionHoldingIt() {
        XCTAssertEqual(
            HostQuit.bundlePath(containing: "/System/Library/ExtensionKit/Extensions/SecurityPrivacyExtension.appex/Contents/MacOS/SecurityPrivacyExtension"),
            "/System/Library/ExtensionKit/Extensions/SecurityPrivacyExtension.appex"
        )
        XCTAssertEqual(
            HostQuit.bundlePath(containing: "/System/Applications/System Settings.app/Contents/MacOS/System Settings"),
            "/System/Applications/System Settings.app"
        )
        XCTAssertNil(HostQuit.bundlePath(containing: "/usr/bin/osascript"))
    }

    func testAQuitWithNoSheetFinishesAtOnce() {
        var finished = 0
        var scheduled = 0
        SheetDrain(hasAttachedSheet: { false }, schedule: { _, _ in scheduled += 1 }, finish: { finished += 1 }).start()
        XCTAssertEqual(finished, 1)
        XCTAssertEqual(scheduled, 0)
    }

    /// SwiftUI takes a sheet down a moment after its state changes, so the
    /// quit waits for it rather than being refused by AppKit.
    func testAQuitWaitsForTheSheetToGo() {
        var sheetChecks = 0
        var pending: [() -> Void] = []
        var finished = 0
        SheetDrain(hasAttachedSheet: { sheetChecks += 1; return sheetChecks < 3 },
                   schedule: { _, work in pending.append(work) }, finish: { finished += 1 }).start()
        while !pending.isEmpty { pending.removeFirst()() }
        XCTAssertEqual(finished, 1)
        XCTAssertEqual(sheetChecks, 3)
    }

    /// A sheet that never goes does not hang the quit.
    func testAQuitStopsWaitingAfterItsLastCheck() {
        var pending: [() -> Void] = []
        var finished = 0
        var drain = SheetDrain(hasAttachedSheet: { true }, schedule: { _, work in pending.append(work) },
                               finish: { finished += 1 })
        drain.attempts = 5
        drain.start()
        var waits = 0
        while !pending.isEmpty { pending.removeFirst()(); waits += 1 }
        XCTAssertEqual(waits, 5)
        XCTAssertEqual(finished, 1)
    }
}
