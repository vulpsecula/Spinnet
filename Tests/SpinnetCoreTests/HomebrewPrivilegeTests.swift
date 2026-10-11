import XCTest
import SpinnetCore

final class HomebrewPrivilegeTests: XCTestCase {
    func testPrivilegedInstallerIsBoundToReviewedTaskPackageAndRejectsArbitraryCommands() throws {
        let binding = HomebrewPrivilegePlan.Cask(name: "example", version: "1.0", sha256: String(repeating: "a", count: 64), packages: ["Example.pkg"])
        let plan = try HomebrewPrivilegePlan(taskID: "activity_123", prefix: "/opt/homebrew", casks: [binding])
        let request = HomebrewPrivilegeRequest(taskID: "activity_123", package: "example", operation: .installPackage,
            source: "/opt/homebrew/Caskroom/example/1.0/Example.pkg", sha256: String(repeating: "b", count: 64), relativePackage: "Example.pkg")
        XCTAssertNoThrow(try plan.validate(request))
        var other = request; other.package = "other"
        XCTAssertThrowsError(try plan.validate(other))
        other = request; other.source = "/tmp/Example.pkg"
        XCTAssertThrowsError(try plan.validate(other))
        other = request; other.source = "/opt/homebrew/Caskroom/example/1.0/../evil.pkg"
        XCTAssertThrowsError(try plan.validate(other))
        other = request; other.taskID = "activity_other"
        XCTAssertThrowsError(try plan.validate(other))
        XCTAssertThrowsError(try JSONDecoder().decode(HomebrewPrivilegeRequest.self, from: Data("{\"taskID\":\"activity_123\",\"operation\":\"shell\"}".utf8)))
    }
    func testElevationRejectsUnboundArchiveTraversalAndUninstallAsInstallation() throws {
        let cask = HomebrewPrivilegePlan.Cask(name: "example", version: "1.0", sha256: String(repeating: "a", count: 64), packages: ["Example.pkg"])
        let plan = try HomebrewPrivilegePlan(taskID: "activity_123", prefix: "/opt/homebrew", casks: [cask])
        var request = HomebrewPrivilegeRequest(taskID: "activity_123", package: "example", operation: .installPackage,
            source: "/opt/homebrew/Caskroom/example/1.0/Example.pkg", sha256: String(repeating: "b", count: 64), archive: "/Users/test/Library/Caches/Homebrew/downloads/example.dmg", relativePackage: "../Example.pkg")
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
}
