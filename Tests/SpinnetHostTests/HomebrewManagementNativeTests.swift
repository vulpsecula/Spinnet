import XCTest
import SpinnetCore
@testable import SpinnetReviewedTools
@testable import SpinnetHost

final class HomebrewManagementNativeTests: XCTestCase {
    func testActualBrowserInventorySearchAndServicesWithoutMutation() throws {
        guard ProcessInfo.processInfo.environment["SPINNET_HOMEBREW_BROWSER_NATIVE"] == "1" else { throw XCTSkip("Opt-in read-only Homebrew browser checks") }
        let profile = HomebrewReadProfile()
        for input: JSONValue in [
            .object(["tool": .string("homebrew"), "operation": .string("installed")]),
            .object(["tool": .string("homebrew"), "operation": .string("outdated")]),
            .object(["tool": .string("homebrew"), "operation": .string("search"), "query": .string("wget")]),
            .object(["tool": .string("homebrew"), "operation": .string("info"), "kind": .string("formula"), "names": .array([.string("wget")])]),
            .object(["tool": .string("homebrew"), "operation": .string("services")]),
            .object(["tool": .string("homebrew"), "operation": .string("taps")])
        ] {
            let result = try profile.read(input, owner: .init("native.browser"), timeout: 15)
            XCTAssertLessThanOrEqual(try JSONEncoder().encode(result).count, 512 * 1024)
            print("HOMEBREW_BROWSER_NATIVE operation=\(input.value(atPointer: "/operation") ?? .null) bytes=\(try JSONEncoder().encode(result).count)")
        }
    }
    func testActualInstalledPackageMetadataWithoutNetworkOrMutation() throws {
        guard ProcessInfo.processInfo.environment["SPINNET_PACKAGE_METADATA_NATIVE"] == "1" else { throw XCTSkip("Opt-in local package metadata check") }
        let profile = HomebrewReadProfile()
        for (kind, name) in [("formula", "libtommath"), ("cask", "spotify")] {
            let start = Date()
            let value = try profile.read(.object(["tool": .string("homebrew"), "operation": .string("info"), "kind": .string(kind), "names": .array([.string(name)])]), owner: PluginID("native.metadata"), timeout: 15)
            guard value.value(atPointer: "/packages/0/installed_version") != nil else { throw XCTSkip("Fixed example package is not installed on this Mac") }
            guard case .string(let path)? = value.value(atPointer: "/packages/0/installed_path") else { XCTFail("An installed reviewed package should expose its existing bounded directory"); continue }
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
            XCTAssertNotNil(value.value(atPointer: "/packages/0/linkable"))
            if kind == "formula" { XCTAssertNotNil(value.value(atPointer: "/packages/0/linked")) }
            else {
                XCTAssertEqual(value.value(atPointer: "/packages/0/linkable"), .bool(false))
                XCTAssertNotNil(value.value(atPointer: "/packages/0/languages"))
                XCTAssertNotNil(value.value(atPointer: "/packages/0/download_url"))
            }
            print("HOMEBREW_PACKAGE_METADATA_NATIVE kind=\(kind) seconds=\(Date().timeIntervalSince(start)) result_bytes=\(try JSONEncoder().encode(value).count)")
        }
    }
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

extension HomebrewManagementNativeTests {
    func testActualFormulaPreviewUsesRealDownloadMetadataWithoutInstallation() throws {
        guard ProcessInfo.processInfo.environment["SPINNET_PREVIEW_METADATA_NATIVE"] == "1" else { throw XCTSkip("Opt-in fixed public hello preview; ghcr.io metadata only, no package mutation") }
        let profile = HomebrewReadProfile(management: HomebrewManagementReads(transport: URLSessionHTTPSTransport()))
        let start = Date()
        let value = try profile.read(.object(["tool": .string("homebrew"), "operation": .string("previewInstall"), "kind": .string("formula"), "names": .array([.string("hello")])]), owner: PluginID("native.preview"), timeout: 15)
        XCTAssertEqual(value.value(atPointer: "/estimated"), .bool(false))
        XCTAssertEqual(value.value(atPointer: "/dry_run"), .bool(true))
        XCTAssertEqual(value.value(atPointer: "/succeeded"), .bool(true))
        guard case .string(let text)? = value.value(atPointer: "/stdout") else { return XCTFail("Missing actual dry-run output") }
        XCTAssertTrue(text.contains("Would install"))
        XCTAssertTrue(text.contains("hello"))
        print("HOMEBREW_PREVIEW_METADATA_NATIVE seconds=\(Date().timeIntervalSince(start)) result=\(value)")
    }

    func testActualPreviewIsReadOnlyHomebrewOutputWithoutNetwork() throws {
        guard ProcessInfo.processInfo.environment["SPINNET_PREVIEW_NATIVE"] == "1" else { throw XCTSkip("Opt-in local dry-run; networking and persistent writes denied") }
        let profile = HomebrewReadProfile()
        let start = Date()
        let value = try profile.read(.object(["tool": .string("homebrew"), "operation": .string("previewInstall"), "kind": .string("cask"), "names": .array([.string("firefox")])]), owner: PluginID("native.preview"), timeout: 15)
        XCTAssertEqual(value.value(atPointer: "/estimated"), .bool(false))
        XCTAssertEqual(value.value(atPointer: "/dry_run"), .bool(true))
        XCTAssertEqual(value.value(atPointer: "/succeeded"), .bool(true))
        XCTAssertEqual(value.value(atPointer: "/stages/0/title"), .string("Would install 1 cask:"))
        print("HOMEBREW_PREVIEW_NATIVE seconds=\(Date().timeIntervalSince(start)) result=\(value)")
    }
}
