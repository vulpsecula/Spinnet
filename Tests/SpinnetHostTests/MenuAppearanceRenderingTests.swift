import AppKit
import SpinnetCore
import SwiftUI
import XCTest
@testable import SpinnetHost

/// Appearance as it reaches the screen: title wrapping and font selection, the
/// theme boundary between a Menu and the Settings window, and the menu-size
/// contract shared by Editor Mode, Runtime Mode and the native slider.
final class MenuAppearanceRenderingTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    func testMenuTitleLayoutUsesReadableWrappingAndConfiguredFont() {
        let wrapped = MenuTitleLayoutEngine.layout(
            title: "A Very Long Menu Item Name",
            maxWidth: 120,
            baseSize: 13,
            font: .system
        )
        XCTAssertEqual(wrapped.lineCount, 2)
        XCTAssertFalse(wrapped.text.contains("…"))
        XCTAssertEqual(wrapped.font.pointSize, 13)

        let short = MenuTitleLayoutEngine.layout(
            title: "Open",
            maxWidth: 120,
            baseSize: 13,
            font: .system
        )
        XCTAssertEqual(wrapped.font.fontDescriptor, short.font.fontDescriptor)

        let oneSlotLayout = RadialMenuLayout(
            itemCount: 1,
            innerRadius: 38,
            outerRadius: 142,
            itemCenterRadius: 90
        )
        let oneSlotTitle = MenuTitleLayoutEngine.layout(
            title: "Fixture",
            maxWidth: RadialMenuView.menuTitleWidth(for: oneSlotLayout),
            baseSize: 13,
            font: .system
        )
        XCTAssertEqual(
            oneSlotTitle.lineCount,
            1,
            "A one-slot Menu should not split an ordinary title into a vertical stack"
        )

        let singleWord = MenuTitleLayoutEngine.layout(
            title: "Fixture",
            maxWidth: 36,
            baseSize: 10,
            font: .system
        )
        XCTAssertFalse(singleWord.text.contains("\n"))

        let wrappedWord = MenuTitleLayoutEngine.layout(
            title: "ExtremelyLongSlotName",
            maxWidth: 36,
            baseSize: 10,
            font: .system
        )
        XCTAssertEqual(wrappedWord.font.pointSize, 10)
        XCTAssertFalse(wrappedWord.text.contains("…"))
        XCTAssertGreaterThan(wrappedWord.lineCount, 1)
        XCTAssertEqual(
            wrappedWord.text.replacingOccurrences(of: "\n", with: ""),
            "ExtremelyLongSlotName"
        )

        let system = MenuTitleLayoutEngine.layout(
            title: "Open",
            maxWidth: 80,
            baseSize: 13,
            font: .system
        )
        let customFamily = MenuTitleLayoutEngine.layout(
            title: "Open",
            maxWidth: 80,
            baseSize: 13,
            font: MenuAppearanceConfiguration.MenuFont(rawValue: testMenuFontFamily)
        )
        XCTAssertNotEqual(system.font.fontName, customFamily.font.fontName)

