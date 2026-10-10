import XCTest
import SpinnetCore
@testable import SpinnetHost

final class HomebrewManagementNativeTests: XCTestCase {
    func testSafeActualLocalManagementReads() throws {
        guard ProcessInfo.processInfo.environment["SPINNET_HOMEBREW_MANAGEMENT_NATIVE"] == "1" else { throw XCTSkip("Opt-in read-only native Homebrew checks") }
        let profile = HomebrewReadProfile(management: HomebrewManagementReads(transport: URLSessionHTTPSTransport()))
        for operation in ["version", "taps", "services", "doctor", "adoptionCandidates"] {
            let start = Date()
            let value = try profile.read(.object(["tool": .string("homebrew"), "operation": .string(operation)]), owner: PluginID("native.management"), timeout: 15)
            let bytes = try JSONEncoder().encode(value).count
            XCTAssertLessThanOrEqual(bytes, 512 * 1024)
            print("HOMEBREW_MANAGEMENT_NATIVE operation=\(operation) seconds=\(Date().timeIntervalSince(start)) result_bytes=\(bytes)")
        }
    }
    func testFixedPublicMetadataExamplesWithoutInstalledInventoryEgress() throws {
        guard ProcessInfo.processInfo.environment["SPINNET_PUBLIC_METADATA_NATIVE"] == "1" else { throw XCTSkip("Opt-in fixed public metadata checks") }
        let profile = HomebrewReadProfile(management: HomebrewManagementReads(transport: URLSessionHTTPSTransport()))
        let analytics = try profile.read(.object(["tool": .string("homebrew"), "operation": .string("packageAnalytics"), "kind": .string("formula"), "names": .array([.string("wget")])]), owner: PluginID("native.management"), timeout: 15)
        XCTAssertNotNil(analytics.value(atPointer: "/analytics/install/30d"))
        print("HOMEBREW_PUBLIC_METADATA_NATIVE analytics_result_bytes=\(try JSONEncoder().encode(analytics).count)")
        let advisory = try profile.read(.object(["tool": .string("homebrew"), "operation": .string("vulnerabilityDetail"), "id": .string("CVE-2023-38545")]), owner: PluginID("native.management"), timeout: 15)
        XCTAssertEqual(advisory.value(atPointer: "/advisory/id"), .string("CVE-2023-38545"))
        print("HOMEBREW_PUBLIC_METADATA_NATIVE advisory_result_bytes=\(try JSONEncoder().encode(advisory).count)")
    }
}
