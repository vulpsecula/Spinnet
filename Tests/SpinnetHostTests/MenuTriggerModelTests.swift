import XCTest
@testable import SpinnetHost

/// The Menu Trigger is reachable on its own: a UserDefaults suite and a stub
/// conflict check are the whole fixture. Conflict detection is injected, so
/// these tests never touch the real Accessibility-backed detector.
final class MenuTriggerModelTests: XCTestCase {
    private var suiteName = ""
    private var defaults = UserDefaults.standard

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "SpinnetHostTests.Trigger.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func conflict(_ name: String) -> MouseInputConflict {
        MouseInputConflict(id: "com.example.\(name)", applicationName: name,
                           guidance: "Remove that button's assignments in \(name).")
    }

    func testEditingTheTriggerPersistsItAndReportsTheChange() {
        let model = MenuTriggerModel(defaults: defaults, conflictCheck: { _ in [] })
        var reported: [MenuTriggerConfiguration] = []
        model.onChange = { reported.append($0) }

        model.mouseButton = 4

        XCTAssertEqual(reported.count, 1)
        XCTAssertEqual(reported.last?.mouseButton, 4)
        XCTAssertEqual(MenuTriggerConfiguration(defaults: defaults).mouseButton, 4,
                       "The edit is durable before the callback returns")
    }

    func testEveryTriggerValueReportsAChange() {
        let model = MenuTriggerModel(defaults: defaults, conflictCheck: { _ in [] })
        var reported: [MenuTriggerConfiguration] = []
        model.onChange = { reported.append($0) }

        model.mouseButton = 3
        model.clickDragEnabled.toggle()
        model.keyboardShortcut = MenuKeyboardShortcut(keyCode: 35, modifiers: 0, displayValue: "P")

        XCTAssertEqual(reported.count, 3)
        XCTAssertEqual(reported.last?.keyboardShortcut?.keyCode, 35)
    }

    /// Conflicts follow the chosen button, so changing the button has to
    /// re-run detection rather than leave the previous button's verdict on screen.
    func testChangingTheButtonRedetectsConflicts() {
        var probed: [Int] = []
        let model = MenuTriggerModel(defaults: defaults, conflictCheck: { button in
            probed.append(button)
            return button == 4 ? [self.conflict("Rival")] : []
        })

        XCTAssertTrue(model.mouseInputConflicts.isEmpty, "The saved default button is clear in this fixture")

        model.mouseButton = 4
        XCTAssertEqual(model.mouseInputConflicts.map(\.applicationName), ["Rival"])

        model.mouseButton = 3
        XCTAssertTrue(model.mouseInputConflicts.isEmpty)
        XCTAssertEqual(probed.suffix(2), [4, 3])
    }

    /// Another utility can claim the button while Settings sits open, so
    /// detection must be repeatable without touching the trigger.
    func testConflictsRefreshWithoutChangingTheTrigger() {
        var claimed = false
        let model = MenuTriggerModel(defaults: defaults, conflictCheck: { _ in
            claimed ? [self.conflict("Latecomer")] : []
        })
        let button = model.mouseButton
        XCTAssertTrue(model.mouseInputConflicts.isEmpty)

        claimed = true
        model.refreshConflicts()

        XCTAssertEqual(model.mouseInputConflicts.map(\.applicationName), ["Latecomer"])
        XCTAssertEqual(model.mouseButton, button, "Refreshing detection is not an edit")
    }

    func testANewModelReadsTheTriggerTheLastOnePersisted() {
        let first = MenuTriggerModel(defaults: defaults, conflictCheck: { _ in [] })
        first.mouseButton = 5
        first.clickDragEnabled = false

        let second = MenuTriggerModel(defaults: defaults, conflictCheck: { _ in [] })
        XCTAssertEqual(second.mouseButton, 5)
        XCTAssertFalse(second.clickDragEnabled)
    }
}
