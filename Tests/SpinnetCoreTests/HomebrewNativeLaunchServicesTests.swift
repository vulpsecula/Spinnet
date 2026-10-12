import XCTest
import Darwin
import SpinnetCore

final class HomebrewNativeLaunchServicesTests: XCTestCase {
    func testOwnedSystemWideAgentRegisteredInSystemUsesOneConcreteRemovalTarget() throws {
        let root = URL(fileURLWithPath: "/private/tmp/spinnet-launch-system-agent-" + UUID().uuidString)
        try NativeFileQuarantine.makePrivateDirectory(root); defer { try? FileManager.default.removeItem(at: root) }
        for scope in ["systemDaemons", "systemAgents", "userAgents"] { try NativeFileQuarantine.makePrivateDirectory(root.appendingPathComponent(scope)) }
        let label = "com.vendor.system-agent", file = root.appendingPathComponent("systemAgents/" + label + ".plist")
        try PropertyListSerialization.data(fromPropertyList: ["Label": label, "Program": "/usr/bin/true"], format: .xml, options: 0).write(to: file); XCTAssertEqual(chmod(file.path, 0o600), 0)
        let context = try HomebrewNativeLaunchServices.Context(uid: getuid(), home: URL(fileURLWithPath: NSHomeDirectory()))
        let job = HomebrewNativeLaunchServices.Job(domain: .system, label: label, program: "/usr/bin/true", configurationPath: file.path, expectedUID: 0, state: "fixture not running")
        let manifest = try HomebrewNativeLaunchServices.captureOwnedFixture(context: context, declarations: [.init(label)], root: root, jobs: [job], deadline: Date().addingTimeInterval(5))
        XCTAssertEqual(manifest.entries.count, 1); XCTAssertEqual(manifest.entries.first?.domain, .system)
        XCTAssertEqual(manifest.entries.first?.plists.filter(\.removeFile).count, 1)
        XCTAssertEqual(manifest.entries.first?.plists.first?.scope, .systemAgents)
    }
    func testOwnedUserOnlyAndDuplicateDomainsFollowConcreteHomebrewLookupAndOwnership() throws {
        let root = URL(fileURLWithPath: "/private/tmp/spinnet-launch-domains-" + UUID().uuidString)
        try NativeFileQuarantine.makePrivateDirectory(root); defer { try? FileManager.default.removeItem(at: root) }
        for scope in ["systemDaemons", "systemAgents", "userAgents"] { try NativeFileQuarantine.makePrivateDirectory(root.appendingPathComponent(scope)) }
        let context = try HomebrewNativeLaunchServices.Context(uid: getuid(), home: URL(fileURLWithPath: NSHomeDirectory()))
        let label = "prefix.com.vendor.agent"
        let user = HomebrewNativeLaunchServices.Job(domain: .user(getuid()), label: label, program: "/usr/bin/true", configurationPath: nil, expectedUID: getuid(), pid: 42, state: "fixture running")
        let declaration = try HomebrewNativeLaunchServices.Declaration("com.vendor.*")
        let only = try HomebrewNativeLaunchServices.captureOwnedFixture(context: context, declarations: [declaration], root: root, jobs: [user], deadline: Date().addingTimeInterval(5))
        XCTAssertEqual(only.entries.first?.domain, .user(getuid())); XCTAssertTrue(only.unmatched.isEmpty)
        let gui = HomebrewNativeLaunchServices.Job(domain: .gui(getuid()), label: label, program: "/usr/bin/true", configurationPath: nil, expectedUID: getuid(), pid: 43, state: "fixture running")
        let both = try HomebrewNativeLaunchServices.captureOwnedFixture(context: context, declarations: [declaration], root: root, jobs: [user, gui], deadline: Date().addingTimeInterval(5))
        XCTAssertEqual(both.entries.count, 1); XCTAssertEqual(both.entries.first?.domain, .gui(getuid())); XCTAssertEqual(both.entries.first?.retainedDomains, [.user(getuid())])
        let other = HomebrewNativeLaunchServices.Job(domain: .gui(getuid() + 1), label: label, program: "/usr/bin/true", configurationPath: nil, expectedUID: getuid() + 1, pid: 44, state: "other fixture user")
        XCTAssertThrowsError(try HomebrewNativeLaunchServices.captureOwnedFixture(context: context, declarations: [declaration], root: root, jobs: [other], deadline: Date().addingTimeInterval(5)))
        let inactive = HomebrewNativeLaunchServices.Job(domain: .gui(getuid()), label: label, program: "/usr/bin/true", configurationPath: nil, expectedUID: getuid(), state: "fixture inactive")
        let missing = try HomebrewNativeLaunchServices.captureOwnedFixture(context: context, declarations: [declaration], root: root, jobs: [inactive], deadline: Date().addingTimeInterval(5))
        XCTAssertTrue(missing.entries.isEmpty); XCTAssertEqual(missing.unmatched, [declaration])
    }
    func testSelectedSymlinkAndGroupWritablePlistNeverBecomeConcreteAuthority() throws {
        let root = URL(fileURLWithPath: "/private/tmp/spinnet-launch-refusal-" + UUID().uuidString)
        try NativeFileQuarantine.makePrivateDirectory(root); defer { try? FileManager.default.removeItem(at: root) }
        for scope in ["systemDaemons", "systemAgents", "userAgents"] { try NativeFileQuarantine.makePrivateDirectory(root.appendingPathComponent(scope)) }
        let context = try HomebrewNativeLaunchServices.Context(uid: getuid(), home: URL(fileURLWithPath: NSHomeDirectory())), label = "com.vendor.fixture"
        let file = root.appendingPathComponent("userAgents/" + label + ".plist")
        let target = root.appendingPathComponent("owned-target.plist")
        try PropertyListSerialization.data(fromPropertyList: ["Label": label, "Program": "/usr/bin/true"], format: .xml, options: 0).write(to: target)
        XCTAssertEqual(symlink(target.path, file.path), 0)
        XCTAssertThrowsError(try HomebrewNativeLaunchServices.captureOwnedFixture(context: context, declarations: [.init(label)], root: root, jobs: [], deadline: Date().addingTimeInterval(5)))
        XCTAssertEqual(unlink(file.path), 0); try FileManager.default.copyItem(at: target, to: file); XCTAssertEqual(chmod(file.path, 0o660), 0)
        XCTAssertThrowsError(try HomebrewNativeLaunchServices.captureOwnedFixture(context: context, declarations: [.init(label)], root: root, jobs: [], deadline: Date().addingTimeInterval(5)))
    }
    func testActualReadOnlyWorkerProvesUniqueAbsentLabelAcrossAllTaskDomainsAndRoots() throws {
        let context = try HomebrewNativeLaunchServices.Context(uid: getuid(), home: URL(fileURLWithPath: NSHomeDirectory()))
        let declaration = try HomebrewNativeLaunchServices.Declaration("com.vulpsecula.spinnet.owned.absent." + UUID().uuidString)
        let request = HomebrewNativeLaunchServiceInventory.Request(context: context, declarations: [declaration], deadline: Date().addingTimeInterval(15))
        let result = try HomebrewNativeLaunchServiceExecution.capture(request, toolsDirectory: Bundle(for: Self.self).bundleURL.deletingLastPathComponent())
        XCTAssertEqual(result.state, .completed); XCTAssertNil(result.response?.failure); XCTAssertNil(result.response?.unavailable)
        let manifest = try XCTUnwrap(result.response?.manifest)
        XCTAssertEqual(manifest.evidence, .nativeReadOnly); XCTAssertTrue(manifest.entries.isEmpty); XCTAssertEqual(manifest.unmatched, [declaration])
        XCTAssertEqual(manifest.coverage.count, 3)
        XCTAssertNoThrow(try HomebrewNativeLaunchServices.validateNative(manifest, context: context, declarations: [declaration]))
        XCTAssertNil(HomebrewTaskProcess.startIdentity(result.process.processIdentifier))
    }
    func testOwnedUserAndSystemAgentPlistsFreezeExactGUIAndInactiveFilesWithoutInventedJobs() throws {
        let root = URL(fileURLWithPath: "/private/tmp/spinnet-launch-fixture-" + UUID().uuidString)
        try NativeFileQuarantine.makePrivateDirectory(root); defer { try? FileManager.default.removeItem(at: root) }
        for scope in ["systemDaemons", "systemAgents", "userAgents"] { try NativeFileQuarantine.makePrivateDirectory(root.appendingPathComponent(scope)) }
        let label = "com.vulpsecula.spinnet.owned.fixture"
        for scope in ["systemAgents", "userAgents"] {
            let bytes = try PropertyListSerialization.data(fromPropertyList: ["Label": label, "Program": "/usr/bin/true"], format: .xml, options: 0)
            let file = root.appendingPathComponent(scope + "/" + label + ".plist"); try bytes.write(to: file); XCTAssertEqual(chmod(file.path, 0o600), 0)
        }
        let context = try HomebrewNativeLaunchServices.Context(uid: getuid(), home: URL(fileURLWithPath: NSHomeDirectory()))
        let manifest = try HomebrewNativeLaunchServices.captureOwnedFixture(context: context, declarations: [.init(label)], root: root, jobs: [], deadline: Date().addingTimeInterval(5))
        XCTAssertEqual(manifest.evidence, .ownedFixture); XCTAssertEqual(manifest.entries.count, 1)
        let entry = try XCTUnwrap(manifest.entries.first)
        XCTAssertEqual(entry.domain, .gui(getuid())); XCTAssertEqual(entry.plists.count, 2); XCTAssertNil(entry.job)
        XCTAssertTrue(entry.plists.allSatisfy { $0.removeFile && !$0.frozen.sha256.isEmpty && $0.frozen.owner == getuid() })
        XCTAssertThrowsError(try HomebrewNativeLaunchServices.validateNative(manifest, context: context, declarations: [.init(label)]))
    }
    func testPrimaryHomebrewLaunchWildcardIsLiteralUnanchoredCaseSensitiveAndActiveOnly() throws {
        let declaration = try HomebrewNativeLaunchServices.Declaration("com.vendor.*")
        XCTAssertTrue(declaration.matches(label: "prefix.com.vendor.agent", pid: 42))
        XCTAssertFalse(declaration.matches(label: "com.vendor.agent", pid: 0))
        XCTAssertFalse(declaration.matches(label: "COM.VENDOR.agent", pid: 42))
        XCTAssertFalse(try HomebrewNativeLaunchServices.Declaration("com.vendor.?").matches(label: "com.vendor.x", pid: 42))
        XCTAssertTrue(try HomebrewNativeLaunchServices.Declaration("com.vendor.agent").matches(label: "com.vendor.agent", pid: 0))
        XCTAssertThrowsError(try HomebrewNativeLaunchServices.Declaration("com.apple.*"))
        XCTAssertThrowsError(try HomebrewNativeLaunchServices.Declaration("/private/tmp/anything.plist"))
    }
}
