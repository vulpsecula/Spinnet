import XCTest
import SpinnetCore
@testable import SpinnetReviewedTools

final class HomebrewPrivilegeTests: XCTestCase {
    func testFullConfirmedBatchAuthorizationBoundCannotFailAfterOnlyOneHundredActions() throws {
        let casks = (0..<100).map { HomebrewPrivilegePlan.Cask(name: "fixture\($0)", version: "1", sha256: String(repeating: "a", count: 64), packages: ["first.pkg", "second.pkg"]) }
        let plan = try HomebrewPrivilegePlan(taskID: "activity_batch", prefix: "/opt/homebrew", casks: casks)
        XCTAssertGreaterThanOrEqual(plan.authorizationLimit, 200)
        XCTAssertLessThan(plan.authorizationLimit, 10_000)
        XCTAssertThrowsError(try HomebrewPrivilegePlan(taskID: "activity_batch", prefix: "/opt/homebrew", casks: [casks[0], casks[0]]))
    }
    func testPrivilegedInstallerIsBoundToReviewedTaskPackageAndRejectsArbitraryCommands() throws {
        let binding = HomebrewPrivilegePlan.Cask(name: "example", version: "1.0", sha256: String(repeating: "a", count: 64), packages: ["Example.pkg"])
        let plan = try HomebrewPrivilegePlan(taskID: "activity_123", prefix: "/opt/homebrew", casks: [binding])
        let request = HomebrewPrivilegeRequest(taskID: "activity_123", package: "example", operation: .installPackage,
            source: "/opt/homebrew/Caskroom/example/1.0/Example.pkg", sha256: binding.sha256, archive: "/Users/test/Library/Caches/Homebrew/downloads/source.archive", relativePackage: "Example.pkg")
        XCTAssertNoThrow(try plan.validate(request))
        var other = request; other.package = "other"
        XCTAssertThrowsError(try plan.validate(other))
        other = request; other.source = "/tmp/Example.pkg"
        XCTAssertThrowsError(try plan.validate(other))
        other = request; other.source = "/opt/homebrew/Caskroom/example/1.0/../evil.pkg"
        XCTAssertThrowsError(try plan.validate(other))
        other = request; other.taskID = "activity_other"
        XCTAssertThrowsError(try plan.validate(other))
        other = request; other.sha256 = String(repeating: "b", count: 64)
        XCTAssertThrowsError(try plan.validate(other))
        other = request; other.archive = ""
        XCTAssertThrowsError(try plan.validate(other))
        XCTAssertThrowsError(try JSONDecoder().decode(HomebrewPrivilegeRequest.self, from: Data("{\"taskID\":\"activity_123\",\"operation\":\"shell\"}".utf8)))
    }
    func testNativePackageChoicesAreFrozenHostDataAndDoNotAcceptClientOptionPaths() throws {
        let options = HomebrewPrivilegePlan.PackageInstaller(path: "Setup.pkg", choices: [.init(identifier: "choiceVBoxCLI", selected: true)], allowUntrusted: true)
        let cask = HomebrewPrivilegePlan.Cask(name: "example", version: "1", sha256: String(repeating: "a", count: 64), packages: ["Setup.pkg"], packageInstallers: [options])
        let plan = try HomebrewPrivilegePlan(taskID: "activity_123", prefix: "/opt/homebrew", casks: [cask])
        XCTAssertEqual(plan.casks[0].packageInstallers?.first?.choices?.first?.identifier, "choiceVBoxCLI")
        XCTAssertTrue(plan.casks[0].packageInstallers?.first?.allowUntrusted == true)
        let roundtrip = try HomebrewPrivilegePlan.decodeValidated(JSONEncoder().encode(plan))
        XCTAssertEqual(roundtrip, plan)
        let invalid = HomebrewPrivilegePlan.PackageInstaller(path: "../Setup.pkg", choices: [.init(identifier: "choiceVBoxCLI", selected: true)])
        XCTAssertThrowsError(try HomebrewPrivilegePlan(taskID: "activity_123", prefix: "/opt/homebrew", casks: [.init(name: "example", version: "1", sha256: String(repeating: "a", count: 64), packages: ["Setup.pkg"], packageInstallers: [invalid])]))
    }

