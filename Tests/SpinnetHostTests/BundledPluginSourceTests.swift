import XCTest
@testable import SpinnetHost

/// Which Plugins a launch is allowed to call Bundled, and whether it read
/// enough of them to decide that a Plugin is gone.
final class BundledPluginSourceTests: XCTestCase {
    private let bundle = URL(fileURLWithPath: "/Applications/SpinnetHost.app", isDirectory: true)
    private let resources = URL(
        fileURLWithPath: "/Applications/SpinnetHost.app/Contents/Resources",
        isDirectory: true
    )

    func testPackagedHostReadsItsOwnPluginsAndIgnoresTheDevelopmentDirectory() throws {
        let source = try BundledPluginSource.resolve(
            bundleURL: bundle,
            resourceURL: resources,
            environmentOverride: "/tmp/anything",
            directoryExists: { _ in true }
        )

        XCTAssertEqual(
            source,
            .packaged(resources.appendingPathComponent("Plugins", isDirectory: true)),
            "A packaged Host may only grant Bundled authority to the Plugins it ships"
        )
        XCTAssertTrue(source.accountsForBundledPlugins)
    }

    func testPackagedHostWithoutItsPluginsRefusesToStart() {
        XCTAssertThrowsError(try BundledPluginSource.resolve(
            bundleURL: bundle,
            resourceURL: resources,
            environmentOverride: nil,
            directoryExists: { _ in false }
        ))
    }

    func testDevelopmentDirectoryIsReadWithoutSpeakingForEveryBundledPlugin() throws {
        let source = try BundledPluginSource.resolve(
            bundleURL: URL(fileURLWithPath: "/repository/.build/debug", isDirectory: true),
            resourceURL: nil,
            environmentOverride: "Plugins",
            directoryExists: { _ in true }
        )

        XCTAssertEqual(source, .development(URL(fileURLWithPath: "Plugins", isDirectory: true)))
        XCTAssertFalse(
            source.accountsForBundledPlugins,
            "A directory a development run was pointed at holds whatever it holds"
        )
    }

    func testRunWithNoPluginDirectoryAccountsForNoBundledPlugins() throws {
        let source = try BundledPluginSource.resolve(
            bundleURL: URL(fileURLWithPath: "/repository/.build/debug", isDirectory: true),
            resourceURL: nil,
            environmentOverride: nil,
            directoryExists: { _ in true }
        )

        XCTAssertEqual(source, BundledPluginSource.none)
        XCTAssertNil(source.directory)
        XCTAssertFalse(
            source.accountsForBundledPlugins,
            "A launch that read no Bundled Plugin cannot decide that one is gone"
        )
    }
}
