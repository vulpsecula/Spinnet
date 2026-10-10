import XCTest
import SpinnetCore
import SpinnetPluginTestKit

final class ReviewedToolTaskTests: XCTestCase {
    func testPublishedTaskFixturesMatchPublicSchemaAndHostAdmission() throws {
        struct Entry: Decodable { let valid: Bool; let file: String; let definition: String }
        struct Index: Decodable { let fixtures: [Entry] }
        let api = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("PluginAPI")
        let directory = api.appendingPathComponent("fixtures/reviewed-tasks")
        let index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: directory.appendingPathComponent("index.json")))
        for entry in index.fixtures {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: directory.appendingPathComponent(entry.file)))
            let validator = try JSONSchemaSubsetValidator(definition: entry.definition, inSchemaAt: api.appendingPathComponent("schemas/reviewed-tools.schema.json"))
            XCTAssertEqual(validator.errors(for: value).isEmpty, entry.valid, entry.file)
            if entry.definition == "tools.startTask.input" {
                if entry.valid { XCTAssertNoThrow(try HomebrewTaskInput(value), entry.file) } else { XCTAssertThrowsError(try HomebrewTaskInput(value), entry.file) }
            }
        }
    }
    func testTaskInputNamesExactlyOnePackageAndRejectsOptionsOrUnreviewedWork() throws {
        let input: JSONValue = .object(["tool": .string("homebrew"), "operation": .string("install"), "kind": .string("formula"), "name": .string("wget")])
        XCTAssertEqual(try HomebrewTaskInput(input).arguments, ["install", "--formula", "--", "wget"])
        for bad in ["--HEAD", "./evil.rb", "two names"] {
            XCTAssertThrowsError(try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("install"), "kind": .string("formula"), "name": .string(bad)])))
        }
        XCTAssertThrowsError(try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("exec"), "kind": .string("formula"), "name": .string("wget")])))
    }
    func testUpgradeAllBothKindsMustOmitKindInsteadOfAddingUndocumentedKind() throws {
        let base: [String: JSONValue] = ["tool": .string("homebrew"), "operation": .string("upgradeAll")]
        XCTAssertEqual(try HomebrewTaskInput(.object(base)).kind, "both")
        var explicit = base; explicit["kind"] = .string("both")
        XCTAssertThrowsError(try HomebrewTaskInput(.object(explicit)))
    }
    func testCaskLanguageChangeUsesOnlyReviewedDeclaredLanguage() throws {
        let input: JSONValue = .object(["tool": .string("homebrew"), "operation": .string("changeLanguage"), "kind": .string("cask"), "name": .string("firefox"), "language": .string("en-GB")])
        XCTAssertEqual(try HomebrewTaskInput(input).arguments, ["reinstall", "--cask", "--language=en-GB", "--", "firefox"])
        guard case .object(var fields) = input else { return XCTFail("input") }; fields["language"] = .string("--evil")
        XCTAssertThrowsError(try HomebrewTaskInput(.object(fields)))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = HostReviewedToolTasks(activities: HostActivities(), journal: root, runnerURL: URL(fileURLWithPath: "/missing"), executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, preflight: { _ in .object(["tap": .string("homebrew/cask"), "installed_version": .string("1"), "languages": .array([.string("en-US")])]) }, trustedTaps: { [] })
        XCTAssertThrowsError(try host.prepare(HomebrewTaskInput(input), owner: PluginID("a"), pluginName: "Homebrew")) { XCTAssertEqual($0 as? PluginHostServiceError, .tool(.planChanged)) }
        fields["language"] = .string("en-US")
        let plan = try host.prepare(HomebrewTaskInput(.object(fields)), owner: PluginID("a"), pluginName: "Homebrew")
        XCTAssertTrue(plan.confirmation.message.contains("Reinstalls the App with language en-US"))
        host.decline(plan)
    }
    func testStopReachesChildAfterLeaderExitedAndReportsNoRollback() throws {
        let process = HomebrewTaskProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "(sleep 5) & exit 0"], environment: HomebrewReadProfile.environment, interruptGrace: 0.05, terminateGrace: 0.05)
        let finished = expectation(description: "process group ended")
        var result: HomebrewTaskProcess.Result?
        try process.start(output: { _ in }, finished: { result = $0; finished.fulfill() })
        process.stop()
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(result?.outcome, "stopped")
        XCTAssertNotNil(result?.stop)
    }
    func testTaskOutputIsBoundedAndRedactsSplitSecretsBeforePublication() throws {
        let log = HomebrewTaskLog()
        log.append(Data("\u{1b}[31mDownloading https://alice:secret@example.com/x?token=abc\nAPI_TOKEN=super".utf8))
        log.append(Data("secret\nAuthorization: Bearer secret\n/Users/test/home/package\n".utf8), home: "/Users/test/home")
        XCTAssertEqual(log.lines, ["Downloading https://example.com/x", "API_TOKEN=…", "Authorization: …", "~/package"])
        for _ in 0..<100 { log.append(Data((String(repeating: "a", count: 250) + "\n").utf8)) }
        XCTAssertEqual(log.lines.count, 20)
        XCTAssertTrue(log.lines.allSatisfy { $0.count <= 200 })
    }
    func testExpandedManagementUsesTypedTargetsAndNeverAcceptsRepairOrShellText() throws {
        XCTAssertEqual(try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("trust"), "tap": .string("hashicorp/tap")])).arguments, ["trust", "--tap", "--", "hashicorp/tap"])
        XCTAssertEqual(try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("cleanup"), "pruneAll": .bool(true)])).arguments, ["cleanup", "--prune=all"])
        XCTAssertThrowsError(try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("doctorFix"), "command": .string("rm -rf /")])))
        XCTAssertThrowsError(try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("serviceStart"), "name": .string("foo;evil")])))
    }
    func testOversizedPreflightIsRefusedBeforeConfirmationOrRunnerLaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = HostReviewedToolTasks(activities: HostActivities(), journal: root, runnerURL: URL(fileURLWithPath: "/missing"), executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, preflight: { _ in .object(["tap": .string("homebrew/core"), "metadata": .string(String(repeating: "x", count: 2 * 1024 * 1024))]) }, trustedTaps: { [] })
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("install"), "kind": .string("formula"), "name": .string("wget")]))
        XCTAssertThrowsError(try host.prepare(input, owner: PluginID("a"), pluginName: "Homebrew")) { XCTAssertEqual($0 as? PluginHostServiceError, .tool(.outputTooLarge)) }
        XCTAssertFalse(host.hasRunningTasks)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    func testAdmissionNamesResolvedSourceAndSerializesAcrossPluginOwners() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = HostReviewedToolTasks(activities: HostActivities(), journal: root, runnerURL: URL(fileURLWithPath: "/missing"),
            executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, preflight: { _ in
                .object(["name": .string("wget"), "tap": .string("homebrew/core"), "version": .string("1.25")])
            }, trustedTaps: { [] })
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("install"), "kind": .string("formula"), "name": .string("wget")]))
        let plan = try host.prepare(input, owner: PluginID("a"), pluginName: "Package Browser")
        XCTAssertTrue(plan.confirmation.message.contains("homebrew/core"))
        XCTAssertTrue(plan.confirmation.message.contains("Stopping does not undo"))
        XCTAssertThrowsError(try host.prepare(input, owner: PluginID("b"), pluginName: "Other"))
        host.decline(plan)
        XCTAssertNoThrow(try host.prepare(input, owner: PluginID("b"), pluginName: "Other"))
    }
    func testRunnerSurvivesOwnerDetachmentAndHostRecoveryNeverReplaysMutation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = root.appendingPathComponent("runner")
        try Data("""
        #!/bin/sh
        taskdir="$2"
        echo started >> "$taskdir/started"
        while [ ! -f "$taskdir/stop" ]; do sleep 0.02; done
        /usr/bin/plutil -replace result -json '{"outcome":"stopped","stop":"interrupted"}' -o "$taskdir/task.json" "$taskdir/task.json"
        """.utf8).write(to: runner)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runner.path)
        let journal = root.appendingPathComponent("journal"), owner = PluginID("brew-browser"), activities = HostActivities()
        let preflight: HostReviewedToolTasks.Preflight = { _ in .object(["tap": .string("homebrew/core"), "name": .string("wget")]) }
        var host: HostReviewedToolTasks? = HostReviewedToolTasks(activities: activities, journal: journal, runnerURL: runner,
            executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, preflight: preflight, trustedTaps: { [] })
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("install"), "kind": .string("formula"), "name": .string("wget")]))
        let plan = try host!.prepare(input, owner: owner, pluginName: "Homebrew")
        let id = try host!.launch(plan), directory = journal.appendingPathComponent(id)
        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("started").path), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        host!.invalidate(owner)
        XCTAssertTrue(host!.hasRunningTasks)
        XCTAssertTrue(activities.list(for: owner).isEmpty)
        XCTAssertEqual(activities.list().count, 1)
        host = nil
        let restoredActivities = HostActivities()
        let restored = HostReviewedToolTasks(activities: restoredActivities, journal: journal, runnerURL: runner,
            executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, preflight: preflight, trustedTaps: { [] })
        XCTAssertTrue(restored.hasRunningTasks)
        XCTAssertTrue(restoredActivities.list(for: owner).isEmpty)
        try restored.stop(id)
        while restored.hasRunningTasks, Date() < deadline { restored.refresh(); Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertFalse(restored.hasRunningTasks)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("started")), "started\n")
        XCTAssertEqual(restoredActivities.list().first?.json.value(atPointer: "/result/outcome"), .string("stopped"))
    }
    func testRevokedAdmissionCannotResurrectAfterRegrantAndUntrustedTapCannotStart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = PluginID("brew-browser")
        let host = HostReviewedToolTasks(activities: HostActivities(), journal: root, runnerURL: URL(fileURLWithPath: "/missing"),
            executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, preflight: { _ in .object(["tap": .string("homebrew/core")]) }, trustedTaps: { [] })
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("install"), "kind": .string("formula"), "name": .string("wget")]))
        let plan = try host.prepare(input, owner: owner, pluginName: "Homebrew")
        host.invalidate(owner)
        XCTAssertThrowsError(try host.launch(plan))
        let untrusted = HostReviewedToolTasks(activities: HostActivities(), journal: root, runnerURL: URL(fileURLWithPath: "/missing"),
            executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, preflight: { _ in .object(["tap": .string("other/tap")]) }, trustedTaps: { [] })
        XCTAssertThrowsError(try untrusted.prepare(input, owner: owner, pluginName: "Homebrew")) { XCTAssertEqual($0 as? PluginHostServiceError, .tool(.sourceNotAllowed)) }
    }
    func testAllUpgradesResolveBothKindsRespectPinsAndKeepExplicitTypedBatches() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = HostReviewedToolTasks(activities: HostActivities(), journal: root, runnerURL: URL(fileURLWithPath: "/missing"), executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, preflight: { _ in
            .object(["packages": .array([
                .object(["kind": .string("formula"), "name": .string("wget"), "tap": .string("homebrew/core")]),
                .object(["kind": .string("formula"), "name": .string("git"), "tap": .string("homebrew/core"), "pinned": .bool(true)]),
                .object(["kind": .string("cask"), "name": .string("firefox"), "tap": .string("homebrew/cask")])])])
        }, trustedTaps: { [] })
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("upgradeAll")]))
        let plan = try host.prepare(input, owner: PluginID("brew"), pluginName: "Homebrew")
        XCTAssertEqual(plan.steps.map(\.arguments), [["upgrade", "--formula", "--", "wget"], ["upgrade", "--cask", "--", "firefox"]])
        XCTAssertTrue(plan.confirmation.message.contains("wget"))
        XCTAssertTrue(plan.confirmation.message.contains("firefox"))
        XCTAssertFalse(plan.confirmation.message.contains(" git"))
    }
}