    func testVendorScriptPlanFreezesArgumentsAndExactInputWithoutSearchPathFallback() throws {
        let script = HomebrewPrivilegePlan.NativeScript(phase: .install, executable: "Installer.app/Contents/MacOS/Installer", arguments: ["-silent"], input: "yes\n" + "next", mustSucceed: true)
        let cask = HomebrewPrivilegePlan.Cask(name: "example", version: "1", sha256: String(repeating: "a", count: 64), packages: [], nativeScripts: [script])
        let plan = try HomebrewPrivilegePlan(taskID: "activity_123", prefix: "/opt/homebrew", casks: [cask])
        XCTAssertEqual(plan.casks[0].nativeScripts?.first?.input, "yes\nnext")
        XCTAssertEqual(try HomebrewPrivilegePlan.decodeValidated(JSONEncoder().encode(plan)), plan)
        for path in ["/bin/sh", "../Installer", "Installer.app/../tool", "", "./installer"] {
            let invalid = HomebrewPrivilegePlan.NativeScript(phase: .install, executable: path, arguments: [])
            XCTAssertThrowsError(try HomebrewPrivilegePlan(taskID: "activity_123", prefix: "/opt/homebrew", casks: [.init(name: "example", version: "1", sha256: String(repeating: "a", count: 64), packages: [], nativeScripts: [invalid])]))
        }
    }

    func testVendorRequestCannotChooseExecutableArgumentsOrAnotherFrozenScript() throws {
        let script = HomebrewPrivilegePlan.NativeScript(phase: .install, executable: "Installer.app/Contents/MacOS/Installer", arguments: ["-silent"])
        let cask = HomebrewPrivilegePlan.Cask(name: "example", version: "1", sha256: String(repeating: "a", count: 64), packages: [], nativeScripts: [script])
        let plan = try HomebrewPrivilegePlan(taskID: "activity_123", prefix: "/opt/homebrew", casks: [cask])
        var request = HomebrewPrivilegeRequest(taskID: "activity_123", package: "example", operation: .executeVendorScript, source: "0", sha256: cask.sha256, archive: "/Users/test/Library/Caches/Homebrew/downloads/example.zip")
        XCTAssertNoThrow(try plan.validate(request))
        request.source = "/bin/sh"; XCTAssertThrowsError(try plan.validate(request))
        request.source = "1"; XCTAssertThrowsError(try plan.validate(request))
        request.source = "0"; request.sha256 = String(repeating: "b", count: 64); XCTAssertThrowsError(try plan.validate(request))
        request.sha256 = cask.sha256; request.relativePackage = "Other.app/tool"; XCTAssertThrowsError(try plan.validate(request))
    }

    func testElevationRejectsUnboundArchiveTraversalAndUninstallAsInstallation() throws {
        let cask = HomebrewPrivilegePlan.Cask(name: "example", version: "1.0", sha256: String(repeating: "a", count: 64), packages: ["Example.pkg"])
        let plan = try HomebrewPrivilegePlan(taskID: "activity_123", prefix: "/opt/homebrew", casks: [cask])
        var request = HomebrewPrivilegeRequest(taskID: "activity_123", package: "example", operation: .installPackage,
            source: "/opt/homebrew/Caskroom/example/1.0/Example.pkg", sha256: cask.sha256, archive: "/Users/test/Library/Caches/Homebrew/downloads/example.dmg", relativePackage: "../Example.pkg")
        XCTAssertThrowsError(try plan.validate(request))
        request.relativePackage = "Example.pkg"
        XCTAssertNoThrow(try plan.validate(request))
        XCTAssertThrowsError(try HomebrewPrivilegePlan(taskID: "activity_123", prefix: "/opt/homebrew", casks: [cask], operation: "uninstall"), "A pkg-only plan grants no uninstall authority")
    }

