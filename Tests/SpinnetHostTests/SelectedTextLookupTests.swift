import AppKit
import XCTest
@testable import SpinnetHost

final class SelectedTextLookupTests: XCTestCase {
    func testReadsSelectedTextFromFocusedWindowDescendantWhenGlobalFocusIsUnavailable() throws {
        let client = FakeSelectedTextAXClient()

        let selectedText = try SelectedTextLookup().read(using: client)

        XCTAssertEqual(selectedText, "selected message text")
        XCTAssertEqual(client.selectionQueries, [.window, .contentGroup, .selectedText])
        XCTAssertFalse(client.selectionQueries.contains(.otherWindow))
    }

    func testSelectionSearchHonorsMaximumElementCount() throws {
        let client = FakeSelectedTextAXClient(
            childrenByElement: [
                .window: [.contentGroup, .otherWindow, .selectedText]
            ]
        )
        let lookup = SelectedTextLookup(
            maxDepth: 12,
            maxElements: 2,
            searchDuration: .seconds(1)
        )

        let selectedText = try lookup.read(using: client)

        XCTAssertEqual(selectedText, "")
        XCTAssertEqual(client.selectionQueries, [.window, .contentGroup])
    }

    func testSelectionSearchHonorsMaximumDepth() throws {
        let client = FakeSelectedTextAXClient(
            childrenByElement: [
                .window: [.contentGroup],
                .contentGroup: [.selectedText]
            ]
        )
        let lookup = SelectedTextLookup(
            maxDepth: 1,
            maxElements: 10,
            searchDuration: .seconds(1)
        )

        let selectedText = try lookup.read(using: client)

        XCTAssertEqual(selectedText, "")
        XCTAssertEqual(client.selectionQueries, [.window, .contentGroup])
    }

    func testSelectionSearchSurfacesAccessibilityFailuresForCopyFallback() {
        let client = FakeSelectedTextAXClient(childrenFailure: .window)

        XCTAssertThrowsError(try SelectedTextLookup().read(using: client))
    }

    // Chrome keeps the address bar's select-all range after the user clicks
    // into the page: the focused web area reports no selection, and the
    // unfocused address bar still reports the whole address as selected.
    // The web area answers an empty string on some pages and no value on
    // others; both say nothing is selected.
    func testFocusedElementReportingNoSelectionIsNotOverriddenByAnotherElementsSelection() throws {
        for webAreaSelection: SelectedTextAXResult<String> in [.value(""), .noValue] {
            let client = FakeSelectedTextAXClient(
                childrenByElement: [.window: [.addressBar, .webArea]],
                focusedElement: .webArea,
                selections: [
                    .webArea: webAreaSelection,
                    .addressBar: .value("https://www.bilibili.com/video/BV18Ryfz1ES9/?")
                ]
            )

            let selectedText = try SelectedTextLookup().read(using: client)

            XCTAssertEqual(selectedText, "", "\(webAreaSelection)")
            XCTAssertFalse(client.selectionQueries.contains(.addressBar), "\(webAreaSelection)")
        }
    }

    func testSearchesWindowWhenFocusedElementDoesNotReportSelectedText() throws {
        let client = FakeSelectedTextAXClient(focusedElement: .contentGroup)

        let selectedText = try SelectedTextLookup().read(using: client)

        XCTAssertEqual(selectedText, "selected message text")
    }
}

private final class FakeSelectedTextAXClient: SelectedTextAXClient {
    typealias Element = FakeElement

    enum FakeElement: Hashable {
        case systemWide
        case application
        case window
        case contentGroup
        case selectedText
        case otherWindow
        case webArea
        case addressBar
    }

    private let childrenByElement: [FakeElement: [FakeElement]]
    private let childrenFailure: FakeElement?
    private let focusedElement: FakeElement?
    private let selections: [FakeElement: SelectedTextAXResult<String>]
    private(set) var selectionQueries: [FakeElement] = []

    init(
        childrenByElement: [FakeElement: [FakeElement]] = [
            .window: [.contentGroup],
            .contentGroup: [.selectedText, .otherWindow]
        ],
        childrenFailure: FakeElement? = nil,
        focusedElement: FakeElement? = nil,
        selections: [FakeElement: SelectedTextAXResult<String>] = [.selectedText: .value("selected message text")]
    ) {
        self.childrenByElement = childrenByElement
        self.childrenFailure = childrenFailure
        self.focusedElement = focusedElement
        self.selections = selections
    }

    func systemWideElement() -> FakeElement { .systemWide }

    func focusedUIElement(in element: FakeElement) -> SelectedTextAXResult<FakeElement> {
        focusedElement.map { .value($0) } ?? .noValue
    }

    func focusedApplication(in element: FakeElement) -> SelectedTextAXResult<FakeElement> {
        .noValue
    }

    func frontmostApplication() -> FakeElement? { .application }

    func focusedWindow(in element: FakeElement) -> SelectedTextAXResult<FakeElement> {
        .value(.window)
    }

    func selectedText(in element: FakeElement, messagingTimeout: Float?) -> SelectedTextAXResult<String> {
        selectionQueries.append(element)
        return selections[element] ?? .unsupported
    }

    func children(
        of element: FakeElement,
        limitedTo maximumCount: Int,
        messagingTimeout: Float?
    ) -> SelectedTextAXResult<[FakeElement]> {
        if element == childrenFailure { return .failure(.cannotComplete) }
        return .value(Array((childrenByElement[element] ?? []).prefix(maximumCount)))
    }
}
