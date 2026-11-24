import XCTest
import ServiceManagement
import CryptoKit
@testable import SpinnetCore
@testable import SpinnetReviewedTools

final class HomebrewSystemServicePreparationTests: XCTestCase {
    func testReinstallationAlwaysInstallsAgainAndChecksTheResult() throws {
        var state = HomebrewHelperInstallation.Status.installed, installs = 0
        try HomebrewSystemAuthorization.reinstallService(status: { state }, install: { installs += 1; state = .installed },
            openSettings: { XCTFail("Installed after reinstalling") }, bundledServiceExists: true)
        XCTAssertEqual(installs, 1)
    }

    func testReinstallationThatTheLoginItemsSwitchBlocksOpensLoginItems() {
        var opened = false
        XCTAssertThrowsError(try HomebrewSystemAuthorization.reinstallService(status: { .approvalRequired }, install: {},
            openSettings: { opened = true }, bundledServiceExists: true)) {
            XCTAssertTrue($0.localizedDescription.contains("Login Items"))
        }
        XCTAssertTrue(opened)
    }

    func testAppleIssuedSignerRequiresTheSameTeam() throws {
        let expression = try HomebrewSystemAuthorization.requirement(identifier: "com.vulpsecula.SpinnetHost.preview", signer: .team("3T85X744CB"))
        XCTAssertEqual(expression, "anchor apple generic and identifier \"com.vulpsecula.SpinnetHost.preview\" and certificate leaf[subject.OU] = \"3T85X744CB\"")
        var requirement: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(expression as CFString, [], &requirement), errSecSuccess)
    }

    func testSelfSignedReleaseSignerPinsTheExactLeafCertificate() throws {
        let hash = String(repeating: "ab", count: 20)
        let expression = try HomebrewSystemAuthorization.requirement(identifier: "com.vulpsecula.SpinnetHost.task-runner", signer: .certificate(sha1: hash))
        XCTAssertEqual(expression, "identifier \"com.vulpsecula.SpinnetHost.task-runner\" and certificate leaf = H\"\(hash)\"")
        var requirement: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(expression as CFString, [], &requirement), errSecSuccess)
    }

    func testMalformedSignerIdentitiesNeverBecomeRequirements() {
        for signer: HomebrewSystemAuthorization.Signer in [.team(""), .team("3t85x744cb"), .team("ABC\" or true"),
                                                           .certificate(sha1: ""), .certificate(sha1: "AB"), .certificate(sha1: String(repeating: "g", count: 40))] {
            XCTAssertThrowsError(try HomebrewSystemAuthorization.requirement(identifier: "com.vulpsecula.SpinnetHost.preview", signer: signer))
        }
    }

    func testSignerPrefersTeamAndRefusesAdHocSignatures() throws {
        let certificate = Data([0x30, 0x03, 0x02, 0x01, 0x01])
        XCTAssertEqual(HomebrewSystemAuthorization.signer(team: "3T85X744CB", leafCertificate: certificate), .team("3T85X744CB"))
        XCTAssertEqual(HomebrewSystemAuthorization.signer(team: nil, leafCertificate: certificate),
                       .certificate(sha1: Insecure.SHA1.hash(data: certificate).map { String(format: "%02X", $0) }.joined()))
        XCTAssertNil(HomebrewSystemAuthorization.signer(team: nil, leafCertificate: nil))
    }

    func testServiceAndSigningIdentitiesUseTheHostPrefix() {
        XCTAssertEqual(HomebrewSystemAuthorization.hostIdentifier, "com.vulpsecula.SpinnetHost.dev")
        XCTAssertEqual(HomebrewSystemAuthorization.helperIdentifier, "com.vulpsecula.SpinnetHost.dev.privileged-tools")
        XCTAssertEqual(HomebrewSystemAuthorization.service, "com.vulpsecula.SpinnetHost.dev.reviewed-tools")
        XCTAssertEqual(HomebrewSystemAuthorization.right, "com.vulpsecula.SpinnetHost.dev.install-reviewed-package")
        XCTAssertEqual(HomebrewSystemAuthorization.runnerIdentifier, "com.vulpsecula.SpinnetHost.dev.task-runner")
        XCTAssertEqual(HomebrewSystemAuthorization.clientIdentifier, "com.vulpsecula.SpinnetHost.dev.authorization-client")
    }
    func testRequestRightSurvivesTheClientToHelperHandoffWithoutSharingCredentials() throws {
        let definition = HomebrewSystemAuthorization.requestRightDefinition
        let timeout = try XCTUnwrap(definition["timeout"] as? Int)
        XCTAssertGreaterThan(timeout, 0, "A zero-second right expires before Root can verify the external form")
        XCTAssertLessThanOrEqual(timeout, 120)
        XCTAssertEqual(definition["shared"] as? Bool, false)
        XCTAssertEqual(definition["authenticate-user"] as? Bool, true)
        XCTAssertEqual(definition["allow-root"] as? Bool, false)
        XCTAssertEqual(definition["group"] as? String, "admin")
    }
    func testMissingInstallationWithCompleteBundledHelperInstallsIt() throws {
        var state = HomebrewHelperInstallation.Status.notInstalled
        var installs = 0
        try HomebrewSystemAuthorization.prepareService(status: { state }, install: {
            installs += 1
            state = .installed
        }, openSettings: { XCTFail("An installed helper needs no Settings prompt") }, bundledServiceExists: true)
        XCTAssertEqual(installs, 1)
    }
    func testABlockedInstallationOpensLoginItemsAndIsNotInstalledAgainOnRetry() throws {
        for initial in [HomebrewHelperInstallation.Status.notInstalled, .approvalRequired] {
            var state = initial
            var installs = 0, prompts = 0
            XCTAssertThrowsError(try HomebrewSystemAuthorization.prepareService(status: { state }, install: {
                installs += 1; state = .approvalRequired
            }, openSettings: { prompts += 1 }, bundledServiceExists: true)) {
                XCTAssertTrue($0.localizedDescription.contains("Login Items"))
            }
            XCTAssertEqual(installs, initial == .approvalRequired ? 0 : 1)
            XCTAssertEqual(prompts, 1)
        }
    }
    func testInstalledHelperIsNotInstalledAgainOrSentToSettings() throws {
        try HomebrewSystemAuthorization.prepareService(status: { .installed }, install: { XCTFail("Already installed") },
            openSettings: { XCTFail("Already approved") }, bundledServiceExists: true)
    }
    func testIncompleteBundleCannotInstallOrBeReportedAsAnApprovalProblem() {
        XCTAssertThrowsError(try HomebrewSystemAuthorization.prepareService(status: { .notInstalled }, install: { XCTFail("Missing payload") },
            openSettings: { XCTFail("No installed item to approve") }, bundledServiceExists: false)) {
            XCTAssertTrue($0.localizedDescription.contains("missing from this app bundle"))
            XCTAssertFalse($0.localizedDescription.contains("Login Items"))
        }
    }
    func testInstallationFailureKeepsItsDiagnosticAndDoesNotRequestApproval() {
        XCTAssertThrowsError(try HomebrewSystemAuthorization.prepareService(status: { .notInstalled }, install: {
            throw PluginHostServiceError.unavailable("launchctl bootstrap failed: 5: Input/output error")
        }, openSettings: { XCTFail("Installation failed") }, bundledServiceExists: true)) {
            XCTAssertTrue($0.localizedDescription.contains("launchctl bootstrap failed"))
            XCTAssertFalse($0.localizedDescription.contains("Login Items"))
        }
    }
    func testUnresolvedInstallationDoesNotLoopOrPretendApprovalWillFixIt() {
        var installs = 0
        XCTAssertThrowsError(try HomebrewSystemAuthorization.prepareService(status: { .notInstalled }, install: { installs += 1 },
            openSettings: { XCTFail("No approval-pending helper") }, bundledServiceExists: true)) {
            XCTAssertTrue($0.localizedDescription.contains("after the installation attempt"))
            XCTAssertFalse($0.localizedDescription.contains("Login Items"))
        }
        XCTAssertEqual(installs, 1)
    }
}