    func testInstallerCannotChooseAnotherPackageInsideTheApprovedDownload() throws {
        let cask = HomebrewPrivilegePlan.Cask(name: "example", version: "1.0", sha256: String(repeating: "a", count: 64), packages: ["Approved.pkg"])
        let plan = try HomebrewPrivilegePlan(taskID: "activity_123", prefix: "/opt/homebrew", casks: [cask])
        let other = HomebrewPrivilegeRequest(taskID: "activity_123", package: "example", operation: .installPackage,
            source: "/opt/homebrew/Caskroom/example/1.0/Other.pkg", sha256: String(repeating: "b", count: 64), archive: "/Users/test/Library/Caches/Homebrew/downloads/example.dmg", relativePackage: "Other.pkg")
        XCTAssertThrowsError(try plan.validate(other))
    }

    func testPrivilegedUninstallBindsOnlyItsFrozenLaunchDaemonAndRefusesOtherRootTargets() throws {
        let daemon = HomebrewPrivilegePlan.LaunchDaemon(label: "org.example.helper", sha256: String(repeating: "a", count: 64), device: 1, inode: 42)
        let cask = HomebrewPrivilegePlan.Cask(name: "example", version: "1", sha256: "", packages: [], launchDaemons: [daemon])
        let plan = try HomebrewPrivilegePlan(taskID: "activity_123", prefix: "/opt/homebrew", casks: [cask], operation: "uninstall")
        var request = HomebrewPrivilegeRequest(taskID: "activity_123", package: "example", operation: .removeLaunchDaemon, source: "org.example.helper", sha256: daemon.sha256)
        XCTAssertNoThrow(try plan.validate(request))
        request.source = "org.other.helper"; XCTAssertThrowsError(try plan.validate(request))
        request.source = daemon.label; request.sha256 = String(repeating: "b", count: 64); XCTAssertThrowsError(try plan.validate(request))
        request.sha256 = daemon.sha256; request.package = "other"; XCTAssertThrowsError(try plan.validate(request))
        XCTAssertThrowsError(try HomebrewPrivilegePlan(taskID: "activity_123", prefix: "/opt/homebrew", casks: [cask], operation: "install"))
        XCTAssertFalse(HomebrewPrivilegePlan.validLaunchDaemonLabel("../other")); XCTAssertFalse(HomebrewPrivilegePlan.validLaunchDaemonLabel("org.example.*")); XCTAssertFalse(HomebrewPrivilegePlan.validLaunchDaemonLabel("com.apple.system"))
    }

    func testReceiptUninstallRequiresFrozenManifestAndAllowsOnlyExactEmptyManifestRecovery() throws {
        let receipt = HomebrewPrivilegePlan.Receipt(identifier: "org.example.pkg", manifestSHA256: String(repeating: "a", count: 64), fileCount: 12)
        let cask = HomebrewPrivilegePlan.Cask(name: "example", version: "1", sha256: "", packages: [], receipts: [receipt])
        let plan = try HomebrewPrivilegePlan(taskID: "activity_123", prefix: "/opt/homebrew", casks: [cask], operation: "uninstall")
        var request = HomebrewPrivilegeRequest(taskID: "activity_123", package: "example", operation: .removeReceipt, source: receipt.identifier, sha256: receipt.manifestSHA256)
        XCTAssertNoThrow(try plan.validate(request))
        request.source = "org.other.pkg"; XCTAssertThrowsError(try plan.validate(request))
        request.source = receipt.identifier; request.sha256 = String(repeating: "b", count: 64); XCTAssertThrowsError(try plan.validate(request))
        let empty = HomebrewPrivilegePlan.Receipt(identifier: receipt.identifier, manifestSHA256: receipt.manifestSHA256, fileCount: 0)
        let recovery = try HomebrewPrivilegePlan(taskID: "activity_123", prefix: "/opt/homebrew", casks: [.init(name: "example", version: "1", sha256: "", packages: [], receipts: [empty])], operation: "uninstall")
        XCTAssertNoThrow(try recovery.validate(.init(taskID: recovery.taskID, package: "example", operation: .removeReceipt, source: empty.identifier, sha256: empty.manifestSHA256)))
        XCTAssertThrowsError(try recovery.validate(.init(taskID: recovery.taskID, package: "example", operation: .removeReceipt, source: "org.other.pkg", sha256: empty.manifestSHA256)))
        let unsealed = HomebrewPrivilegePlan.Receipt(identifier: empty.identifier, manifestSHA256: "", fileCount: 0)
        XCTAssertThrowsError(try HomebrewPrivilegePlan(taskID: "activity_123", prefix: "/opt/homebrew", casks: [.init(name: "example", version: "1", sha256: "", packages: [], receipts: [unsealed])], operation: "uninstall"))
        XCTAssertFalse(HomebrewPrivilegePlan.validReceiptID("org.example.*")); XCTAssertFalse(HomebrewPrivilegePlan.validReceiptID("com.apple.system"))
    }

