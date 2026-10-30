import Combine
import XCTest
@testable import SpinnetHost

final class LaunchAtLoginAsyncTests: XCTestCase {
    func testAsyncStatusPublishesOnMainThread() {
        let service = ControlledLoginItemService()
        let model = LaunchAtLoginModel(service: service)
        let published = expectation(description: "status published on main")
        let observer = model.$status.dropFirst().sink { value in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(value, .requiresApproval)
            published.fulfill()
        }
        model.refreshAsynchronously()
        XCTAssertEqual(model.status, .notRegistered)
        let complete = service.pending.removeFirst()
        DispatchQueue.global().async { complete(.requiresApproval) }
        wait(for: [published], timeout: 2)
        withExtendedLifetime(observer) {}
    }

    func testLateAsyncStatusCannotOverwriteUserChange() {
        let service = ControlledLoginItemService()
        let model = LaunchAtLoginModel(service: service)
        model.refreshAsynchronously()
        let complete = service.pending.removeFirst()

        model.setEnabled(true)
        XCTAssertEqual(model.status, .enabled)

        let delivered = expectation(description: "late callback delivered")
        DispatchQueue.global().async {
            complete(.notRegistered)
            DispatchQueue.main.async { delivered.fulfill() }
        }
        wait(for: [delivered], timeout: 2)
        XCTAssertEqual(model.status, .enabled)
    }

    func testReentrantCompletionDuringRegistrationDoesNotPublishOldStatus() {
        let service = ControlledLoginItemService()
        let model = LaunchAtLoginModel(service: service)
        var values: [LoginItemStatus] = []
        let observer = model.$status.dropFirst().sink { values.append($0) }
        model.refreshAsynchronously()
        let complete = service.pending.removeFirst()
        service.duringRegister = { complete(.requiresApproval) }

        model.setEnabled(true)

        XCTAssertEqual(values, [.enabled])
        XCTAssertEqual(model.status, .enabled)
        withExtendedLifetime(observer) {}
    }

    func testRepeatedRefreshWaitsForCurrentReadAndKeepsNewestResult() {
        let service = ControlledLoginItemService()
        let model = LaunchAtLoginModel(service: service)
        model.refreshAsynchronously()
        model.refreshAsynchronously()
        model.refreshAsynchronously()
        XCTAssertEqual(service.pending.count, 1)

        service.pending.removeFirst()(.requiresApproval)
        XCTAssertEqual(model.status, .notRegistered)
        XCTAssertEqual(service.pending.count, 1)
        service.pending.removeFirst()(.enabled)
        XCTAssertEqual(model.status, .enabled)
        XCTAssertTrue(service.pending.isEmpty)
    }
}

private final class ControlledLoginItemService: LoginItemService {
    var status: LoginItemStatus = .notRegistered
    var pending: [(LoginItemStatus) -> Void] = []
    var duringRegister: (() -> Void)?
    func requestStatus(completion: @escaping (LoginItemStatus) -> Void) { pending.append(completion) }
    func register() throws { duringRegister?(); status = .enabled }
    func unregister() throws { status = .notRegistered }
    func openSystemSettingsLoginItems() {}
}
