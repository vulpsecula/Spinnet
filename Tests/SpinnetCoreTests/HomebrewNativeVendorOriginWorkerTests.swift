import XCTest
import Darwin
import SpinnetCore

final class HomebrewNativeVendorOriginWorkerTests: XCTestCase {
    func testConfirmedSignedURLFixtureBytesCopyInsideWorkerBeforeMissingOriginalMemberRefuses() throws {
        XCTAssertNotEqual(getuid(), 0, "Current-UID fixed-fetch fixture, no publisher-body or historical claim")
        let snapshot = try HomebrewPrivilegeMetadata.readEvidence("sound-siphon", deadline: Date().addingTimeInterval(15))
        let root = URL(fileURLWithPath: "/private/tmp/spinnet-source-copy-" + UUID().uuidString)
        try NativeFileQuarantine.makePrivateDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDirectory = root.appendingPathComponent("host-snapshot"), stage = root.appendingPathComponent("worker-stage")
        try NativeFileQuarantine.makePrivateDirectory(sourceDirectory); try NativeFileQuarantine.makePrivateDirectory(stage)
        let bytes = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "vendor", withExtension: "zip", subdirectory: "ArchiveFixtures")))
        let confirmed = try HomebrewNoCheckSnapshot.capture(snapshot: snapshot, into: sourceDirectory, deadline: Date().addingTimeInterval(10), fetch: { _, fd, _, _, _ in
            // Fixed fixture fetch ONLY: no network or original publisher claim.
            try bytes.withUnsafeBytes { raw in XCTAssertEqual(Darwin.write(fd, raw.baseAddress, raw.count), raw.count) }
        })
        let evidence = try XCTUnwrap(snapshot.officialEvidence), configuration = try XCTUnwrap(snapshot.configuration)
        let envelope = try snapshot.persistOfficialEvidence(in: stage)
        let request = HomebrewNativeVendorOriginWorker.Request(envelope: envelope, sourceSHA256: evidence.catalog.envelopeSHA256,
            projectionSHA256: confirmed.projectionSHA256, configuration: configuration, token: "sound-siphon",
            recipeExecutable: "/Applications/Sound Siphon.app/Contents/Resources/uninstall_soundsiphon", confirmedSnapshot: confirmed,
            originalDownload: confirmed.fileURL, staging: stage, ownerUID: getuid(), deadline: Date().addingTimeInterval(10))
        let tools = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let result = HomebrewNativeVendorOriginWorker.run(request, toolsDirectory: tools)
        XCTAssertNil(result.proof); XCTAssertEqual(result.failure, .planChanged)
        let copied = stage.appendingPathComponent("original-download")
        XCTAssertEqual(try Data(contentsOf: copied), bytes)
        XCTAssertEqual(try NativeFileQuarantine.capture(copied).mode & 0o777, 0o400)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.appendingPathComponent("original/Vendor.pkg/Contents/install").path))
    }
    func testActualFixedCLIFramesMalformedInputAndOversizeRefusals() throws {
        XCTAssertEqual(try cli(Data("{}".utf8)).failure, .failed)
        XCTAssertEqual(try cli(Data(repeating: 65, count: HomebrewNativeVendorOriginWorker.maximumMessageBytes + 1)).failure, .outputTooLarge)
    }
    func testActualFixedCLICStopInterruptsHeldStdinAndReturnsStructuredRefusal() throws {
        XCTAssertEqual(try cli(nil, signal: SIGINT).failure, .planChanged)
        XCTAssertEqual(try cli(nil, signal: SIGTERM).failure, .planChanged)
    }
    private func cli(_ input: Data?, signal: Int32? = nil) throws -> HomebrewNativeVendorOriginWorker.Response {
        let executable = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("SpinnetVendorOrigin")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw XCTSkip("Matching fixed source worker development product must be built") }
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        process.executableURL = executable; process.arguments = ["--capture"]
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        try process.run()
        if let input { try stdin.fileHandleForWriting.write(contentsOf: input); try stdin.fileHandleForWriting.close() }
        // Allow this development executable's Swift/Foundation startup before
        // testing its C handler. Stop during startup remains supervisor-owned.
        if let signal { Thread.sleep(forTimeInterval: 1); XCTAssertEqual(kill(process.processIdentifier, signal), 0) }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
            throw PluginHostServiceError.tool(.timedOut)
        }
        process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        try? stdin.fileHandleForWriting.close()
        let output = try stdout.fileHandleForReading.readToEnd() ?? Data()
        XCTAssertLessThanOrEqual(output.count, HomebrewNativeVendorOriginWorker.maximumMessageBytes)
        return try JSONDecoder().decode(HomebrewNativeVendorOriginWorker.Response.self, from: output)
    }
    func testStopAndExpiredDeadlineRefuseBeforeAnyFileAccess() throws {
        let account = try XCTUnwrap(getpwuid(getuid()))
        let home = URL(fileURLWithPath: String(cString: account.pointee.pw_dir))
        let configuration = try HomebrewSignedCaskCatalog.Configuration(languages: [], home: home,
            prefix: URL(fileURLWithPath: "/opt/homebrew"), appDirectory: URL(fileURLWithPath: "/Applications"))
        let missing = URL(fileURLWithPath: "/private/tmp/spinnet-source-not-created-" + UUID().uuidString)
        func request(_ deadline: Date) -> HomebrewNativeVendorOriginWorker.Request {
            .init(envelope: missing.appendingPathComponent("homebrew-source.jws.json"), sourceSHA256: String(repeating: "a", count: 64),
                projectionSHA256: String(repeating: "b", count: 64), configuration: configuration, token: "fixture",
                recipeExecutable: "/Applications/fixture", originalDownload: missing.appendingPathComponent("original"),
                staging: missing, ownerUID: getuid(), deadline: deadline)
        }
        XCTAssertEqual(HomebrewNativeVendorOriginWorker.run(request(Date().addingTimeInterval(10)), toolsDirectory: missing, isCancelled: { true }).failure, .planChanged)
        XCTAssertEqual(HomebrewNativeVendorOriginWorker.run(request(Date().addingTimeInterval(-1)), toolsDirectory: missing).failure, .timedOut)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }
    func testFixedWorkerIndependentlyReverifiesSourceBeforeRejectingWrongOriginalBytes() throws {
        XCTAssertNotEqual(getuid(), 0, "Current-UID source seam, not Root acceptance")
        let snapshot = try HomebrewPrivilegeMetadata.readEvidence("shadowsocksx-ng", deadline: Date().addingTimeInterval(15))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try NativeFileQuarantine.makePrivateDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let envelope = try snapshot.persistOfficialEvidence(in: root)
        let image = root.appendingPathComponent("original.dmg")
        try Data("wrong original fixture bytes".utf8).write(to: image); XCTAssertEqual(chmod(image.path, 0o600), 0)
        let evidence = try XCTUnwrap(snapshot.officialEvidence), configuration = try XCTUnwrap(snapshot.configuration)
        let request = HomebrewNativeVendorOriginWorker.Request(envelope: envelope, sourceSHA256: evidence.catalog.envelopeSHA256,
            projectionSHA256: try evidence.catalog.projectionDigest("shadowsocksx-ng", configuration: configuration),
            configuration: configuration, token: "shadowsocksx-ng", recipeExecutable: "/Applications/ShadowsocksX-NG.app/Contents/Resources/proxy_conf_helper",
            originalDownload: image, staging: root, ownerUID: getuid(), deadline: Date().addingTimeInterval(10))
        let tools = Bundle(for: HomebrewNativeVendorOriginWorkerTests.self).bundleURL.deletingLastPathComponent()
        let result = HomebrewNativeVendorOriginWorker.run(request, toolsDirectory: tools)
        XCTAssertEqual(result.failure, .planChanged)
        XCTAssertNil(result.proof)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("original").path))
        let supervised = try HomebrewNativeVendorOriginExecution.capture(request, toolsDirectory: tools)
        XCTAssertEqual(supervised.state, .completed); XCTAssertEqual(supervised.response?.failure, .planChanged)
    }
}
