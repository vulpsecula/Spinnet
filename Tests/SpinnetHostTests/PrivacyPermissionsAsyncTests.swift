import Combine
import XCTest
import SpinnetCore
@testable import SpinnetHost

final class PrivacyPermissionsAsyncTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "SpinnetHostTests.PrivacyAsync.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testBackgroundRefreshReturnsBeforeTheResultAndPublishesAuthorityOnMain() {
        let service = BackgroundStatusRequestRecorder()
        let model = makeModel(service)
        var authorityChanges = 0
        let applied = expectation(description: "background authority published on main")
        model.onAuthorityChanged = {
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(model.backgroundOperationsStatus, .approvalRequired)
            authorityChanges += 1
            applied.fulfill()
        }
        var publications: [HostBackgroundOperationsStatus] = []
        let observation = model.$backgroundOperationsStatus.dropFirst().sink { status in
            XCTAssertTrue(Thread.isMainThread)
            publications.append(status)
        }

        model.refreshBackgroundOperationsStatusAsynchronously()

        XCTAssertEqual(model.backgroundOperationsStatus, .notEnabled)
        XCTAssertEqual(service.pending.count, 1)
        XCTAssertEqual(service.checks, 1, "The activation request does not repeat the synchronous initializer check")
        let complete = service.pending.removeFirst()
        DispatchQueue.global().async { complete(.approvalRequired) }
        wait(for: [applied], timeout: 2)
        XCTAssertEqual(authorityChanges, 1)
        XCTAssertEqual(publications, [.approvalRequired])
        withExtendedLifetime(observation) {}
    }

    func testUnchangedAsyncStatusDoesNotPublishOrSignalAuthority() {
        let service = BackgroundStatusRequestRecorder()
        let model = makeModel(service)
        var authorityChanges = 0
        var publications = 0
        model.onAuthorityChanged = { authorityChanges += 1 }
        let observation = model.$backgroundOperationsStatus.dropFirst().sink { _ in publications += 1 }

        model.refreshBackgroundOperationsStatusAsynchronously()
        service.pending.removeFirst()(.notEnabled)

        XCTAssertEqual(authorityChanges, 0)
        XCTAssertEqual(publications, 0)
        withExtendedLifetime(observation) {}
    }

    func testLateAsyncStatusCannotOverwriteASynchronousPermissionRefresh() {
        let service = BackgroundStatusRequestRecorder()
        let model = makeModel(service)
        var authorityChanges = 0
        model.onAuthorityChanged = { authorityChanges += 1 }
        model.refreshBackgroundOperationsStatusAsynchronously()
        let stale = service.pending.removeFirst()
        service.status = .enabled
        model.refreshSystemPermissionStatus()
        XCTAssertEqual(model.backgroundOperationsStatus, .enabled)
        XCTAssertEqual(authorityChanges, 1)
        stale(.approvalRequired)
        XCTAssertEqual(model.backgroundOperationsStatus, .enabled)
        XCTAssertEqual(authorityChanges, 1)
        model.refreshBackgroundOperationsStatusAsynchronously()
        XCTAssertEqual(service.pending.count, 1, "A subsequent request still runs after the obsolete callback is discarded")
        service.pending.removeFirst()(.notEnabled)
        XCTAssertEqual(model.backgroundOperationsStatus, .notEnabled)
        XCTAssertEqual(authorityChanges, 2)
    }

    func testRepeatedActivationRefreshesCoalesceAndApplyOnlyTheFreshResult() {
        let service = BackgroundStatusRequestRecorder()
        let model = makeModel(service)
        var authorityChanges = 0
        model.onAuthorityChanged = { authorityChanges += 1 }

        model.refreshBackgroundOperationsStatusAsynchronously()
        model.refreshBackgroundOperationsStatusAsynchronously()
        model.refreshBackgroundOperationsStatusAsynchronously()

        XCTAssertEqual(service.pending.count, 1, "Activation bursts keep only one status read in flight")
        XCTAssertEqual(service.requests, 1)
        service.pending.removeFirst()(.approvalRequired)
        XCTAssertEqual(model.backgroundOperationsStatus, .notEnabled, "A newer activation made this read obsolete")
        XCTAssertEqual(authorityChanges, 0)
        XCTAssertEqual(service.pending.count, 1)
        XCTAssertEqual(service.requests, 2, "Repeated activations schedule one fresh read after the first finishes")
        service.pending.removeFirst()(.enabled)
        XCTAssertEqual(model.backgroundOperationsStatus, .enabled)
        XCTAssertEqual(authorityChanges, 1)
    }

    func testARequestAfterSynchronousRefreshWaitsForTheObsoleteReadBeforeStarting() {
        let service = BackgroundStatusRequestRecorder()
        let model = makeModel(service)
        var authorityChanges = 0
        model.onAuthorityChanged = { authorityChanges += 1 }
        model.refreshBackgroundOperationsStatusAsynchronously()
        let stale = service.pending.removeFirst()
        service.status = .enabled
        model.refreshSystemPermissionStatus()

        model.refreshBackgroundOperationsStatusAsynchronously()
        XCTAssertTrue(service.pending.isEmpty, "Invalidation does not cancel the system read already in flight")
        stale(.approvalRequired)
        XCTAssertEqual(model.backgroundOperationsStatus, .enabled)
        XCTAssertEqual(authorityChanges, 1)
        XCTAssertEqual(service.pending.count, 1)
        service.pending.removeFirst()(.notEnabled)
        XCTAssertEqual(model.backgroundOperationsStatus, .notEnabled)
        XCTAssertEqual(authorityChanges, 2)
    }

    func testImmediatePermissionRefreshDoesNotInvalidateTheBackgroundRequestItDeliberatelySkips() {
        let service = BackgroundStatusRequestRecorder()
        let model = makeModel(service)
        var authorityChanges = 0
        model.onAuthorityChanged = { authorityChanges += 1 }
        model.refreshBackgroundOperationsStatusAsynchronously()

        model.refreshSystemPermissionStatus(includingBackgroundOperations: false)
        XCTAssertEqual(service.checks, 1)
        service.pending.removeFirst()(.enabled)

        XCTAssertEqual(model.backgroundOperationsStatus, .enabled)
        XCTAssertEqual(authorityChanges, 1)
    }

    func testExplicitBackgroundManagementWinsOverAnEarlierAsyncStatus() {
        let service = BackgroundStatusRequestRecorder()
        let model = makeModel(service)
        var authorityChanges = 0
        model.onAuthorityChanged = { authorityChanges += 1 }
        model.refreshBackgroundOperationsStatusAsynchronously()
        let stale = service.pending.removeFirst()
        // An in-flight callback can arrive while the explicit operation is
        // running, before its synchronous final refresh has a chance to win.
        service.beforeEnable = { stale(.approvalRequired) }

        model.manageBackgroundOperations()

        XCTAssertEqual(service.enableRequests, 1)
        XCTAssertEqual(model.backgroundOperationsStatus, .enabled)
        XCTAssertEqual(authorityChanges, 1)
        stale(.notEnabled)
        XCTAssertEqual(model.backgroundOperationsStatus, .enabled)
        XCTAssertEqual(authorityChanges, 1)
    }

    func testEnabledAsyncStatusClearsAnEarlierSetupErrorWithoutRegisteringAgain() {
        let service = BackgroundStatusRequestRecorder()
        service.enableFailure = PluginHostServiceError.unavailable("Registration failed")
        let model = makeModel(service)
        model.manageBackgroundOperations()
        XCTAssertNotNil(model.backgroundOperationsError)
        XCTAssertEqual(service.enableRequests, 1)
        var authorityChanges = 0
        model.onAuthorityChanged = { authorityChanges += 1 }

        model.refreshBackgroundOperationsStatusAsynchronously()
        service.pending.removeFirst()(.enabled)

        XCTAssertEqual(model.backgroundOperationsStatus, .enabled)
        XCTAssertNil(model.backgroundOperationsError)
        XCTAssertEqual(service.enableRequests, 1, "A read-only status refresh cannot enable background work")
        XCTAssertEqual(authorityChanges, 1)
    }

    func testDefaultAsyncRequestPreservesInjectedSynchronousCheckBehavior() {
        let service = BackgroundStatusRequestRecorder()
        let model = makeModel(service, requestAsynchronously: false)
        service.status = .approvalRequired

        model.refreshBackgroundOperationsStatusAsynchronously()

        XCTAssertEqual(model.backgroundOperationsStatus, .approvalRequired)
        XCTAssertEqual(service.checks, 2)
        XCTAssertTrue(service.pending.isEmpty)
    }

    private func makeModel(_ service: BackgroundStatusRequestRecorder,
                           requestAsynchronously: Bool = true) -> PrivacyPermissionsModel {
        PrivacyPermissionsModel(
            grantStore: .init(), manifests: { [] },
            accessibilityPermissionCheck: { false }, defaults: defaults,
            screenRecordingPermissionCheck: { false },
            screenRecordingPermissionRequest: { XCTFail("A status refresh cannot request Screen Recording"); return false },
            backgroundOperationsCheck: { service.checks += 1; return service.status },
            backgroundOperationsRequest: requestAsynchronously ? service.request : nil,
            backgroundOperationsEnable: {
                service.enableRequests += 1
                service.beforeEnable?()
                if let error = service.enableFailure { throw error }
                service.status = .enabled
            },
            openBackgroundOperationsSettings: { XCTFail("A status refresh cannot open System Settings") }
        )
    }
}

private final class BackgroundStatusRequestRecorder {
    var status = HostBackgroundOperationsStatus.notEnabled
    var checks = 0
    var requests = 0
    var enableRequests = 0
    var enableFailure: Error?
    var beforeEnable: (() -> Void)?
    var pending: [(HostBackgroundOperationsStatus) -> Void] = []
    func request(_ completion: @escaping (HostBackgroundOperationsStatus) -> Void) {
        requests += 1
        pending.append(completion)
    }
}