        let regular = MenuTitleLayoutEngine.layout(
            title: "Open",
            maxWidth: 80,
            baseSize: 13,
            font: .system,
            weight: .regular
        )
        let bold = MenuTitleLayoutEngine.layout(
            title: "Open",
            maxWidth: 80,
            baseSize: 13,
            font: .system,
            weight: .bold
        )
        XCTAssertNotEqual(regular.font.fontDescriptor, bold.font.fontDescriptor)
    }

    func testMenuFontOptionsIncludeEveryInstalledFontFamily() throws {
        let installedFamilies = Set(NSFontManager.shared.availableFontFamilies)
        let options = MenuAppearanceConfiguration.fontOptions

        XCTAssertEqual(options.first, MenuAppearanceConfiguration.MenuFont.system.rawValue)
        XCTAssertTrue(installedFamilies.isSubset(of: Set(options)))
        XCTAssertGreaterThan(options.count, 4)

        let family = try XCTUnwrap(options.dropFirst().first)
        let configuration = MenuAppearanceConfiguration(font: family)
        XCTAssertEqual(configuration.font, family)

        let renderedFont = configuration.titleFont(ofSize: 13, weight: .regular)
        XCTAssertEqual(renderedFont.familyName, family)
    }

    func testMenuThemeDoesNotOverrideSettingsWindowAppearance() throws {
        let suiteName = "SpinnetHostTests.MenuThemeIsolation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("Dark", forKey: MenuAppearanceConfiguration.themeDefaultsKey)

        let controller = SettingsWindowController(
            editor: try makeEditor(),
            defaults: defaults
        )
        defer { controller.close() }

        XCTAssertNil(controller.window?.appearance)
    }

    func testAppearanceSizeUsesOneGeometryContractAcrossEditorRuntimeAndScreenEdges() throws {
        let visibleFrame = try XCTUnwrap(NSScreen.main).visibleFrame
        let centre = CGPoint(x: visibleFrame.midX, y: visibleFrame.midY)
        let edgePointers = [
            CGPoint(x: visibleFrame.minX + 1, y: visibleFrame.midY),
            CGPoint(x: visibleFrame.maxX - 1, y: visibleFrame.midY),
            CGPoint(x: visibleFrame.midX, y: visibleFrame.minY + 1),
            CGPoint(x: visibleFrame.midX, y: visibleFrame.maxY - 1)
        ]

        let menuSizes = MenuAppearanceConfiguration.menuSizeOptions + ["125", "200"]
        for size in menuSizes {
            let appearance = MenuAppearanceConfiguration(menuSize: size)
            for slotCount in [1, 4, 8, 12] {
                let slots = Array(repeating: MenuSlotPresentation.empty, count: slotCount)
                let editorView = RadialMenuView(slots: slots, mode: .editor)
                editorView.applyAppearance(appearance)
                let runtimeMenu = MenuPresentationController(
                    items: slots,
                    appearance: appearance
                )
                var activatedRuntimeSlot: Int?
                runtimeMenu.onEmptySlotActivated = { activatedRuntimeSlot = $0 }

                runtimeMenu.open(at: centre)
                let runtimeGeometry = runtimeMenu.geometrySnapshot
                XCTAssertEqual(editorView.geometryLayout, runtimeGeometry.layout)
                XCTAssertEqual(
                    editorView.bounds.width,
                    runtimeGeometry.contentSize.width,
                    accuracy: 1
                )
                XCTAssertEqual(
                    editorView.bounds.height,
                    runtimeGeometry.contentSize.height,
                    accuracy: 1
                )

                let editorCenter = CGPoint(
                    x: editorView.bounds.midX,
                    y: editorView.bounds.midY
                )
                let runtimeCenter = CGPoint(
                    x: runtimeGeometry.overlayFrame.midX,
                    y: runtimeGeometry.overlayFrame.midY
                )
                let editorItemCenter = editorView.geometryLayout.itemCenter(
                    index: 0,
                    center: editorCenter
                )
                let editorWindow = NSWindow(
                    contentRect: editorView.bounds,
                    styleMask: .borderless,
                    backing: .buffered,
                    defer: false
                )
                editorWindow.contentView = editorView
                var selectedEditorIndex: Int?
                editorView.onEditorSelection = { selectedEditorIndex = $0 }
                let editorEvent = try XCTUnwrap(NSEvent.mouseEvent(
                    with: .leftMouseDown,
                    location: editorItemCenter,
                    modifierFlags: [],
                    timestamp: 0,
                    windowNumber: editorWindow.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 1
                ))
                editorView.mouseDown(with: editorEvent)
                XCTAssertEqual(
                    selectedEditorIndex,
                    runtimeGeometry.layout.hitTest(
                        point: editorItemCenter,
                        center: editorCenter
                    )
                )

                let runtimeItemOffset = runtimeGeometry.layout.itemCenter(
                    index: 0,
                    center: .zero
                )
                runtimeMenu.finishGesture(at: CGPoint(
                    x: runtimeCenter.x + runtimeItemOffset.x,
                    y: runtimeCenter.y + runtimeItemOffset.y
                ))
                XCTAssertEqual(activatedRuntimeSlot, 0)
                runtimeMenu.dismiss()

                for pointer in edgePointers {
                    runtimeMenu.open(at: pointer)
                    let actualFrame = runtimeMenu.geometrySnapshot.overlayFrame
                    let expectedFrame = appearance.layout(slotCount: slotCount).overlayFrame(
                        for: pointer,
                        in: visibleFrame
                    )
                    XCTAssertEqual(actualFrame.minX, expectedFrame.minX, accuracy: 1)
                    XCTAssertEqual(actualFrame.minY, expectedFrame.minY, accuracy: 1)
                    XCTAssertEqual(actualFrame.width, expectedFrame.width, accuracy: 1)
                    XCTAssertEqual(actualFrame.height, expectedFrame.height, accuracy: 1)
                    activatedRuntimeSlot = nil
                    let edgeItemOffset = runtimeMenu.geometrySnapshot.layout.itemCenter(
                        index: 0,
                        center: .zero
                    )
                    runtimeMenu.finishGesture(at: CGPoint(
                        x: actualFrame.midX + edgeItemOffset.x,
                        y: actualFrame.midY + edgeItemOffset.y
                    ))
                    XCTAssertEqual(activatedRuntimeSlot, 0)
                    runtimeMenu.dismiss()
                }
            }
        }
    }

    func testMenuSizeSupportsContinuousPercentagesAndThreeSnapPoints() {
        XCTAssertEqual(MenuAppearanceConfiguration.Size.small.percentage, 100)
        XCTAssertEqual(MenuAppearanceConfiguration.Size.medium.percentage, 150)
        XCTAssertEqual(MenuAppearanceConfiguration.Size.large.percentage, 200)
        XCTAssertEqual(MenuAppearanceConfiguration.menuSizeSnapPoints, [100, 150, 200])
        XCTAssertEqual(
            MenuAppearanceConfiguration.menuSizeSnapPoints[1]
                - MenuAppearanceConfiguration.menuSizeSnapPoints[0],
            MenuAppearanceConfiguration.menuSizeSnapPoints[2]
                - MenuAppearanceConfiguration.menuSizeSnapPoints[1]
        )
        for (index, point) in MenuAppearanceConfiguration.menuSizeSnapPoints.enumerated() {
            XCTAssertEqual(
                (point - MenuAppearanceConfiguration.menuSizeMinimumPercentage)
                    / (MenuAppearanceConfiguration.menuSizeMaximumPercentage
                        - MenuAppearanceConfiguration.menuSizeMinimumPercentage),
                Double(index + 1) / 3,
                accuracy: 0.001
            )
        }

        let custom = MenuAppearanceConfiguration(menuSize: "125")
        XCTAssertEqual(custom.menuSize, "125")
        XCTAssertEqual(custom.scale, 1.25, accuracy: 0.001)
        XCTAssertEqual(MenuAppearanceConfiguration(menuSize: "125.5").menuSize, "125.5")
        XCTAssertEqual(MenuAppearanceConfiguration(menuSize: "100").menuSize, "100")
        XCTAssertEqual(MenuAppearanceConfiguration(menuSize: "150").menuSize, "150")
        XCTAssertEqual(MenuAppearanceConfiguration(menuSize: "200").menuSize, "200")
        XCTAssertEqual(MenuAppearanceConfiguration(menuSize: "100.00005").menuSize, "100.00005")
        XCTAssertEqual(MenuAppearanceConfiguration.exactMenuSizeValue(forPercentage: 100.4), "100.4")
        XCTAssertEqual(MenuAppearanceConfiguration.exactMenuSizeValue(forPercentage: 100), "100")
        XCTAssertEqual(MenuAppearanceConfiguration.exactMenuSizeValue(forPercentage: 150), "150")
        XCTAssertEqual(MenuAppearanceConfiguration.exactMenuSizeValue(forPercentage: 200), "200")

        XCTAssertEqual(MenuAppearanceConfiguration(menuSize: "20").menuSize, "50")
        XCTAssertEqual(MenuAppearanceConfiguration(menuSize: "999").menuSize, "Large")
        XCTAssertEqual(
            MenuAppearanceConfiguration.snappedMenuSizePercentage(97),
            100,
            accuracy: 0.001
        )
        XCTAssertEqual(
            MenuAppearanceConfiguration.snappedMenuSizePercentage(153),
            150,
            accuracy: 0.001
        )
        XCTAssertEqual(
            MenuAppearanceConfiguration.snappedMenuSizePercentage(160),
            160,
            accuracy: 0.001
        )
    }

    func testMenuSizeSliderSnapsDuringDragAndAlignsLabelsToTheNativeThumbTravel() throws {
        XCTAssertEqual(
            MenuAppearanceConfiguration.interactiveMenuSizeValue(forPercentage: 98),
            "Small"
        )
        XCTAssertEqual(
            MenuAppearanceConfiguration.interactiveMenuSizeValue(forPercentage: 104),
            "Small"
        )
        XCTAssertEqual(
            MenuAppearanceConfiguration.interactiveMenuSizeValue(forPercentage: 106),
            "106"
        )

        let slider = MenuSizeSliderView(
            value: 150,
            range: (MenuAppearanceConfiguration.menuSizeMinimumPercentage
                ... MenuAppearanceConfiguration.menuSizeMaximumPercentage)
        )
        slider.frame = NSRect(x: 0, y: 0, width: 300, height: 38)
        slider.layoutSubtreeIfNeeded()

        XCTAssertNil(
            MenuSizeSliderView(
                value: 104,
                range: (MenuAppearanceConfiguration.menuSizeMinimumPercentage
                    ... MenuAppearanceConfiguration.menuSizeMaximumPercentage)
            ).activeSnapPoint,
            "A custom percentage near a preset must not appear selected"
        )
        XCTAssertNil(
            MenuSizeSliderView(
                value: 100.4,
                range: (MenuAppearanceConfiguration.menuSizeMinimumPercentage
                    ... MenuAppearanceConfiguration.menuSizeMaximumPercentage)
            ).activeSnapPoint,
            "A precise custom percentage must not appear selected"
        )
        XCTAssertNil(
            MenuSizeSliderView(
                value: 100.00005,
                range: (MenuAppearanceConfiguration.menuSizeMinimumPercentage
                    ... MenuAppearanceConfiguration.menuSizeMaximumPercentage)
            ).activeSnapPoint,
            "A manually entered value that is merely close to a preset must not appear selected"
        )

        let nativeSlider = slider.nativeSlider
        let cell = try XCTUnwrap(nativeSlider.cell as? NSSliderCell)
        let originalValue = nativeSlider.doubleValue
        nativeSlider.doubleValue = MenuAppearanceConfiguration.menuSizeMinimumPercentage
        let expectedMinimum = nativeSlider.frame.minX
            + cell.knobRect(flipped: nativeSlider.isFlipped).midX
        nativeSlider.doubleValue = MenuAppearanceConfiguration.menuSizeMaximumPercentage
        let expectedMaximum = nativeSlider.frame.minX
            + cell.knobRect(flipped: nativeSlider.isFlipped).midX
        nativeSlider.doubleValue = originalValue

        XCTAssertEqual(slider.nativeThumbTravel.lowerBound, expectedMinimum, accuracy: 0.001)
        XCTAssertEqual(slider.nativeThumbTravel.upperBound, expectedMaximum, accuracy: 0.001)
        for (index, _) in MenuAppearanceConfiguration.Size.allCases.enumerated() {
            let expected = expectedMinimum
                + (expectedMaximum - expectedMinimum) * CGFloat(index + 1) / 3
            XCTAssertEqual(
                slider.snapPointXPositions[index],
                expected,
                accuracy: 0.001
            )
        }
    }

    func testMenuSizeSliderAdjustmentCreatesOneUndoEntry() throws {
        let suiteName = "SpinnetHostTests.MenuSizeUndo.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = SettingsWindowModel(
            editor: try makeEditor(),
            metadata: .current,
            defaults: defaults,
            accessibilityPermissionCheck: { true },
            mouseInputConflictCheck: { _ in [] }
        )

        model.appearance.beginMenuSizeAdjustment()
        model.appearance.menuSize = "112"
        model.appearance.menuSize = "148"
        model.appearance.menuSize = "125"
        model.appearance.endMenuSizeAdjustment()

        XCTAssertEqual(model.appearance.menuSize, "125")
        XCTAssertTrue(model.appearance.canUndo)

        model.appearance.undo()

        XCTAssertEqual(model.appearance.menuSize, "Medium")
        XCTAssertFalse(model.appearance.canUndo)
        XCTAssertTrue(model.appearance.canRedo)
    }
}