    func testUpgradeMayRemoveOnlyItsFrozenInstalledPredecessorBeforeInstallingSuccessor() throws {
        let receipt = HomebrewPrivilegePlan.Receipt(identifier: "org.example.pkg", manifestSHA256: String(repeating: "a", count: 64), fileCount: 12)
        let cask = HomebrewPrivilegePlan.Cask(name: "example", version: "2", sha256: String(repeating: "b", count: 64), packages: ["New.pkg"], receipts: [receipt], uninstallVersion: "1")
        let plan = try HomebrewPrivilegePlan(taskID: "activity_123", prefix: "/opt/homebrew", casks: [cask], operation: "upgrade")
        let removal = HomebrewPrivilegeRequest(taskID: "activity_123", package: "example", operation: .removeReceipt, source: receipt.identifier, sha256: receipt.manifestSHA256)
        XCTAssertNoThrow(try plan.validate(removal))
        let install = HomebrewPrivilegeRequest(taskID: "activity_123", package: "example", operation: .installPackage, source: "/opt/homebrew/Caskroom/example/2/New.pkg", sha256: cask.sha256, archive: "/private/tmp/frozen-download.pkg", relativePackage: "New.pkg")
        XCTAssertNoThrow(try plan.validate(install))
        var previous = install; previous.source = "/opt/homebrew/Caskroom/example/1/New.pkg"; XCTAssertThrowsError(try plan.validate(previous))
        XCTAssertThrowsError(try HomebrewPrivilegePlan(taskID: "activity_123", prefix: "/opt/homebrew", casks: [cask], operation: "install"))
    }
    func testReceiptManifestIgnoresNativePlistKeyOrderWithoutLosingTypedValues() throws {
        let first = Data("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>pkgid</key><string>org.example.pkg</string><key>install-time</key><integer>12</integer></dict></plist>".utf8)
        let second = Data("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>install-time</key><integer>12</integer><key>pkgid</key><string>org.example.pkg</string></dict></plist>".utf8)
        XCTAssertEqual(try HomebrewReceiptRemoval.manifestDigest(exported: first, entries: []), try HomebrewReceiptRemoval.manifestDigest(exported: second, entries: []))
        let changed = Data("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>install-time</key><string>12</string><key>pkgid</key><string>org.example.pkg</string></dict></plist>".utf8)
        XCTAssertNotEqual(try HomebrewReceiptRemoval.manifestDigest(exported: first, entries: []), try HomebrewReceiptRemoval.manifestDigest(exported: changed, entries: []))
    }
    func testRecordedReceiptPatternsResolveToBoundedExactNonAppleTargets() throws {
        let ids = try HomebrewReceiptRemoval.resolvePatterns(["org.virtualbox.pkg.*"], deadline: Date().addingTimeInterval(1)) { arguments, _ in
            XCTAssertEqual(arguments, ["--pkgs=org.virtualbox.pkg.*"])
            return Data("org.virtualbox.pkg.core\norg.virtualbox.pkg.cli\n".utf8)
        }
        XCTAssertEqual(ids, ["org.virtualbox.pkg.cli", "org.virtualbox.pkg.core"])
        XCTAssertThrowsError(try HomebrewReceiptRemoval.resolvePatterns([".*"], deadline: Date().addingTimeInterval(1)) { _, _ in Data("com.apple.pkg.system\n".utf8) })
    }
    func testNativeRelativeReceiptInstallLocationIsAnchoredToItsVolume() throws {
        XCTAssertEqual(try HomebrewReceiptRemoval.installLocation(volume: "/", location: "Applications"), "/Applications")
        XCTAssertEqual(try HomebrewReceiptRemoval.installLocation(volume: "/", location: "Applications/GarageBand.app/Contents/"), "/Applications/GarageBand.app/Contents")
        XCTAssertEqual(try HomebrewReceiptRemoval.installLocation(volume: "/", location: ""), "/")
        XCTAssertThrowsError(try HomebrewReceiptRemoval.installLocation(volume: "/", location: "../Applications"))
        XCTAssertThrowsError(try HomebrewReceiptRemoval.installLocation(volume: "/Volumes/Other", location: "Applications"))
    }
    func testTypedNativeChoicesIncludeBooleanVisibilityAndEnablementWithoutRawXMLAuthority() throws {
        let options = HomebrewPrivilegePlan.PackageInstaller(path: "Owned.pkg", choices: [
            .init(identifier: "owned.choice", selected: true),
            .init(identifier: "owned.choice", attribute: .enabled, selected: false),
            .init(identifier: "owned.choice", attribute: .visible, selected: false)])
        let xml = try XCTUnwrap(options.choicesXML())
        let entries = try XCTUnwrap(PropertyListSerialization.propertyList(from: xml, format: nil) as? [[String: Any]])
        XCTAssertEqual(entries.map { $0["choiceAttribute"] as? String }, ["selected", "enabled", "visible"])
        XCTAssertEqual(entries.map { $0["attributeSetting"] as? Int }, [1, 0, 0])
        let duplicate = HomebrewPrivilegePlan.PackageInstaller(path: "Owned.pkg", choices: [
            .init(identifier: "owned.choice", attribute: .enabled, selected: false),
            .init(identifier: "owned.choice", attribute: .enabled, selected: true)])
        XCTAssertThrowsError(try duplicate.choicesXML())
    }

