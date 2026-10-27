import XCTest
import CryptoKit
import Darwin
import SpinnetCore
@testable import SpinnetReviewedTools

final class HomebrewNativeProductOriginTests: XCTestCase {
    func testActualAppleProductComponentViewsBindPBZXResourcesAndChargeOneAggregateBudget() throws {
        XCTAssertNotEqual(getuid(), 0, "Owned product fixture, never Root acceptance/publisher-body proof")
        let bytes = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "vendor-origin-product", withExtension: "pkg", subdirectory: "ArchiveFixtures")))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try NativeFileQuarantine.makePrivateDirectory(root); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("product.pkg")
        try bytes.write(to: source); XCTAssertEqual(chmod(source.path, 0o600), 0)
        let decoder = HomebrewArchiveStaging.DecoderConfiguration(bootstrap: Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("SpinnetArchiveBootstrap"), uid: getuid(), gid: getgid())
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let product = try HomebrewArchiveStaging.extractVerified(source, checksum: hash, into: root.appendingPathComponent("product"), selected: ".", decoder: decoder)
        let names = try FileManager.default.contentsOfDirectory(atPath: product.selectedURL.path)
        XCTAssertTrue(names.contains("vendor-origin-latest.pkg"), "Owned product members: \(names)")
        XCTAssertTrue(try NativeFileQuarantine.capture(product.selectedURL.appendingPathComponent("vendor-origin-latest.pkg")).directory)
        let componentNames = try FileManager.default.contentsOfDirectory(atPath: product.selectedURL.appendingPathComponent("vendor-origin-latest.pkg").path)
        XCTAssertTrue(try NativeFileQuarantine.existsWithoutFollowing(product.selectedURL.appendingPathComponent("vendor-origin-latest.pkg/PackageInfo")), "Root: \(names); component: \(componentNames)")
        var budget = try HomebrewNativeSourceBudget()
        try budget.consume(product, deadline: Date().addingTimeInterval(5)); let before = budget.usedBytes
        let components = try HomebrewNativeVendorOrigin.extractPackagePayloads(product, into: root, artifactIndex: 0,
            decoder: decoder, deadline: Date().addingTimeInterval(10), budget: &budget)
        XCTAssertEqual(components.count, 1)
        let component = try XCTUnwrap(components.first)
        XCTAssertEqual(component.component, "vendor-origin-latest.pkg")
        XCTAssertEqual(component.resourceDirectory, "payload-0-0")
        XCTAssertEqual(component.payload.installLocation, "/")
        XCTAssertGreaterThan(budget.usedBytes, before)
        let installed = root.appendingPathComponent("owned-installed")
        try Data("vendor executable".utf8).write(to: installed); XCTAssertEqual(chmod(installed.path, 0o700), 0)
        let match = try HomebrewNativeVendorOrigin.compareMember(component.payload.tree, member: "Library/Application Support/Vendor/uninstall", installed: installed, deadline: Date().addingTimeInterval(5))
        XCTAssertEqual(match.executableSHA256, "57fa54816d203f24ce26ae4734a7eba5c220408c6fccbba218ab2cd957655961")
    }
}
