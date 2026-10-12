import XCTest
import SpinnetCore
import Darwin

final class HomebrewPathManifestTests: XCTestCase {
    func testZapExpandsBracesAndGlobsToACompleteLeafFirstFrozenManifestWithoutFollowingLinks() throws {
        try fixture { root, context, worker in
            let vendor = root.appendingPathComponent("home/Library/Application Support/Vendor")
            try FileManager.default.createDirectory(at: vendor.appendingPathComponent("nested"), withIntermediateDirectories: true)
            try Data("fixture one".utf8).write(to: vendor.appendingPathComponent("one.cache"))
            try Data("fixture two".utf8).write(to: vendor.appendingPathComponent("nested/two.cache"))
            try FileManager.default.createSymbolicLink(atPath: vendor.appendingPathComponent("outside.link").path, withDestinationPath: "/System/Library")
            let request = try HomebrewPathManifest.Directive(kind: .zap, patterns: ["~/Library/Application Support/{Vendor,Absent}", "~/Library/Application Support/Vendor/*.cache"])
            let manifest = try HomebrewPathManifest.capture([request], context: context, worker: worker, deadline: Date().addingTimeInterval(10))
            XCTAssertEqual(manifest.entries.count, 5)
            XCTAssertEqual(manifest.entries.last?.path, vendor.path)
            XCTAssertTrue(manifest.entries.contains { $0.path.hasSuffix("outside.link") && $0.snapshot.symbolicLink })
            XCTAssertEqual(manifest.unmatchedPatterns.count, 1)
            XCTAssertFalse(manifest.ancestors.isEmpty)
            XCTAssertEqual(manifest.sha256.count, 64)
            XCTAssertEqual(try Data(contentsOf: vendor.appendingPathComponent("one.cache")), Data("fixture one".utf8))
            try Data("changed fixture".utf8).write(to: vendor.appendingPathComponent("one.cache"))
            let changed = try HomebrewPathManifest.capture([request], context: context, worker: worker, deadline: Date().addingTimeInterval(10))
            XCTAssertNotEqual(changed.sha256, manifest.sha256)
        }
    }
    func testRmdirRemovesOnlyDirectoriesMadeEmptyByConcreteDeletesAndDisclosesRetainedUserData() throws {
        try fixture { root, context, worker in
            let vm = root.appendingPathComponent("home/VM")
            for folder in ["cache", "empty"] { try FileManager.default.createDirectory(at: vm.appendingPathComponent(folder), withIntermediateDirectories: true) }
            try Data("selected".utf8).write(to: vm.appendingPathComponent("cache/remove.txt"))
            try Data("preserved user data".utf8).write(to: vm.appendingPathComponent("preserved.txt"))
            let delete = try HomebrewPathManifest.Directive(kind: .delete, patterns: ["~/VM/cache/remove.txt"])
            let rmdir = try HomebrewPathManifest.Directive(kind: .rmdir, patterns: ["~/VM"])
            let manifest = try HomebrewPathManifest.capture([delete, rmdir], context: context, worker: worker, deadline: Date().addingTimeInterval(10))
            XCTAssertEqual(manifest.entries.map(\.path), [vm.appendingPathComponent("cache/remove.txt").path, vm.appendingPathComponent("cache").path, vm.appendingPathComponent("empty").path])
            XCTAssertEqual(manifest.entries.map(\.operation), [.delete, .rmdir, .rmdir])
            XCTAssertEqual(manifest.retainedDirectories.map(\.path), [vm.path])
            XCTAssertEqual(try Data(contentsOf: vm.appendingPathComponent("preserved.txt")), Data("preserved user data".utf8))
        }
    }
    func testEssentialRootsCredentialsRelativePathsAndArbitrarySymlinkAncestorsCannotBecomeDeleteAuthority() throws {
        try fixture { root, context, worker in
            for name in ["Documents", "Library/Caches", "Library/Keychains", ".ssh"] { try FileManager.default.createDirectory(at: root.appendingPathComponent("home/" + name), withIntermediateDirectories: true) }
            try Data("task-owned credential canary".utf8).write(to: root.appendingPathComponent("home/.ssh/canary"))
            try Data("task-owned keychain canary".utf8).write(to: root.appendingPathComponent("home/Library/Keychains/canary"))
            for pattern in ["~/Documents", "~/Library/Caches", "~/Library/Keychains/canary", "~/Library/Keychains/canary", "~/.ssh/canary", "$HOMEBREW_PREFIX/bin", "$APPDIR", "/Library", "/usr/local/bin", "relative/file", "~/Vendor/../Documents", "~/Vendor/./data", "/System/Library/unsupported"] {
                let request = try HomebrewPathManifest.Directive(kind: .delete, patterns: [pattern])
                XCTAssertThrowsError(try HomebrewPathManifest.capture([request], context: context, worker: worker, deadline: Date().addingTimeInterval(10))) {
                    XCTAssertEqual($0 as? PluginHostServiceError, .tool(.sourceNotAllowed), pattern)
                }
            }
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("home/alias").path, withDestinationPath: root.appendingPathComponent("home/Documents").path)
            let alias = try HomebrewPathManifest.Directive(kind: .delete, patterns: ["~/alias/missing"])
            XCTAssertThrowsError(try HomebrewPathManifest.capture([alias], context: context, worker: worker, deadline: Date().addingTimeInterval(10)))
        }
    }
    func testStopBoundsAnActualReadOnlyWorkerAndLeavesEveryFixtureInPlace() throws {
        try fixture { root, context, worker in
            let vendor = root.appendingPathComponent("home/Vendor")
            try FileManager.default.createDirectory(at: vendor, withIntermediateDirectories: true)
            for index in 0..<1000 { try Data("fixture".utf8).write(to: vendor.appendingPathComponent("file-\(index)")) }
            let request = try HomebrewPathManifest.Directive(kind: .delete, patterns: ["~/Vendor"])
            var checks = 0
            let started = ProcessInfo.processInfo.systemUptime
            XCTAssertThrowsError(try HomebrewPathManifest.capture([request], context: context, worker: worker, deadline: Date().addingTimeInterval(10), isCancelled: { checks += 1; return checks >= 5 })) {
                XCTAssertEqual($0 as? PluginHostServiceError, .tool(.planChanged))
            }
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: vendor.path).count, 1000)
        }
    }
    func testAbsoluteDeadlineBoundsActualInventoryAndOversizedSparseFilesNeverGetAuthority() throws {
        try fixture { root, context, worker in
            let vendor = root.appendingPathComponent("home/Vendor")
            try FileManager.default.createDirectory(at: vendor, withIntermediateDirectories: true)
            for index in 0..<1000 { try Data("fixture".utf8).write(to: vendor.appendingPathComponent("file-\(index)")) }
            let request = try HomebrewPathManifest.Directive(kind: .delete, patterns: ["~/Vendor"])
            let started = ProcessInfo.processInfo.systemUptime
            XCTAssertThrowsError(try HomebrewPathManifest.capture([request], context: context, worker: worker, deadline: Date().addingTimeInterval(0.025))) {
                XCTAssertEqual($0 as? PluginHostServiceError, .tool(.timedOut))
            }
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1)
        }
        try fixture { root, context, worker in
            let path = root.appendingPathComponent("home/oversized.fixture")
            let file = open(path.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            XCTAssertGreaterThanOrEqual(file, 0)
            defer { close(file) }
            XCTAssertEqual(ftruncate(file, 8 * 1024 * 1024 * 1024 + 1), 0)
            let request = try HomebrewPathManifest.Directive(kind: .delete, patterns: ["~/oversized.fixture"])
            XCTAssertThrowsError(try HomebrewPathManifest.capture([request], context: context, worker: worker, deadline: Date().addingTimeInterval(10))) {
                XCTAssertEqual($0 as? PluginHostServiceError, .tool(.outputTooLarge))
            }
        }
    }
    func testAncestorPermissionChangesAndHardlinksCannotHideBehindAnUnchangedLeafName() throws {
        try fixture { root, context, worker in
            let vendor = root.appendingPathComponent("home/Vendor")
            try FileManager.default.createDirectory(at: vendor, withIntermediateDirectories: true)
            let file = vendor.appendingPathComponent("data")
            try Data("frozen fixture".utf8).write(to: file)
            let request = try HomebrewPathManifest.Directive(kind: .delete, patterns: ["~/Vendor/data"])
            let first = try HomebrewPathManifest.capture([request], context: context, worker: worker, deadline: Date().addingTimeInterval(10))
            try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: vendor.path)
            let second = try HomebrewPathManifest.capture([request], context: context, worker: worker, deadline: Date().addingTimeInterval(10))
            XCTAssertEqual(first.entries, second.entries)
            XCTAssertNotEqual(first.sha256, second.sha256)
            XCTAssertNotEqual(first.ancestors, second.ancestors)
            XCTAssertEqual(link(file.path, vendor.appendingPathComponent("other-name").path), 0)
            XCTAssertThrowsError(try HomebrewPathManifest.capture([request], context: context, worker: worker, deadline: Date().addingTimeInterval(10)))
        }
    }
    private func fixture(_ action: (URL, HomebrewPathManifest.Context, HomebrewPathManifest.WorkerConfiguration) throws -> Void) throws {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let root = raw.resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["home", "prefix", "apps"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: false) }
        let context = try HomebrewPathManifest.Context(home: root.appendingPathComponent("home"), prefix: root.appendingPathComponent("prefix"), appDirectory: root.appendingPathComponent("apps"))
        let executable = Bundle(for: HomebrewPathManifestTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("SpinnetPathInventory")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path), executable.path)
        let worker = try HomebrewPathManifest.WorkerConfiguration(executable: executable)
        try action(root, context, worker)
    }
}