    func testNativePackageChoicesPreserveTypedCustomLocationAndLegacyToggles() throws {
        let customized = HomebrewPrivilegePlan.PackageInstaller(path: "Owned.mpkg", choices: [.init(identifier: "owned.choice", customLocation: "/Applications/Owned")])
        let entries = try XCTUnwrap(PropertyListSerialization.propertyList(from: try XCTUnwrap(customized.choicesXML()), format: nil) as? [[String: Any]])
        XCTAssertEqual(entries.first?["choiceAttribute"] as? String, "customLocation")
        XCTAssertEqual(entries.first?["attributeSetting"] as? String, "/Applications/Owned")
        let toggles = HomebrewPrivilegePlan.PackageInstaller(path: "Owned.pkg", choiceToggles: ["owned.one", "owned.two"])
        XCTAssertEqual(try PropertyListSerialization.propertyList(from: XCTUnwrap(toggles.choicesXML()), format: nil) as? [String], ["owned.one", "owned.two"])
        XCTAssertThrowsError(try HomebrewPrivilegePlan.PackageInstaller(path: "Owned.pkg", choices: [.init(identifier: "owned.choice", customLocation: "../escape")]).choicesXML())
        XCTAssertThrowsError(try HomebrewPrivilegePlan.PackageInstaller(path: "Owned.pkg", choices: [.init(identifier: "owned.choice", selected: true)], choiceToggles: ["owned.choice"]).choicesXML())
    }

}
