import Foundation
import SpinnetCore
import SpinnetReviewedTools
import XCTest
@testable import SpinnetHost

final class HostIdentityMigrationTests: XCTestCase {
    private var support: URL!
    private let files = FileManager.default

    override func setUpWithError() throws {
        support = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: support, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? files.removeItem(at: support)
    }

    func testReleaseAndDevelopmentAreSeparateApps() {
        let release = SpinnetBuildIdentity.release, development = SpinnetBuildIdentity.development
        XCTAssertEqual(release.hostBundleIdentifier, "com.vulpsecula.SpinnetHost")
        XCTAssertEqual(development.hostBundleIdentifier, "com.vulpsecula.SpinnetHost.dev")
        XCTAssertFalse([release, development].contains { $0.hostBundleIdentifier == SpinnetBuildIdentity.betaHostBundleIdentifier })
        XCTAssertNotEqual(release.identifierPrefix, development.identifierPrefix,
                          "A development helper must never answer for a release Host")
        XCTAssertNotEqual(release.dataFolderName, development.dataFolderName)
        XCTAssertEqual(release.dataFolderName, SpinnetBuildIdentity.sharedDataFolderName, "Release keeps the beta's data")
        XCTAssertEqual(SpinnetBuildIdentity.current, .development, "Tests build the debug configuration")
    }

    func testTheRootHelperIsNamedByTheBuildIdentity() {
        let prefix = SpinnetBuildIdentity.current.identifierPrefix
        XCTAssertEqual(HomebrewSystemAuthorization.hostIdentifier, SpinnetBuildIdentity.current.hostBundleIdentifier)
        XCTAssertEqual(HomebrewHelperInstallation.label, prefix + ".privileged-tools")
        XCTAssertTrue(HomebrewHelperInstallation.machServices.allSatisfy { $0.hasPrefix(prefix + ".") })
        for name in HomebrewHelperInstallation.toolNames {
            XCTAssertEqual(HomebrewHelperInstallation.identifier(for: name)?.hasPrefix(prefix + "."), true, name)
        }
    }

    func testAReleaseNeverLooksUpTheBetasKeychainItems() {
        // Beta items trust only the beta's identity; reading one from a
        // release asks for the login password on every launch.
        let release = SpinnetBuildIdentity.release, development = SpinnetBuildIdentity.development
        for name in ["activation", "plugin-credential"] {
            let betas = "com.vulpsecula.Spinnet." + name
            XCTAssertNotEqual(release.keychainService(name), betas, name)
            XCTAssertNotEqual(development.keychainService(name), betas, name)
            XCTAssertNotEqual(release.keychainService(name), development.keychainService(name), name)
        }
        XCTAssertEqual(KeychainActivationStore.service, SpinnetBuildIdentity.current.keychainService("activation"))
        XCTAssertEqual(KeychainPluginCredentialStore.defaultService,
                       SpinnetBuildIdentity.current.keychainService("plugin-credential"))
    }

    private func write(_ text: String, to path: String, in folder: String) throws {
        let url = support.appendingPathComponent(folder).appendingPathComponent(path)
        try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ path: String, in folder: String) throws -> String {
        try String(contentsOf: support.appendingPathComponent(folder).appendingPathComponent(path), encoding: .utf8)
    }

    func testADevelopmentBuildStartsFromACopyOfTheSharedDataOnce() throws {
        try write("{}", to: "configuration.json", in: "Spinnet")
        try write("plugin", to: "Plugins/Example/manifest.json", in: "Spinnet")

        let folder = HostIdentityMigration.prepareDataDirectory(in: support, for: .development)

        XCTAssertEqual(folder.lastPathComponent, "Spinnet Dev")
        XCTAssertEqual(try read("Plugins/Example/manifest.json", in: "Spinnet Dev"), "plugin")
        try write("development edit", to: "configuration.json", in: "Spinnet Dev")
        try write("release edit", to: "configuration.json", in: "Spinnet")

        _ = HostIdentityMigration.prepareDataDirectory(in: support, for: .development)
        XCTAssertEqual(try read("configuration.json", in: "Spinnet Dev"), "development edit", "Copied only once")
        XCTAssertEqual(try read("configuration.json", in: "Spinnet"), "release edit", "The shared folder is untouched")
    }

