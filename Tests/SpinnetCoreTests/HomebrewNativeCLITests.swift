import XCTest
import Darwin
@testable import SpinnetCore

final class HomebrewNativeCLITests: XCTestCase {
    func testNonSudoParentCannotOpenAPasswordWindowOrRedirectItsPassword() {
        XCTAssertThrowsError(try HomebrewAskpass.verifySudoParent())
    }
    func testProvenEndedLegacyTaskRetiresItsDaemonDependencyWithoutReplaying() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let id = "activity_1234567890abcdef1234567890abcdef", directory = root.appendingPathComponent("activity_1234567890abcdef1234567890abcdef")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        var record = HomebrewTaskJournal(id: id, owner: "legacy", pluginName: "Homebrew",
            input: .object(["tool": .string("homebrew"), "operation": .string("upgrade"), "kind": .string("cask"), "name": .string("example")]),
            package: .object([:]), executable: "/opt/homebrew/bin/brew", started: Date(), detached: false,
            runnerPID: Int32.max, runnerIdentity: 1, processGroup: nil, processIdentity: nil,
            stage: "completed", log: [], result: .object(["outcome": .string("completed")]), ended: Date())
        record.privilegePlan = try HomebrewPrivilegePlan(taskID: id, prefix: "/opt/homebrew",
            casks: [.init(name: "example", version: "1", sha256: String(repeating: "a", count: 64), packages: ["Example.pkg"])], operation: "upgrade")
        try record.save(to: directory)
        try HomebrewTaskProcessLease(taskID: id, runnerPID: Int32.max, runnerIdentity: 1).save(to: directory)
        let host = HostReviewedToolTasks(activities: .init(), journal: root, runnerURL: root.appendingPathComponent("must-not-launch"), privilegedTaskIsRunning: { _ in false })
        let deadline = Date().addingTimeInterval(2)
        while (try HomebrewTaskJournal.load(from: directory)).privilegePlan != nil && Date() < deadline {
            host.refresh(); Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertNil(try HomebrewTaskJournal.load(from: directory).privilegePlan)
        XCTAssertEqual(try HomebrewTaskJournal.load(from: directory).result, record.result)
        let restarted = HostReviewedToolTasks(activities: .init(), journal: root, runnerURL: root.appendingPathComponent("must-not-launch"), privilegedTaskIsRunning: { _ in
            XCTFail("An ended, proven-reaped Task must not require the legacy daemon again")
            throw PluginHostServiceError.tool(.missing)
        })
        XCTAssertFalse(restarted.hasRunningTasks)
    }
    func testCaskAdmissionDoesNotLoadPrivateRubyOrRequireBackgroundApproval() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("future/bin/brew")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        #!/bin/sh
        case "$1" in
        --version) printf 'Homebrew 8.1.0\\n' ;;
        info) printf '%s\\n' '{"formulae":[],"casks":[{"token":"spotify","full_token":"spotify","tap":"homebrew/cask","version":"2","installed":["1"],"outdated":true,"artifacts":[{"pkg":["Example.pkg"]}]}],"future":true}' ;;
        *) exit 64 ;;
        esac
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        // This tree deliberately has none of the previously allowlisted Ruby
        // files. Exercise the real read -> prepare -> confirm -> journal path.
        let journal = root.appendingPathComponent("journal")
        let host = HostReviewedToolTasks(activities: .init(), journal: journal, runnerURL: URL(fileURLWithPath: "/usr/bin/true"), executable: { executable })
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("upgrade"),
                                                "kind": .string("cask"), "name": .string("spotify")]))
        let plan = try host.prepare(input, owner: .init("native-cli"), pluginName: "Homebrew")
        XCTAssertTrue(plan.nativeCLI)
        XCTAssertFalse(plan.requiresNativeInspection)
        XCTAssertFalse(plan.needsSystemAuthorization)
        XCTAssertTrue(plan.confirmation.message.contains("login password"))
        let id = try host.launch(plan)
        let record = try HomebrewTaskJournal.load(from: journal.appendingPathComponent(id))
        XCTAssertEqual(record.executionModel, "native-cli-v1")
        XCTAssertNil(record.privilegePlan)
    }

    func testAskpassEnvironmentAllowsSudoWithoutPassingCredentialsOrInput() {
        let env = HomebrewAskpass.taskEnvironment(askpass: URL(fileURLWithPath: "/signed/SpinnetHomebrewAskpass"), socket: "/private/tmp/socket")
        XCTAssertNil(env["NONINTERACTIVE"])
        XCTAssertNil(env["HOMEBREW_NO_SUDO"])
        XCTAssertEqual(env["SUDO_ASKPASS"], "/signed/SpinnetHomebrewAskpass")
        XCTAssertEqual(env[HomebrewAskpass.socketEnvironment], "/private/tmp/socket")
        XCTAssertEqual(env["HOMEBREW_NO_AUTO_UPDATE"], "1")
        XCTAssertNil(env["SSH_AUTH_SOCK"])
        XCTAssertNil(env["PASSWORD"])
    }

    func testAskpassOnlySuppliesContextDuringAnActiveCommandAndStopsOnCancellation() throws {
        let waiting = expectation(description: "password window admitted"), ended = expectation(description: "password window released")
        let server = try HomebrewAskpass.Server(verify: { _ in }, changed: { active in (active ? waiting : ended).fulfill() })
        defer { server.stop() }
        server.setCommand("brew upgrade --cask -- spotify")
        let fd = try HomebrewAskpass.connect(server.path)
        defer { close(fd) }
        let context = try JSONDecoder().decode(HomebrewAskpass.Context.self, from: HomebrewAskpass.receive(fd))
        XCTAssertEqual(context.command, "brew upgrade --cask -- spotify")
        wait(for: [waiting], timeout: 2)
        server.setCommand(nil)
        var byte: UInt8 = 0
        XCTAssertEqual(read(fd, &byte, 1), 0, "Stop closes the authorization channel so a visible password window can dismiss")
        wait(for: [ended], timeout: 2)
        let refused = try HomebrewAskpass.connect(server.path)
        defer { close(refused) }
        XCTAssertThrowsError(try HomebrewAskpass.receive(refused))
    }

    func testUnsignedAskpassPeerCannotObtainPromptContext() throws {
        let server = try HomebrewAskpass.Server { _ in XCTFail("An unsigned peer must never be admitted") }
        defer { server.stop() }
        server.setCommand("brew upgrade --cask -- example")
        let fd = try HomebrewAskpass.connect(server.path)
        defer { close(fd) }
        XCTAssertThrowsError(try HomebrewAskpass.receive(fd))
    }

    func testFutureHomebrewUsesDocumentedPreviewsWithNoSourceCohort() throws {
        var calls: [[String]] = []
        let profile = HomebrewReadProfile(executable: { URL(fileURLWithPath: "/future/bin/brew") }, execute: { _, args, _, _ in
            calls.append(args)
            switch args.first {
            case "--version": return .init(status: 0, stdout: Data("Homebrew 8.1.0\n".utf8))
            case "autoremove": return .init(status: 0, stdout: Data("==> Would autoremove 1 unneeded formula:\nexample\n".utf8))
            case "info": return .init(status: 0, stdout: Data(#"{"formulae":[{"name":"example","full_name":"example","tap":"homebrew/core","installed":[{"version":"1"}],"versions":{"stable":"2"}}],"casks":[],"future":true}"#.utf8))
            case "install", "link": return .init(status: 0, stdout: Data("Native dry-run output\n".utf8))
            default: throw PluginHostServiceError.tool(.failed)
            }
        })
        for operation in ["previewAutoremove", "previewInstall", "previewLink"] {
            var input: [String: JSONValue] = ["tool": .string("homebrew"), "operation": .string(operation)]
            if operation != "previewAutoremove" { input["kind"] = .string("formula"); input["names"] = .array([.string("example")]) }
            let value = try profile.read(.object(input), owner: .init("future-cli"))
            XCTAssertEqual(value.value(atPointer: "/available"), .bool(true))
            XCTAssertEqual(value.value(atPointer: "/succeeded"), .bool(true))
        }
        XCTAssertTrue(calls.contains(["autoremove", "--dry-run"]))
        XCTAssertTrue(calls.contains(["install", "--dry-run", "--formula", "--", "example"]))
        XCTAssertTrue(calls.contains(["link", "--dry-run", "--formula", "--", "example"]))
        XCTAssertFalse(calls.contains { $0.first == "ruby" || $0.first == "host-trust" })
    }

    func testChangedAutoremoveTextRemainsVisibleWithoutInventingRemovalTargets() throws {
        let text = "Homebrew future format\nexample\n"
        let value = try HomebrewCLIPreview.autoremove(.init(status: 0, stdout: Data(text.utf8)), version: "8.1.0")
        XCTAssertEqual(value["stdout"], .string(text))
        XCTAssertEqual(value["complete"], .bool(false))
        XCTAssertEqual(value["packages"], .array([]))
    }
}
