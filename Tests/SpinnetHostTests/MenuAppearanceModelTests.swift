import XCTest
@testable import SpinnetHost

/// Appearance is reachable on its own: these tests need a UserDefaults suite
/// and nothing else. Before it was split out, the same behaviour could only be
/// exercised by building a whole SettingsWindowModel, which drags in the
/// configuration editor, the Clipboard History Store, an Accessibility probe
/// and a mouse-conflict probe.
final class MenuAppearanceModelTests: XCTestCase {
    private var suiteName = ""
    private var defaults = UserDefaults.standard

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "SpinnetHostTests.Appearance.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testEditingAValuePersistsItAndReportsTheChange() {
        let model = MenuAppearanceModel(defaults: defaults)
        var reported: [MenuAppearanceConfiguration] = []
        model.onChange = { reported.append($0) }

        model.theme = MenuAppearanceConfiguration.Theme.dark.rawValue

        XCTAssertEqual(defaults.string(forKey: MenuAppearanceConfiguration.themeDefaultsKey),
                       MenuAppearanceConfiguration.Theme.dark.rawValue)
        XCTAssertEqual(reported.count, 1)
        XCTAssertEqual(reported.last?.theme, MenuAppearanceConfiguration.Theme.dark.rawValue)
        XCTAssertTrue(model.canUndo)
        XCTAssertFalse(model.canRedo)
    }

    func testUndoAndRedoRestoreTheSurroundingValues() {
        let model = MenuAppearanceModel(defaults: defaults)
        let original = model.theme
        model.theme = MenuAppearanceConfiguration.Theme.light.rawValue

        model.undo()
        XCTAssertEqual(model.theme, original)
        XCTAssertFalse(model.canUndo)
        XCTAssertTrue(model.canRedo)

        model.redo()
        XCTAssertEqual(model.theme, MenuAppearanceConfiguration.Theme.light.rawValue)
        XCTAssertTrue(model.canUndo)
        XCTAssertFalse(model.canRedo)
    }

    func testUndoAndRedoReportTheChangeOnce() {
        let model = MenuAppearanceModel(defaults: defaults)
        model.accent = MenuAppearanceConfiguration.Accent.green.rawValue
        var reported: [MenuAppearanceConfiguration] = []
        model.onChange = { reported.append($0) }

        model.undo()
        XCTAssertEqual(reported.count, 1, "Restoring five values is one edit, not five")

        model.redo()
        XCTAssertEqual(reported.count, 2)
        XCTAssertEqual(reported.last?.accent, MenuAppearanceConfiguration.Accent.green.rawValue)
    }

    /// A slider drag emits a continuous stream of sizes. The whole drag has to
    /// collapse into one undo entry, otherwise a single gesture floods the
    /// history and undo appears not to work.
    func testAMenuSizeAdjustmentSessionCollapsesIntoOneUndoEntry() {
        let model = MenuAppearanceModel(defaults: defaults)
        model.menuSize = MenuAppearanceConfiguration.Size.small.rawValue
        let beforeDrag = model.menuSize

        model.beginMenuSizeAdjustment()
        model.menuSize = MenuAppearanceConfiguration.Size.medium.rawValue
        model.menuSize = MenuAppearanceConfiguration.Size.large.rawValue
        model.menuSize = MenuAppearanceConfiguration.Size.medium.rawValue
        model.endMenuSizeAdjustment()

        XCTAssertEqual(model.menuSize, MenuAppearanceConfiguration.Size.medium.rawValue)

        model.undo()
        XCTAssertEqual(model.menuSize, beforeDrag,
                       "One undo returns to where the drag started, not to a value it passed through")
    }

    func testAMenuSizeAdjustmentEndingWhereItStartedRecordsNothing() {
        let model = MenuAppearanceModel(defaults: defaults)
        let original = model.menuSize

        model.beginMenuSizeAdjustment()
        model.menuSize = MenuAppearanceConfiguration.Size.large.rawValue
        model.menuSize = original
        model.endMenuSizeAdjustment()

        XCTAssertFalse(model.canUndo, "A drag returning to its origin is not an edit")
    }

    func testWritingTheSameValueRecordsNothing() {
        let model = MenuAppearanceModel(defaults: defaults)
        model.theme = model.theme
        XCTAssertFalse(model.canUndo)
    }

    func testResetReturnsToTheDefaultsAndStaysUndoable() {
        let model = MenuAppearanceModel(defaults: defaults)
        model.theme = MenuAppearanceConfiguration.Theme.dark.rawValue
        model.accent = MenuAppearanceConfiguration.Accent.pink.rawValue
        let edited = model.configuration

        model.reset()
        XCTAssertEqual(model.configuration, MenuAppearanceConfiguration.defaultConfiguration)

        model.undo()
        XCTAssertEqual(model.configuration, edited, "Reset is one entry, so undo restores both edits")
    }

    func testANewModelReadsTheValuesTheLastOnePersisted() {
        let first = MenuAppearanceModel(defaults: defaults)
        first.font = first.font
        first.accent = MenuAppearanceConfiguration.Accent.orange.rawValue

        let second = MenuAppearanceModel(defaults: defaults)
        XCTAssertEqual(second.accent, MenuAppearanceConfiguration.Accent.orange.rawValue)
        XCTAssertFalse(second.canUndo, "History does not survive a restart")
    }
}
