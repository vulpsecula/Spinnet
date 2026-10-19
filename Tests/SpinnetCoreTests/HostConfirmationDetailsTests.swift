import XCTest
import SpinnetCore

final class HostConfirmationDetailsTests: XCTestCase {
    func testCollapsedVerificationSharesValidationAndBudgetsWithVisibleActions() throws {
        let action = HostConfirmationDetails.Row(id: "remove", title: "Remove file", detail: "/Library/Selected/file")
        let evidence = HostConfirmationDetails.Row(id: "proof", title: "Verified source", detail: "Exact source and checksum", presentation: .verification)
        let details = try HostConfirmationDetails(title: "Review", summary: "Selected changes", rows: [action, evidence])
        XCTAssertEqual(details.actionRows, [action])
        XCTAssertEqual(details.verificationRows, [evidence])
        XCTAssertEqual(Array(try details.rows(onPage: 0)), [action, evidence])
        let duplicate = HostConfirmationDetails.Row(id: action.id, title: evidence.title, detail: evidence.detail, presentation: .verification)
        XCTAssertThrowsError(try HostConfirmationDetails(title: "Review", summary: "", rows: [action, duplicate]))
        let oversized = (0..<HostConfirmationDetails.maximumRows).map {
            HostConfirmationDetails.Row(id: "proof/\($0)", title: "Source", detail: "Evidence", presentation: .verification)
        }
        XCTAssertThrowsError(try HostConfirmationDetails(title: "Review", summary: "", rows: [action] + oversized))
        let tooLarge = HostConfirmationDetails.Row(id: "large", title: "Source", detail: String(repeating: "x", count: 512 * 1024 + 1), presentation: .verification)
        XCTAssertThrowsError(try HostConfirmationDetails(title: "Review", summary: "", rows: [tooLarge]))
    }
    func testCompleteMaximumReceiptDisclosureIsLosslesslyPageableWithoutExpandingMessage() throws {
        let rows = (0..<50_000).map { HostConfirmationDetails.Row(id: "file_\($0)", title: "Remove file", detail: "/Library/Verified/\($0)") }
        let details = try HostConfirmationDetails(title: "Concrete receipt actions", summary: "50,000 files; retained directories are explicit", rows: rows)
        let confirmation = HostConfirmation(title: "Confirm removal", message: "Verified complete plan", confirmTitle: "Continue", isDestructive: true, details: details)
        XCTAssertEqual(confirmation.message, "Verified complete plan")
        XCTAssertEqual(details.pageCount, 500)
        var received: [String] = []
        for page in 0..<details.pageCount {
            let rows = try details.rows(onPage: page)
            XCTAssertLessThanOrEqual(rows.count, 100)
            received += rows.map(\.id)
        }
        XCTAssertEqual(received, rows.map(\.id))
        XCTAssertThrowsError(try details.rows(onPage: -1))
        XCTAssertThrowsError(try details.rows(onPage: details.pageCount))
    }
    func testAmbiguousOrOversizedDisclosureRefusesInsteadOfTruncating() throws {
        let row = HostConfirmationDetails.Row(id: "same", title: "Retain directory", detail: "/Library/Shared")
        XCTAssertThrowsError(try HostConfirmationDetails(title: "Review", summary: "Shared", rows: [row, row]))
        XCTAssertThrowsError(try HostConfirmationDetails(title: "Review", summary: "Shared", rows: [row], expectedRows: 2))
        XCTAssertThrowsError(try HostConfirmationDetails(title: "Review", summary: "Shared", rows: [.init(id: "control", title: "Remove", detail: "/Library/\u{1b}unreviewed")]))
        let empty = try HostConfirmationDetails(title: "Receipt metadata only", summary: "No existing files; only the exact receipt is forgotten", rows: [])
        XCTAssertEqual(empty.pageCount, 1)
        XCTAssertTrue(try empty.rows(onPage: 0).isEmpty)
    }
}