    func testADevelopmentBuildWithNoSharedDataStartsEmpty() {
        let folder = HostIdentityMigration.prepareDataDirectory(in: support, for: .development)
        XCTAssertFalse(files.fileExists(atPath: folder.path))
    }

    func testAReleaseBuildKeepsTheSharedFolder() throws {
        try write("{}", to: "configuration.json", in: "Spinnet")
        let folder = HostIdentityMigration.prepareDataDirectory(in: support, for: .release)
        XCTAssertEqual(folder.lastPathComponent, "Spinnet")
        XCTAssertFalse(files.fileExists(atPath: support.appendingPathComponent("Spinnet Dev").path))
    }

    func testAReleaseAdoptsTheBetaSettingsOnlyWhileItsOwnAreEmpty() throws {
        let beta = "HostIdentityMigrationTests.beta." + UUID().uuidString
        let release = "HostIdentityMigrationTests.release." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: release))
        defer {
            defaults.removePersistentDomain(forName: beta)
            defaults.removePersistentDomain(forName: release)
        }
        XCTAssertFalse(HostIdentityMigration.adoptSettings(from: beta, into: release, defaults: defaults),
                       "A beta that left nothing has nothing to adopt")
        defaults.setPersistentDomain(["welcome-guide.finished": true, "AppleLanguages": ["zh-Hans"]], forName: beta)

        XCTAssertTrue(HostIdentityMigration.adoptSettings(from: beta, into: release, defaults: defaults))
        XCTAssertEqual(defaults.persistentDomain(forName: release)?["welcome-guide.finished"] as? Bool, true)
        XCTAssertEqual(defaults.persistentDomain(forName: release)?["AppleLanguages"] as? [String], ["zh-Hans"])

        defaults.setPersistentDomain(["welcome-guide.finished": false], forName: release)
        XCTAssertFalse(HostIdentityMigration.adoptSettings(from: beta, into: release, defaults: defaults))
        XCTAssertEqual(defaults.persistentDomain(forName: release)?["welcome-guide.finished"] as? Bool, false,
                       "Settings the release already has are never replaced")
    }

    func testAReleaseAsksMacOSForItsOwnSystemPermissions() throws {
        let beta = "HostIdentityMigrationTests.beta." + UUID().uuidString
        let release = "HostIdentityMigrationTests.release." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: release))
        defer {
            defaults.removePersistentDomain(forName: beta)
            defaults.removePersistentDomain(forName: release)
        }
        defaults.setPersistentDomain(["privacy.screen-recording-requested": true,
                                      "privacy.accessibility-requested": true], forName: beta)
        XCTAssertFalse(HostIdentityMigration.adoptSettings(from: beta, into: release, defaults: defaults),
                       "Only what macOS was asked: nothing to adopt")

        defaults.setPersistentDomain(["privacy.screen-recording-requested": true,
                                      "privacy.accessibility-requested": true,
                                      "welcome-guide.finished": true], forName: beta)
        XCTAssertTrue(HostIdentityMigration.adoptSettings(from: beta, into: release, defaults: defaults))
        let adopted = try XCTUnwrap(defaults.persistentDomain(forName: release))
        XCTAssertEqual(Set(adopted.keys), ["welcome-guide.finished"])
    }

    func testPackagingChecksChangeNothing() {
        XCTAssertTrue(HostIdentityMigration.isPackagingCheck(["SpinnetHost", "--verify-localizations"]))
        XCTAssertTrue(HostIdentityMigration.isPackagingCheck(["SpinnetHost", "--verify-homebrew-transport"]))
        XCTAssertFalse(HostIdentityMigration.isPackagingCheck(["SpinnetHost"]))
        XCTAssertFalse(HostIdentityMigration.isPackagingCheck(["SpinnetHost", "--install-plugins", "/tmp/x"]))
    }
}
