import XCTest
import SpinnetCore
@testable import SpinnetReviewedTools
import Darwin

final class HomebrewPathRemovalTests: XCTestCase {
    func testOwnedRecursiveManifestRemovesOnlyFrozenLeavesAndRestoresNoExternalSymlinkTarget() throws {
        try fixture { root, context, worker, staging in
            let vendor = root.appendingPathComponent("home/Vendor")
            try FileManager.default.createDirectory(at: vendor.appendingPathComponent("nested"), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: vendor.appendingPathComponent("nested/data"))
            let outside = root.appendingPathComponent("home/unselected")
            try Data("preserved".utf8).write(to: outside)
            try FileManager.default.createSymbolicLink(atPath: vendor.appendingPathComponent("external.link").path, withDestinationPath: outside.path)
            let request = try HomebrewPathManifest.Directive(kind: .delete, patterns: ["~/Vendor"])
            let manifest = try HomebrewPathManifest.capture([request], context: context, worker: worker, deadline: Date().addingTimeInterval(10))
            let result = try HomebrewPathRemoval.remove(manifest, staging: staging, deadline: Date().addingTimeInterval(10))
            XCTAssertEqual(Set(result.removed), Set(manifest.entries.map(\.path)))
            XCTAssertTrue(result.retained.isEmpty)
            XCTAssertTrue(result.quarantined.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: vendor.path))
            XCTAssertEqual(try Data(contentsOf: outside), Data("preserved".utf8))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
        }
    }
    func testFrozenNonemptyRmdirBecomesConditionalEmptyAuthorityAfterEarlierOrdinaryRemoval() throws {
        try fixture { root, context, worker, staging in
            let vm = root.appendingPathComponent("home/VM")
            try FileManager.default.createDirectory(at: vm, withIntermediateDirectories: true)
            let old = vm.appendingPathComponent("ordinary-app-data")
            try Data("fixture".utf8).write(to: old)
            let request = try HomebrewPathManifest.Directive(kind: .rmdir, patterns: ["~/VM"])
            let manifest = try HomebrewPathManifest.capture([request], context: context, worker: worker, deadline: Date().addingTimeInterval(10))
            XCTAssertEqual(manifest.retainedDirectories.map(\.path), [vm.path])
            // Simulate the earlier normal uninstall phase on owned fixture data.
            try FileManager.default.removeItem(at: old)
            let result = try HomebrewPathRemoval.remove(manifest, staging: staging, deadline: Date().addingTimeInterval(10))
            XCTAssertEqual(result.removed, [vm.path])
            XCTAssertTrue(result.retained.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: vm.path))
        }
        try fixture { root, context, worker, staging in
            let vm = root.appendingPathComponent("home/VM")
            try FileManager.default.createDirectory(at: vm, withIntermediateDirectories: true)
            try Data("preserved".utf8).write(to: vm.appendingPathComponent("user-data"))
            let request = try HomebrewPathManifest.Directive(kind: .rmdir, patterns: ["~/VM"])
            let manifest = try HomebrewPathManifest.capture([request], context: context, worker: worker, deadline: Date().addingTimeInterval(10))
            try Data("new data".utf8).write(to: vm.appendingPathComponent("new-data"))
            let result = try HomebrewPathRemoval.remove(manifest, staging: staging, deadline: Date().addingTimeInterval(10))
            XCTAssertTrue(result.removed.isEmpty)
            XCTAssertEqual(result.retained.map(\.path), [vm.path])
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: vm.path).count, 2)
        }
    }
    func testChangedRecursivePayloadAndAddedChildrenRefuseBeforeAnyFixtureMutation() throws {
        try fixture { root, context, worker, staging in
            let vendor = root.appendingPathComponent("home/Vendor")
            try FileManager.default.createDirectory(at: vendor, withIntermediateDirectories: true)
            let file = vendor.appendingPathComponent("data")
            try Data("original".utf8).write(to: file)
            let request = try HomebrewPathManifest.Directive(kind: .delete, patterns: ["~/Vendor"])
            let manifest = try HomebrewPathManifest.capture([request], context: context, worker: worker, deadline: Date().addingTimeInterval(10))
            try Data("changed payload".utf8).write(to: file)
            try Data("unreviewed child".utf8).write(to: vendor.appendingPathComponent("new"))
            var mutations = 0
            XCTAssertThrowsError(try HomebrewPathRemoval.remove(manifest, staging: staging, deadline: Date().addingTimeInterval(10), mutation: { action in mutations += 1; try action() })) {
                XCTAssertEqual($0 as? PluginHostServiceError, .tool(.planChanged))
            }
            XCTAssertEqual(mutations, 0)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: vendor.path).count, 2)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
        }
    }
    func testNewPayloadAfterQuarantineIsRestoredAndPendingJournalPrecedesMutation() throws {
        try fixture { root, context, worker, staging in
            let directory = root.appendingPathComponent("home/Empty")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let request = try HomebrewPathManifest.Directive(kind: .rmdir, patterns: ["~/Empty"])
            let manifest = try HomebrewPathManifest.capture([request], context: context, worker: worker, deadline: Date().addingTimeInterval(10))
            var mutations = 0
            let result = try HomebrewPathRemoval.remove(manifest, staging: staging, deadline: Date().addingTimeInterval(10), mutation: { action in
                mutations += 1
                let files = try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
                let journals = files.filter { $0.lastPathComponent.hasPrefix("pending-") }
                XCTAssertEqual(journals.count, 1)
                let pending = try JSONDecoder().decode(HomebrewPathRemoval.PendingOperation.self, from: Data(contentsOf: XCTUnwrap(journals.first)))
                XCTAssertEqual(pending.manifestSHA256, manifest.sha256)
                XCTAssertEqual(pending.path, directory.path)
                if mutations == 2 {
                    // Add owned fixture data immediately before conditional unlink.
                    let quarantined = staging.appendingPathComponent(pending.quarantineName)
                    try Data("new payload".utf8).write(to: quarantined.appendingPathComponent("preserve"))
                }
                try action()
            })
            XCTAssertEqual(mutations, 2)
            XCTAssertTrue(result.removed.isEmpty)
            XCTAssertEqual(result.retained.map(\.path), [directory.path])
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("preserve")), Data("new payload".utf8))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
        }
    }
    func testChangedParentRefusesBeforeFirstMutationAndLeavesOwnedPayload() throws {
        try fixture { root, context, worker, staging in
            let file = root.appendingPathComponent("home/data")
            try Data("owned fixture".utf8).write(to: file)
            let request = try HomebrewPathManifest.Directive(kind: .delete, patterns: ["~/data"])
            let manifest = try HomebrewPathManifest.capture([request], context: context, worker: worker, deadline: Date().addingTimeInterval(10))
            XCTAssertEqual(chmod(context.home.path, 0o700), 0)
            var mutations = 0
            XCTAssertThrowsError(try HomebrewPathRemoval.remove(manifest, staging: staging, deadline: Date().addingTimeInterval(10), mutation: { action in mutations += 1; try action() }))
            XCTAssertEqual(mutations, 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        }
    }
    func testLostRestorePreservesBothReplacementAndFrozenQuarantineWithPendingJournal() throws {
        try fixture { root, context, worker, staging in
            let file = root.appendingPathComponent("home/data")
            try Data("frozen".utf8).write(to: file)
            let request = try HomebrewPathManifest.Directive(kind: .delete, patterns: ["~/data"])
            let manifest = try HomebrewPathManifest.capture([request], context: context, worker: worker, deadline: Date().addingTimeInterval(10))
            var mutations = 0
            do {
                _ = try HomebrewPathRemoval.remove(manifest, staging: staging, deadline: Date().addingTimeInterval(10), mutation: { action in
                    mutations += 1
                    if mutations == 2 {
                        try Data("replacement".utf8).write(to: file)
                        throw PluginHostServiceError.tool(.planChanged)
                    }
                    try action()
                })
                XCTFail("Expected partial quarantine failure")
            } catch let error as HomebrewPathRemoval.Failure {
                XCTAssertTrue(error.result.removed.isEmpty)
                XCTAssertEqual(error.result.quarantined.count, 1)
                XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(error.result.quarantined.first))), Data("frozen".utf8))
                XCTAssertEqual(try Data(contentsOf: file), Data("replacement".utf8))
                let records = try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("pending-") }
                XCTAssertEqual(records.count, 1)
            }
        }
    }
    func testCancellationAndThrownAfterUnlinkReturnExactIrreversiblePartialProgress() throws {
        for throwAfterUnlink in [false, true] {
            try fixture { root, context, worker, staging in
                for name in ["a", "b"] { try Data("fixture".utf8).write(to: root.appendingPathComponent("home/" + name)) }
                let request = try HomebrewPathManifest.Directive(kind: .delete, patterns: ["~/a", "~/b"])
                let manifest = try HomebrewPathManifest.capture([request], context: context, worker: worker, deadline: Date().addingTimeInterval(10))
                var mutations = 0, stopped = false
                do {
                    _ = try HomebrewPathRemoval.remove(manifest, staging: staging, deadline: Date().addingTimeInterval(10), isCancelled: { stopped }, mutation: { action in
                        mutations += 1; try action()
                        if mutations == 2 { stopped = true; if throwAfterUnlink { throw PluginHostServiceError.tool(.planChanged) } }
                    })
                    XCTFail("Expected partial Stop")
                } catch let error as HomebrewPathRemoval.Failure {
                    XCTAssertEqual(error.result.removed, [root.appendingPathComponent("home/a").path])
                    XCTAssertTrue(error.result.quarantined.isEmpty)
                    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("home/a").path))
                    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("home/b").path))
                    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
                }
            }
        }
    }
    func testFixedMutationExecutableDeletesOnlyOwnedFrozenManifestAndReturnsStructuredResult() throws {
        XCTAssertNotEqual(getuid(), 0, "This is a current-UID fixture tracer, not Root acceptance")
        try fixture { root, context, worker, staging in
            let file = root.appendingPathComponent("home/data")
            let outside = root.appendingPathComponent("home/unselected")
            try Data("frozen".utf8).write(to: file)
            try Data("preserved".utf8).write(to: outside)
            let request = try HomebrewPathManifest.Directive(kind: .delete, patterns: ["~/data"])
            let manifest = try HomebrewPathManifest.capture([request], context: context, worker: worker, deadline: Date().addingTimeInterval(10))
            let bytes = try JSONEncoder().encode(HomebrewPathRemoval.Request(manifest: manifest, staging: staging, deadline: Date().addingTimeInterval(10)))
            let (process, input, output) = try launchWorker()
            try input.fileHandleForWriting.write(contentsOf: bytes)
            try input.fileHandleForWriting.close()
            let result = try finishWorker(process, output)
            XCTAssertNil(result.failure)
            XCTAssertNil(result.unavailable)
            XCTAssertEqual(result.result?.removed, [file.path])
            XCTAssertEqual(try Data(contentsOf: outside), Data("preserved".utf8))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
        }
    }
    func testFixedWorkerSIGINTAndSIGTERMInterruptStdinWithoutSwiftSignalHandler() throws {
        XCTAssertNotEqual(getuid(), 0)
        for signal in [SIGINT, SIGTERM] {
            let (process, input, output) = try launchWorker()
            // This fixed process is blocked in its bounded stdin read, before
            // any request/manifest is accepted. C handler must unblock it.
            usleep(100_000)
            XCTAssertTrue(process.isRunning)
            XCTAssertEqual(kill(process.processIdentifier, signal), 0)
            let result = try finishWorker(process, output)
            try input.fileHandleForWriting.close()
            XCTAssertEqual(result.failure, .planChanged)
            XCTAssertNil(result.result)
        }
    }
    private func launchWorker() throws -> (Process, Pipe, Pipe) {
        let executable = Bundle(for: HomebrewPathRemovalTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("SpinnetPathRemoval")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path), "Build the fixed mutation target before native process verification")
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = executable
        process.arguments = ["--remove"]
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        return (process, input, output)
    }
    private func finishWorker(_ process: Process, _ output: Pipe) throws -> HomebrewPathRemoval.Response {
        let completed = expectation(description: "Fixed owned worker reaps within budget")
        DispatchQueue.global().async { process.waitUntilExit(); completed.fulfill() }
        let result = XCTWaiter.wait(for: [completed], timeout: 3)
        if result != .completed { kill(process.processIdentifier, SIGKILL); process.waitUntilExit(); XCTFail("Fixed worker exceeded owned fixture deadline") }
        XCTAssertEqual(process.terminationReason, .exit)
        XCTAssertEqual(process.terminationStatus, 0)
        let bytes = try output.fileHandleForReading.readToEnd() ?? Data()
        XCTAssertLessThanOrEqual(bytes.count, 32 * 1024 * 1024)
        return try JSONDecoder().decode(HomebrewPathRemoval.Response.self, from: bytes)
    }
    private func fixture(_ action: (URL, HomebrewPathManifest.Context, HomebrewPathManifest.WorkerConfiguration, URL) throws -> Void) throws {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let root = raw.resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["home", "prefix", "apps"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: false) }
        let staging = root.appendingPathComponent("stage")
        try NativeFileQuarantine.makePrivateDirectory(staging)
        let context = try HomebrewPathManifest.Context(home: root.appendingPathComponent("home"), prefix: root.appendingPathComponent("prefix"), appDirectory: root.appendingPathComponent("apps"))
        let executable = Bundle(for: HomebrewPathRemovalTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("SpinnetPathInventory")
        let worker = try HomebrewPathManifest.WorkerConfiguration(executable: executable)
        try action(root, context, worker, staging)
    }
}
