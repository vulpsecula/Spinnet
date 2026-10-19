import XCTest
import ServiceManagement
@testable import SpinnetCore

final class HomebrewSystemServicePreparationTests: XCTestCase {
    func testDailyBuildKeepsItsServiceAndSigningIdentitiesSeparateFromLifecycleFixtures() {
        XCTAssertEqual(HomebrewSystemAuthorization.hostIdentifier, "com.vulpsecula.SpinnetHost.preview")
        XCTAssertEqual(HomebrewSystemAuthorization.helperIdentifier, "com.vulpsecula.SpinnetHost.privileged-tools")
        XCTAssertEqual(HomebrewSystemAuthorization.service, "com.vulpsecula.SpinnetHost.reviewed-tools")
        XCTAssertEqual(HomebrewSystemAuthorization.right, "com.vulpsecula.SpinnetHost.install-reviewed-package")
        XCTAssertEqual(HomebrewSystemAuthorization.runnerIdentifier, "com.vulpsecula.SpinnetHost.task-runner")
        XCTAssertEqual(HomebrewSystemAuthorization.clientIdentifier, "com.vulpsecula.SpinnetHost.authorization-client")
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
    func testMissingRegistrationWithCompleteBundledHelperAttemptsRegistration() throws {
        var state = SMAppService.Status.notFound
        var registrations = 0
        try HomebrewSystemAuthorization.prepareService(status: { state }, register: {
            registrations += 1
            state = .enabled
        }, openSettings: { XCTFail("An enabled service needs no Settings prompt") }, bundledServiceExists: true)
        XCTAssertEqual(registrations, 1)
    }
    func testFirstRegistrationWaitsForApprovalAndDoesNotRepeatRegistrationOnRetry() throws {
        for initial in [SMAppService.Status.notFound, .notRegistered, .requiresApproval] {
            var state = initial
            var registrations = 0, prompts = 0
            XCTAssertThrowsError(try HomebrewSystemAuthorization.prepareService(status: { state }, register: {
                registrations += 1; state = .requiresApproval
            }, openSettings: { prompts += 1 }, bundledServiceExists: true)) {
                XCTAssertTrue($0.localizedDescription.contains("Login Items"))
            }
            XCTAssertEqual(registrations, initial == .requiresApproval ? 0 : 1)
            XCTAssertEqual(prompts, 1)
        }
    }
    func testEnabledHelperDoesNotChangeRegistrationOrOpenSettings() throws {
        try HomebrewSystemAuthorization.prepareService(status: { .enabled }, register: { XCTFail("Already enabled") },
            openSettings: { XCTFail("Already approved") }, bundledServiceExists: true)
    }
    func testIncompleteBundleCannotRegisterOrBeReportedAsAnApprovalProblem() {
        for state in [SMAppService.Status.notFound, .notRegistered] {
            XCTAssertThrowsError(try HomebrewSystemAuthorization.prepareService(status: { state }, register: { XCTFail("Missing payload") },
                openSettings: { XCTFail("No registered item to approve") }, bundledServiceExists: false)) {
                XCTAssertTrue($0.localizedDescription.contains("missing from this app bundle"))
                XCTAssertFalse($0.localizedDescription.contains("Login Items"))
            }
        }
    }
    func testRegistrationFailureKeepsSystemDiagnosticAndDoesNotRequestApproval() {
        XCTAssertThrowsError(try HomebrewSystemAuthorization.prepareService(status: { .notFound }, register: {
            throw NSError(domain: "SMAppServiceErrorDomain", code: 22, userInfo: [NSLocalizedDescriptionKey: "Invalid daemon configuration"])
        }, openSettings: { XCTFail("Registration failed") }, bundledServiceExists: true)) {
            XCTAssertTrue($0.localizedDescription.contains("SMAppServiceErrorDomain 22"))
            XCTAssertTrue($0.localizedDescription.contains("Invalid daemon configuration"))
            XCTAssertFalse($0.localizedDescription.contains("Login Items"))
        }
    }
    func testUnresolvedRegistrationDoesNotLoopOrPretendApprovalWillFixIt() {
        for state in [SMAppService.Status.notFound, .notRegistered] {
            var registrations = 0
            XCTAssertThrowsError(try HomebrewSystemAuthorization.prepareService(status: { state }, register: { registrations += 1 },
                openSettings: { XCTFail("No approval-pending service") }, bundledServiceExists: true)) {
                XCTAssertTrue($0.localizedDescription.contains("after the registration attempt"))
                XCTAssertFalse($0.localizedDescription.contains("Login Items"))
            }
            XCTAssertEqual(registrations, 1)
        }
    }
}
