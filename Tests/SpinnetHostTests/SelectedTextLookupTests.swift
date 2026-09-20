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
    }

    private let childrenByElement: [FakeElement: [FakeElement]]
    private let childrenFailure: FakeElement?
    private(set) var selectionQueries: [FakeElement] = []

    init(
        childrenByElement: [FakeElement: [FakeElement]] = [
            .window: [.contentGroup],
            .contentGroup: [.selectedText, .otherWindow]
        ],
        childrenFailure: FakeElement? = nil
    ) {
        self.childrenByElement = childrenByElement
        self.childrenFailure = childrenFailure
    }

    func systemWideElement() -> FakeElement { .systemWide }

    func focusedUIElement(in element: FakeElement) -> SelectedTextAXResult<FakeElement> {
        .noValue
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
        if element == .selectedText {
            return .value("selected message text")
        }
        return .unsupported
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
