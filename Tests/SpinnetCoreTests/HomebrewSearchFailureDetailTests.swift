import XCTest
@testable import SpinnetCore
@testable import SpinnetReviewedTools

final class HomebrewSearchFailureDetailTests: XCTestCase {
    private func failure(_ status: Int32, _ stderr: String) throws -> PluginHostServiceError {
        var launches = 0
        defer { XCTAssertEqual(launches,1,"Failure diagnostics must use the original attempt") }
        let profile = HomebrewReadProfile(executable: { URL(fileURLWithPath:"/opt/homebrew/bin/brew") }, execute: { _, _, _, _ in
            launches += 1
            return .init(status:status,stdout:Data(),stderr:Data(stderr.utf8))
        })
        do {
            _ = try profile.read(.object(["tool":.string("homebrew"),"operation":.string("search"),"kind":.string("formula"),"query":.string("example")]),owner:.init("failure-detail"))
            XCTFail("A failed search must not become an empty result")
        } catch let error as PluginHostServiceError { return error }
        throw CocoaError(.coderInvalidValue)
    }
    func testSearchPreservesNativeFailureReasonAndCategoryWithoutRetrying() throws {
        for status: Int32 in [1,2,78] {
            let error = try failure(status,"Error: Catalog snapshot is malformed.\n")
            XCTAssertEqual(error.runtimeFailureCategory,.toolFailed)
            XCTAssertEqual(HostOperationReason(error),.toolFailed)
            XCTAssertEqual(FetchedAnswer.message(for:error),error.description)
            XCTAssertTrue(error.description.contains("Catalog snapshot is malformed."))
            XCTAssertTrue(error.description.contains("exit \(status)"))
        }
    }
    func testFailureDetailIsBoundedAndSanitizedBeforePublication() throws {
        let detail = "\u{001B}[31mError: Catalog unavailable\u{001B}[0m\npassword=do-not-expose\nAuthorization: Bearer do-not-expose\n" + String(repeating:"more\n",count:200)
        let error = try failure(2,detail)
        XCTAssertLessThanOrEqual(error.description.count,512)
        XCTAssertTrue(error.description.contains("Catalog unavailable"))
        XCTAssertFalse(error.description.contains("do-not-expose"))
        XCTAssertFalse(error.description.contains("\u{001B}"))
    }
    func testCredentialRedactionPrecedesDiagnosticTruncation() throws {
        let detail = "Error: https://private-user:" + String(repeating:"do-not-expose",count:600) + "@example.com/catalog?token=also-private"
        let error = try failure(2,detail)
        XCTAssertTrue(error.description.contains("https://example.com/catalog"))
        for secret in ["private-user","do-not-expose","also-private"] { XCTAssertFalse(error.description.contains(secret)) }
    }
}
