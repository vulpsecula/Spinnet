import Foundation
import XCTest

final class HomebrewLegacyAdmissionTests: XCTestCase {
    func testProductionHelperRejectsEveryOldExecutionEntryBeforeRootStartup() throws {
        let executable = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("SpinnetPrivilegedToolHelper")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path), "Build the real Root helper with this test target")
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--verify-retired-entrypoints"]
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output; process.standardError = errors
        try process.run()
        let body = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let diagnostic = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, diagnostic)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let endpoints = try XCTUnwrap(report["retiredEndpoints"] as? [String: Int])
        XCTAssertEqual(Set(endpoints.keys), ["host.admit", "runner.begin", "client.prepare", "client.perform",
            "inspection.reserve", "inspection.confirmInspection", "inspection.acknowledgeReview", "inspection.confirmMutation",
            "inspection.inspect", "inspection.validateAdmission"])
        XCTAssertTrue(endpoints.values.allSatisfy { $0 == 3 }, "Empty, malformed and validated old plan requests must each be refused")
        XCTAssertEqual(report["requestsRefused"] as? Int, 30)
        XCTAssertEqual(report["rootStateUntouched"] as? Bool, true)
        XCTAssertEqual(report["rootStartupSkipped"] as? Bool, true)
    }
}
