import XCTest
import Darwin
import SpinnetCore

final class HomebrewNativeVendorOriginExecutionTests: XCTestCase {
    func testOwnedFixedWorkerResidentMemoryCapStopsAndReaps() throws {
        try fixture("fixture-rss", timeout: 8) { request, tools in
            let result = try HomebrewNativeVendorOriginExecution.capture(request, toolsDirectory: tools)
            XCTAssertEqual(result.state, .completed); XCTAssertEqual(result.response?.failure, .outputTooLarge)
            XCTAssertNil(HomebrewTaskProcess.startIdentity(result.process.processIdentifier))
            let details = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: request.staging.appendingPathComponent("owned-child.json"))) as? [String: Int32])
            XCTAssertNotEqual(details["group"], details["parent"])
            XCTAssertNil(HomebrewTaskProcess.startIdentity(try XCTUnwrap(details["pid"])))
        }
    }
    func testStopBeforeSpawnDoesNotCallLaneRegistration() throws {
        try fixture("fixture-malformed") { request, tools in
            var registered = false
            XCTAssertThrowsError(try HomebrewNativeVendorOriginExecution.capture(request, toolsDirectory: tools,
                isCancelled: { true }, willStart: { _ in registered = true; return true })) {
                XCTAssertEqual($0 as? PluginHostServiceError, .tool(.planChanged))
            }
            XCTAssertFalse(registered)
        }
    }
    func testOwnedFixtureMalformedAndOversizeResponsesRefuse() throws {
        try fixture("fixture-malformed") { request, tools in
            let result = try HomebrewNativeVendorOriginExecution.capture(request, toolsDirectory: tools)
            XCTAssertEqual(result.state, .completed); XCTAssertEqual(result.response?.failure, .failed)
            XCTAssertEqual(result.response?.recoveryDirectory, request.staging)
        }
        try fixture("fixture-large") { request, tools in
            let result = try HomebrewNativeVendorOriginExecution.capture(request, toolsDirectory: tools)
            XCTAssertEqual(result.state, .completed); XCTAssertEqual(result.response?.failure, .outputTooLarge)
            XCTAssertEqual(result.response?.recoveryDirectory, request.staging)
        }
    }
    func testOwnedBlockedWorkerDeadlineKillsAndActuallyReapsBeforeRelease() throws {
        try fixture("fixture-block", timeout: 0.5) { request, tools in
            let reaped = expectation(description: "Actual fixed fixture reap")
            let result = try HomebrewNativeVendorOriginExecution.capture(request, toolsDirectory: tools, didReap: { _ in reaped.fulfill() })
            XCTAssertEqual(result.state, .completed); XCTAssertEqual(result.response?.failure, .timedOut)
            wait(for: [reaped], timeout: 3)
            XCTAssertNil(HomebrewTaskProcess.startIdentity(result.process.processIdentifier))
        }
    }
    func testOwnedUnknownResponseRetainsProcessUntilActualReapCallback() throws {
        try fixture("fixture-block", timeout: 0.5) { request, tools in
            let reaped = expectation(description: "Retained unknown process actually reaps")
            let result = try HomebrewNativeVendorOriginExecution.capture(request, toolsDirectory: tools, stopGrace: 0, didReap: { _ in reaped.fulfill() })
            XCTAssertEqual(result.state, .unknown); XCTAssertNil(result.response)
            XCTAssertNotNil(HomebrewTaskProcess.startIdentity(result.process.processIdentifier))
            wait(for: [reaped], timeout: 3)
            XCTAssertNil(HomebrewTaskProcess.startIdentity(result.process.processIdentifier))
        }
    }
    func testOwnedFoundationChildSeparateGroupCannotEscapeSourceWorkerStopOrReap() throws {
        try fixture("fixture-escape", timeout: 0.9) { request, tools in
            let start = ProcessInfo.processInfo.systemUptime
            let result = try HomebrewNativeVendorOriginExecution.capture(request, toolsDirectory: tools)
            XCTAssertEqual(result.state, .completed); XCTAssertEqual(result.response?.failure, .timedOut)
            XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - start, 0.7)
            let details = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: request.staging.appendingPathComponent("owned-child.json"))) as? [String: Int32])
            let pid = try XCTUnwrap(details["pid"])
            XCTAssertNotEqual(details["group"], details["parent"], "Actual Foundation child uses a separate process group")
            XCTAssertNil(HomebrewTaskProcess.startIdentity(pid), "Exact owned child must really reap before lane release")
        }
    }
    private func fixture(_ token: String, timeout: TimeInterval = 5,
                         _ action: (HomebrewNativeVendorOriginWorker.Request, URL) throws -> Void) throws {
        XCTAssertNotEqual(getuid(), 0, "Current-UID fixtures only, never Root acceptance")
        let source = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("SpinnetVendorOriginFixture")
        guard FileManager.default.isExecutableFile(atPath: source.path) else { throw XCTSkip("Build the fixed, unprivileged fixture product first") }
        let root = URL(fileURLWithPath: "/private/tmp/spinnet-origin-execution-" + UUID().uuidString)
        try NativeFileQuarantine.makePrivateDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = root.appendingPathComponent("tools")
        try NativeFileQuarantine.makePrivateDirectory(tools)
        let worker = tools.appendingPathComponent("SpinnetVendorOrigin")
        try FileManager.default.copyItem(at: source, to: worker); XCTAssertEqual(chmod(worker.path, 0o700), 0)
        let home = URL(fileURLWithPath: String(cString: try XCTUnwrap(getpwuid(getuid())).pointee.pw_dir))
        let config = try HomebrewSignedCaskCatalog.Configuration(languages: [], home: home,
            prefix: URL(fileURLWithPath: "/opt/homebrew"), appDirectory: URL(fileURLWithPath: "/Applications"))
        let request = HomebrewNativeVendorOriginWorker.Request(envelope: root.appendingPathComponent("homebrew-source.jws.json"),
            sourceSHA256: String(repeating: "a", count: 64), projectionSHA256: String(repeating: "b", count: 64),
            configuration: config, token: token, recipeExecutable: "/Applications/fixture", originalDownload: root.appendingPathComponent("original"),
            staging: root, ownerUID: getuid(), deadline: Date().addingTimeInterval(timeout))
        try action(request, tools)
    }
}
