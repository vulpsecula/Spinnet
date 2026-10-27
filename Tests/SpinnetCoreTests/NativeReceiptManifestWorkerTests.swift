import XCTest
import SpinnetCore
@testable import SpinnetReviewedTools
import Darwin

final class NativeReceiptManifestWorkerTests: XCTestCase {
    func testRemainingCaptureBudgetIsEnforcedBeforeReadingAnotherRegularPayload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try NativeFileQuarantine.makePrivateDirectory(root); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("owned"), link = root.appendingPathComponent("link")
        try Data(repeating: 42, count: 4096).write(to: file); XCTAssertEqual(chmod(file.path, 0o600), 0)
        XCTAssertThrowsError(try NativeFileQuarantine.capture(file, maximumBytes: 4095)) { XCTAssertEqual($0 as? PluginHostServiceError, .tool(.outputTooLarge)) }
        XCTAssertEqual(try NativeFileQuarantine.capture(file, maximumBytes: 4096).size, 4096)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try NativeFileQuarantine.capture(link, maximumBytes: 0)) { XCTAssertEqual($0 as? PluginHostServiceError, .tool(.outputTooLarge)) }
        XCTAssertThrowsError(try NativeFileQuarantine.capture(file, maximumBytes: -1))
    }
    func testManifestWorkerRequestAdmitsOnlyExplicitNativeAccountingAndRejectsMutationInputs() throws {
        let identifier = "org.example.disposable"
        XCTAssertNoThrow(try NativeReceiptInventoryWorker.ManifestRequest(selected: [identifier],
            excludedPaths: [identifier: ["/Library/Extensions/Owned.kext/Contents/Info.plist", "/Library/LaunchAgents/org.example.owned.plist"]]).validate())
        for path in ["/System/Library/Extensions/Owned.kext", "/Library/Extensions/../Other", "/private/tmp/any", "/Library/LaunchDaemons/"] {
            XCTAssertThrowsError(try NativeReceiptInventoryWorker.ManifestRequest(selected: [identifier], excludedPaths: [identifier: [path]]).validate())
        }
        XCTAssertThrowsError(try NativeReceiptInventoryWorker.ManifestRequest(selected: [identifier], excludedPaths: ["org.other": []]).validate())
        XCTAssertThrowsError(try NativeReceiptInventoryWorker.ManifestRequest(selected: []).validate())
        XCTAssertThrowsError(try NativeReceiptInventoryWorker.captureManifests(.init(selected: [identifier]), deadline: Date().addingTimeInterval(1), isCancelled: { true }))
    }
    func testActualFixedManifestWorkerRefusesUnknownReceiptWithoutParentFilesystemScan() throws {
        let began = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try NativeReceiptInventoryWorker.captureManifests(.init(selected: ["org.spinnet.disposable.missing"]), deadline: Date().addingTimeInterval(3)))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 3.5)
    }
    func testFixedManifestInputAboveVendorLimitReachesBoundedReadonlyValidation() throws {
        let identifier = "org.spinnet.disposable.missing"
        let names = Set((0..<1300).map { "/Library/LaunchDaemons/org.spinnet.disposable.\($0)." + String(repeating: "a", count: 240) + ".plist" })
        let request = NativeReceiptInventoryWorker.ManifestRequest(selected: [identifier], excludedPaths: [identifier: names])
        let bytes = try JSONEncoder().encode(request)
        XCTAssertGreaterThan(bytes.count, 256 * 1024); XCTAssertLessThan(bytes.count, 1024 * 1024)
        XCTAssertThrowsError(try NativeReceiptInventoryWorker.captureManifests(request, deadline: Date().addingTimeInterval(3))) { error in
            guard case .unavailable = error as? PluginHostServiceError else { return XCTFail("Frame must reach fixed read-only unknown-receipt validation, not fail vendor stdin policy: \(error)") }
        }
    }
}
