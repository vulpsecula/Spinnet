import SpinnetTestSupport
import XCTest
@testable import SpinnetCore
@testable import SpinnetReviewedTools
import SpinnetPluginTestKit

final class ReviewedToolTaskTests: XCTestCase {
    func testOpaqueMetadataPreparationFailureNamesTheStageAndReleasesTheLane() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = HostReviewedToolTasks(activities: .init(), journal: root, runnerURL: URL(fileURLWithPath: "/missing"),
            executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, preflight: { _ in throw PluginHostServiceError.tool(.failed) })
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("upgrade"), "kind": .string("cask"), "name": .string("example")]))
        XCTAssertThrowsError(try host.prepare(input, owner: .init("metadata-failure"), pluginName: "Homebrew")) { error in
            guard case .toolReadFailed(let message) = error as? PluginHostServiceError else { return XCTFail("Missing preparation context") }
            XCTAssertTrue(message.contains("reading selected package metadata"))
        }
        XCTAssertFalse(host.hasRunningTasks)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    func testCancellingPreparationSignalsWorkerAndHoldsLaneUntilActualCompletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let started = DispatchSemaphore(value: 0), stopped = DispatchSemaphore(value: 0), reap = DispatchSemaphore(value: 0)
        let done = expectation(description: "cancelled preflight actually ended")
        let host = HostReviewedToolTasks(activities: HostActivities(), journal: root, runnerURL: URL(fileURLWithPath: "/missing"), executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, cancellablePreflight: { _, cancellation in
            let remove = cancellation.onCancel { stopped.signal() }; defer { remove() }
            started.signal()
            guard stopped.wait(timeout: .now() + 2) == .success else { throw PluginHostServiceError.tool(.timedOut) }
            guard reap.wait(timeout: .now() + 2) == .success else { throw PluginHostServiceError.tool(.timedOut) }
            throw PluginHostServiceError.unavailable("The preflight was cancelled")
        })
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("install"), "kind": .string("formula"), "name": .string("example")]))
        let owner = PluginID("source-review")
        DispatchQueue.global().async {
            do { _ = try host.prepare(input, owner: owner, pluginName: "Homebrew"); XCTFail("Cancelled preparation succeeded") }
            catch { XCTAssertEqual(error as? PluginHostServiceError, .unavailable("The preflight was cancelled")) }
            done.fulfill()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        host.cancelPending(for: owner)
        XCTAssertTrue(host.hasRunningTasks, "Cancellation is not a proof the owned worker reaped")
        XCTAssertThrowsError(try host.prepare(input, owner: PluginID("other"), pluginName: "Other")) { XCTAssertEqual($0 as? PluginHostServiceError, .tool(.busy)) }
        reap.signal(); wait(for: [done], timeout: 3)
        XCTAssertFalse(host.hasRunningTasks)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "No mutation journal or replay authority is created by cancelled preparation")
    }
    private final class WaitingNativeConfirmation: HostConfirming {
        var shown: [HostConfirmation] = []
        var answers: [(HostConfirmationAnswer) -> Void] = []
        func confirm(_ confirmation: HostConfirmation, for action: ActionConfiguration, answer: @escaping (HostConfirmationAnswer) -> Void) -> () -> Void {
            shown.append(confirmation); answers.append(answer); return {}
        }
    }
    func testNativeCaskUsesOneHostConfirmationAndViewClosureCancelsBeforeLaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = PluginID("native-cli-confirmation")
        let command = CommandDeclaration(id: .init("upgrade"), title: "Upgrade", execution: .javascript, script: "upgrade.js")
        let scope = PluginCapabilityScope(capability: .runReviewedToolTasks, commandIDs: [command.id], reviewedTools: [.init(tool: "homebrew", operations: ["upgrade"], kinds: ["cask"])])
        let manifest = try PluginManifest(id: owner, name: "Homebrew", version: "1.0", capabilities: [.runReviewedToolTasks], capabilityScopes: [scope], commands: [command])
        let registry = PluginRegistry(); try registry.register(.init(rootURL: root, manifest: manifest, origin: .installed))
        let action = try ActionConfiguration(id: .init("upgrade"), pluginID: owner, command: command, input: .null)
        let host = HostReviewedToolTasks(activities: .init(), journal: root.appendingPathComponent("journal"), runnerURL: root.appendingPathComponent("must-not-launch"),
            executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, preflight: { _ in
                .object(["kind": .string("cask"), "name": .string("example"), "tap": .string("homebrew/cask"), "needs_privileges": .bool(true)])
            })
        let confirmation = WaitingNativeConfirmation()
        let performer = ReviewedTaskOperationPerformer(tasks: host, confirmations: confirmation, registry: registry, background: { $0() }, executor: { $0() }, schedule: { _, _ in })
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("upgrade"), "kind": .string("cask"), "name": .string("example")]))
        var outcomes: [HostOperationOutcome] = []
        performer.perform(input, for: action, accepted: performer.accept(owner: owner), authorize: {}, completion: { outcomes.append($0.outcome) })
        XCTAssertEqual(confirmation.shown.count, 1)
        XCTAssertTrue(confirmation.shown[0].message.contains("login password"))
        performer.abandon(owner, because: .viewClosed)
        confirmation.answers[0](.confirmed)
        XCTAssertEqual(outcomes, [.cancelled])
        XCTAssertFalse(host.hasRunningTasks)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("journal").path))
    }




    func testSelectedUpgradeReviewListsEveryResolvedPackageForSmallAndMaximumSelection() throws {
        for count in [3, 50] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let packages: [JSONValue] = (0..<count).map { .object(["kind": .string("formula"), "name": .string("package\($0)"),
                "tap": .string("homebrew/core"), "installed_version": .string("1"), "version": .string("2")]) }
            let host = HostReviewedToolTasks(activities: HostActivities(), journal: root, runnerURL: URL(fileURLWithPath: "/missing"),
                executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, preflight: { _ in .object(["packages": .array(packages)]) }, trustedTaps: { [] })
            let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("upgradeSelected"), "kind": .string("formula"),
                "names": .array((0..<count).map { .string("alias\($0)") })]))
            let plan = try host.prepare(input, owner: .init("selected-upgrades"), pluginName: "Homebrew")
            let details = try XCTUnwrap(plan.confirmation.details)
            let rows = details.rows.filter { $0.id.hasPrefix("package-target/") }
            XCTAssertEqual(rows.count, count)
            for index in 0..<count { XCTAssertTrue(rows.contains { $0.id == "package-target/formula/package\(index)" && $0.title == "Upgrade package\(index)" && $0.detail.contains("1 → 2") }) }
            XCTAssertFalse(details.rows.contains { $0.title.contains("alias") }, "Confirmation must use the same canonical names as execution")
            host.decline(plan)
        }
    }



    func testUninstallDoesNotBorrowTheCurrentCatalogInstallerAuthorization() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = HostReviewedToolTasks(activities: HostActivities(), journal: root, runnerURL: URL(fileURLWithPath: "/missing"),
            executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, preflight: { _ in
                .object(["name": .string("example"), "kind": .string("cask"), "tap": .string("homebrew/cask"), "installed_version": .string("1"), "needs_privileges": .bool(true)])
            }, trustedTaps: { [] })
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("uninstall"), "kind": .string("cask"), "name": .string("example")]))
        let plan = try host.prepare(input, owner: .init("ordinary-removal"), pluginName: "Homebrew")
        XCTAssertEqual(plan.executionModel, "native-cli-v1", "Metadata cannot select a legacy Root execution model")
        XCTAssertFalse(plan.confirmation.message.contains("macOS system authorization"))
        host.decline(plan)
    }

    func testNativeZapAdmissionFlagAppliesOnlyToExplicitUninstallZap() throws {
        for zap in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
                let host = HostReviewedToolTasks(activities: HostActivities(), journal: root, runnerURL: URL(fileURLWithPath: "/missing"), executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, preflight: { _ in
                .object(["name": .string("example"), "kind": .string("cask"), "tap": .string("homebrew/cask"), "installed_version": .string("1"), "zap_needs_privileges": .bool(true)])
            })
            let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("uninstall"), "kind": .string("cask"), "name": .string("example"), "zap": .bool(zap)]))
            let plan = try host.prepare(input, owner: PluginID("zap-review"), pluginName: "Homebrew")
            XCTAssertEqual(plan.executionModel, "native-cli-v1", "Metadata cannot select a legacy Root execution model")
                XCTAssertEqual(plan.confirmation.message.contains("Zap deletes"), zap)
            host.decline(plan)
        }
    }
    func testPrefixLinkAndPinActionsDoNotBorrowCaskInstallerSystemAuthorization() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for operation in ["link", "unlink", "pin", "unpin"] {
            let change: JSONValue = operation == "unlink" ? .object(["action": .string("unlink"), "path": .string("/opt/homebrew/bin/example")]) : .object(["action": .string("link"), "path": .string("/opt/homebrew/bin/example"), "source": .string("/opt/homebrew/Caskroom/example/1/example")])
            let host = HostReviewedToolTasks(activities: HostActivities(), journal: root, runnerURL: URL(fileURLWithPath: "/missing"), executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, preflight: { _ in
                .object(["kind": .string("cask"), "name": .string("example"), "tap": .string("homebrew/cask"), "installed_version": .string("1"),
                    "needs_privileges": .bool(true), "uninstall_needs_privileges": .bool(true), "quits_app": .bool(true), "link_preview": .object([
                        "succeeded": .bool(true), "complete": .bool(true), "truncated": .bool(false), "no_op": .bool(false), "paths": .array([.string("/opt/homebrew/bin/example")]),
                        "paths_fingerprint": .string(String(repeating: "a", count: 64)), "changes": .array([change])])])
            }, trustedTaps: { [] })
            let plan = try host.prepare(HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string(operation), "kind": .string("cask"), "name": .string("example")])), owner: PluginID("cask-metadata"), pluginName: "Homebrew")
            XCTAssertEqual(plan.executionModel, "native-cli-v1", "Metadata cannot select a legacy Root execution model")
            XCTAssertFalse(plan.confirmation.message.contains("macOS system authorization"))
            XCTAssertFalse(plan.confirmation.message.contains("quit the affected App"))
            host.decline(plan)
        }
    }

    func testLinkConfirmationUsesNativeOperationAndChangedMetadataRefusesLaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var installedVersion = "1"
        let host = HostReviewedToolTasks(activities: .init(), journal: root, runnerURL: URL(fileURLWithPath: "/missing"),
            executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, preflight: { _ in
                .object(["name": .string("wget"), "kind": .string("formula"), "tap": .string("homebrew/core"), "installed_version": .string(installedVersion)])
            }, trustedTaps: { [] })
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("link"), "kind": .string("formula"), "name": .string("wget")]))
        let plan = try host.prepare(input, owner: .init("native-links"), pluginName: "Homebrew")
        XCTAssertTrue(plan.confirmation.message.contains("Homebrew will link wget"))
        installedVersion = "2"
        XCTAssertThrowsError(try host.launch(plan)) { XCTAssertEqual($0 as? PluginHostServiceError, .tool(.planChanged)) }
    }
    func testAHostReplacedOnDiskSaysToReopenInsteadOfStartingARunnerThatRefuses() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var replaced = true
        let host = HostReviewedToolTasks(activities: .init(), journal: root, runnerURL: URL(fileURLWithPath: "/must-not-launch"),
            executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, preflight: { _ in
                .object(["name": .string("wget"), "kind": .string("formula"), "tap": .string("homebrew/core"), "installed_version": .string("1")])
            }, trustedTaps: { [] }, hostIsCurrent: { if replaced { throw PluginHostServiceError.unavailable(HostCodeCurrency.message) } })
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("link"), "kind": .string("formula"), "name": .string("wget")]))
        let owner = PluginID("replaced-host")
        XCTAssertThrowsError(try host.prepare(input, owner: owner, pluginName: "Homebrew")) {
            XCTAssertEqual($0 as? PluginHostServiceError, .unavailable(HostCodeCurrency.message))
        }
        XCTAssertFalse(host.hasRunningTasks)

        // Replaced while the Host Confirmation was shown.
        replaced = false
        let plan = try host.prepare(input, owner: owner, pluginName: "Homebrew")
        replaced = true
        XCTAssertThrowsError(try host.launch(plan)) {
            XCTAssertEqual($0 as? PluginHostServiceError, .unavailable(HostCodeCurrency.message))
            XCTAssertTrue("\($0)".contains("Quit and reopen Spinnet"))
        }
        XCTAssertFalse(host.hasRunningTasks)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "No Task journal or runner exists for a Task that cannot start")
    }
    func testLinkWithoutInstalledMetadataCannotReachConfirmation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = HostReviewedToolTasks(activities: .init(), journal: root, runnerURL: URL(fileURLWithPath: "/missing"),
            executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, preflight: { _ in
                .object(["name": .string("wget"), "kind": .string("formula"), "tap": .string("homebrew/core")])
            }, trustedTaps: { [] })
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("link"), "kind": .string("formula"), "name": .string("wget")]))
        XCTAssertThrowsError(try host.prepare(input, owner: .init("missing-keg"), pluginName: "Homebrew")) { XCTAssertEqual($0 as? PluginHostServiceError, .tool(.planChanged)) }
        XCTAssertFalse(host.hasRunningTasks)
    }
    func testPublishedTaskFixturesMatchPublicSchemaAndHostAdmission() throws {
        struct Entry: Decodable { let valid: Bool; let file: String; let definition: String }
        struct Index: Decodable { let fixtures: [Entry] }
        let api = TestRepository.root.appendingPathComponent("PluginAPI")
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
    func testCatalogRefreshIsOneGlobalConfirmedTaskWithNoPackageOrOptionsAuthority() throws {
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("update")]))
        XCTAssertEqual(input.arguments, ["update"])
        XCTAssertEqual(input.kind, "both")
        let formulaOnly = PluginCapabilityScope(capability: .runReviewedToolTasks, commandIDs: [CommandID("updates")], reviewedTools: [.init(tool: "homebrew", operations: ["update"], kinds: ["formula"])])
        XCTAssertThrowsError(try input.authorize(in: formulaOnly)) { XCTAssertEqual($0 as? PluginHostServiceError, .capabilityScopeDenied(.runReviewedToolTasks)) }
        let both = PluginCapabilityScope(capability: .runReviewedToolTasks, commandIDs: [CommandID("updates")], reviewedTools: [.init(tool: "homebrew", operations: ["update"], kinds: ["formula", "cask"])])
        XCTAssertNoThrow(try input.authorize(in: both))
        XCTAssertThrowsError(try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("update"), "name": .string("wget")])))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = HostReviewedToolTasks(activities: HostActivities(), journal: root, runnerURL: URL(fileURLWithPath: "/missing"), executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, preflight: { _ in .object([:]) }, trustedTaps: { [] })
        let plan = try host.prepare(input, owner: PluginID("updates"), pluginName: "Homebrew")
        XCTAssertTrue(plan.confirmation.message.contains("Homebrew itself"))
        XCTAssertTrue(plan.confirmation.message.contains("all configured taps"))
        XCTAssertTrue(plan.confirmation.message.contains("package catalogs"))
        host.decline(plan)
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
        let startupDeadline = Date().addingTimeInterval(15)
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("started").path), Date() < startupDeadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("started").path))
        // This runner only waits for Stop; it never reserves a mutation.
        // Complete the real runner's birth-bound launch handshake rather
        // than leaving the Host's launch-pending lease unresolved forever.
        let launchLease = try HomebrewTaskProcessLease.load(from: directory)
        XCTAssertTrue(launchLease.runnerLaunchPending)
        XCTAssertNil(launchLease.reservation)
        XCTAssertNil(launchLease.leaderPID)
        XCTAssertTrue(launchLease.members.isEmpty)
        XCTAssertFalse(launchLease.ownershipUncertain)
        let identity = try XCTUnwrap(HomebrewTaskProcessLease.loadRunnerIdentity(from: directory))
        XCTAssertEqual(HomebrewTaskProcess.startIdentity(identity.pid), identity.identity)
        try HomebrewTaskProcessLease(taskID: id, runnerPID: identity.pid, runnerIdentity: identity.identity).save(to: directory)
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
        let stopDeadline = Date().addingTimeInterval(5)
        while restored.hasRunningTasks, Date() < stopDeadline { restored.refresh(); Thread.sleep(forTimeInterval: 0.01) }
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
                .object(["kind": .string("cask"), "name": .string("firefox"), "tap": .string("homebrew/cask"), "needs_privileges": .bool(true), "quits_app": .bool(true)])])])
        }, trustedTaps: { [] })
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("upgradeAll")]))
        let plan = try host.prepare(input, owner: PluginID("brew"), pluginName: "Homebrew")
        XCTAssertEqual(plan.steps.map(\.arguments), [["upgrade", "--formula", "--", "wget"], ["upgrade", "--cask", "--", "firefox"]])
        XCTAssertTrue(plan.confirmation.message.contains("wget"))
        XCTAssertTrue(plan.confirmation.message.contains("firefox"))
        XCTAssertFalse(plan.confirmation.message.contains(" git"))
        XCTAssertTrue(plan.confirmation.message.contains("login password"))
        XCTAssertTrue(plan.confirmation.message.contains("may quit the affected App"))
    }
}

extension ReviewedToolTaskTests {
    func testIssuedDoctorBatchTargetReachesHostConfirmationThroughRealResolver() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let targets = HomebrewManagementTargets(), owner = PluginID("doctor")
        let profile = HomebrewReadProfile(executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, execute: { _, args, _, _ in
            if args == ["--version"] { return .init(status: 0, stdout: Data("Homebrew 7.0.0\n".utf8)) }
            return .init(status: 1, stdout: Data(#"{"tier":2,"findings":[{"text":"Repairs","remediation":{"commands":["brew link wget","brew cleanup"]}}]}"#.utf8))
        }, management: HomebrewManagementReads(targets: targets))
        let result = try profile.read(.object(["tool": .string("homebrew"), "operation": .string("doctor")]), owner: owner)
        guard case .string(let key)? = result.value(atPointer: "/fix_all/target") else { return XCTFail("Missing opaque Doctor set") }
        let host = HostReviewedToolTasks(activities: HostActivities(), journal: root, runnerURL: URL(fileURLWithPath: "/missing"), executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, preflight: { _ in .object([:]) }, trustedTaps: { [] }, targetResolver: targets.resolveTask)
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("doctorFix"), "target": .string(key)]))
        let plan = try host.prepare(input, owner: owner, pluginName: "Homebrew")
        XCTAssertEqual(plan.steps.map(\.arguments), [["link", "--formula", "--", "wget"], ["cleanup", "--prune=120"]])
        XCTAssertTrue(plan.confirmation.message.contains("stale downloads"))
        host.decline(plan)
    }
    func testDoctorFixAllFreezesConcreteRepairsAndChecksEachOriginalScope() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = PluginCapabilityScope(capability: .runReviewedToolTasks, commandIDs: [CommandID("repair")], reviewedTools: [.init(tool: "homebrew", operations: ["doctorFix"], kinds: ["formula"])])
        let first: JSONValue = .object(["tool": .string("homebrew"), "operation": .string("cleanup"), "days": .number(120)])
        let second: JSONValue = .object(["tool": .string("homebrew"), "operation": .string("link"), "kind": .string("formula"), "name": .string("wget")])
        var changed = false
        let host = HostReviewedToolTasks(activities: HostActivities(), journal: root, runnerURL: URL(fileURLWithPath: "/missing"), executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, preflight: { _ in .object(["tap": .string("homebrew/core")]) }, trustedTaps: { [] }, targetResolver: { _, _ in
            let input = try HomebrewTaskInput(first)
            return (input, .object(["doctor_steps": .array([.object(["input": first, "metadata": .object(["repair_summary": .string("Clean old downloads")])]), .object(["input": second, "metadata": .object(["repair_summary": .string(changed ? "Changed" : "Link wget")])])])]))
        })
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("doctorFix"), "target": .string("fix_batch")]))
        let plan = try host.prepare(input, owner: PluginID("repairer"), pluginName: "Homebrew", scope: scope)
        XCTAssertEqual(plan.steps.map(\.operation), ["cleanup", "link"])
        XCTAssertTrue(plan.confirmation.message.contains("Link wget"))
        changed = true
        XCTAssertThrowsError(try host.launch(plan)) { XCTAssertEqual($0 as? PluginHostServiceError, .tool(.planChanged)) }
    }
    func testScopedUpgradeAllAdmitsBothReviewedKinds() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = PluginCapabilityScope(capability: .runReviewedToolTasks, commandIDs: [CommandID("upgrade")], reviewedTools: [.init(tool: "homebrew", operations: ["upgradeAll"], kinds: ["formula", "cask"])])
        let host = HostReviewedToolTasks(activities: HostActivities(), journal: root, runnerURL: URL(fileURLWithPath: "/missing"), executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, preflight: { _ in
            .object(["packages": .array([.object(["kind": .string("formula"), "name": .string("wget")]), .object(["kind": .string("cask"), "name": .string("firefox")])])])
        }, trustedTaps: { [] })
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("upgradeAll")]))
        let plan = try host.prepare(input, owner: PluginID("upgrader"), pluginName: "Homebrew", scope: scope)
        XCTAssertEqual(plan.steps.map(\.kind), ["formula", "cask"])
        host.decline(plan)
    }
    func testAdoptionNeedsCaskScopeAndRejectsFormulaScopeBeforePreflight() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("adopt"), "target": .string("adoption_reviewed")]))
        let cask = PluginCapabilityScope(capability: .runReviewedToolTasks, commandIDs: [CommandID("adopt")], reviewedTools: [.init(tool: "homebrew", operations: ["adopt"], kinds: ["cask"])])
        let formula = PluginCapabilityScope(capability: .runReviewedToolTasks, commandIDs: [CommandID("adopt")], reviewedTools: [.init(tool: "homebrew", operations: ["adopt"], kinds: ["formula"])])
        var preflights = 0
        let host = HostReviewedToolTasks(activities: HostActivities(), journal: root, runnerURL: URL(fileURLWithPath: "/missing"), executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, preflight: { _ in preflights += 1; return .object(["kind": .string("cask"), "name": .string("example")]) }, trustedTaps: { [] }, targetResolver: { _, _ in
            (try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("install"), "kind": .string("cask"), "name": .string("example")])), .object(["adopt": .bool(true)]))
        })
        XCTAssertThrowsError(try host.prepare(input, owner: PluginID("adopter"), pluginName: "Homebrew", scope: formula)) { XCTAssertEqual($0 as? PluginHostServiceError, .capabilityScopeDenied(.runReviewedToolTasks)) }
        XCTAssertEqual(preflights, 0)
        let plan = try host.prepare(input, owner: PluginID("adopter"), pluginName: "Homebrew", scope: cask)
        XCTAssertEqual(plan.resolvedInput.kind, "cask")
        XCTAssertEqual(preflights, 1)
        host.decline(plan)
    }
    func testDoctorTargetCannotResolveToAnUnapprovedPackageKind() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = PluginCapabilityScope(capability: .runReviewedToolTasks, commandIDs: [CommandID("repair")], reviewedTools: [.init(tool: "homebrew", operations: ["doctorFix"], kinds: ["formula"])])
        let host = HostReviewedToolTasks(activities: HostActivities(), journal: root, runnerURL: URL(fileURLWithPath: "/missing"), executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, preflight: { _ in .object([:]) }, trustedTaps: { [] }, targetResolver: { _, _ in
            (try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("link"), "kind": .string("cask"), "name": .string("example")])), .object([:]))
        })
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("doctorFix"), "target": .string("fix_reviewed")]))
        XCTAssertThrowsError(try host.prepare(input, owner: PluginID("repairer"), pluginName: "Homebrew", scope: scope)) { XCTAssertEqual($0 as? PluginHostServiceError, .capabilityScopeDenied(.runReviewedToolTasks)) }
    }
}


extension ReviewedToolTaskTests {
    func testGreedyUpgradeAllOnlyAddsGreedyToItsCaskStep() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = HostReviewedToolTasks(activities: HostActivities(), journal: root, runnerURL: URL(fileURLWithPath: "/missing"), executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, preflight: { _ in
            .object(["packages": .array([.object(["kind": .string("formula"), "name": .string("wget")]), .object(["kind": .string("cask"), "name": .string("firefox")])])])
        }, trustedTaps: { [] })
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("upgradeAll"), "greedy": .bool(true)]))
        let plan = try host.prepare(input, owner: PluginID("upgrader"), pluginName: "Homebrew")
        XCTAssertEqual(plan.steps.map(\.arguments), [["upgrade", "--formula", "--", "wget"], ["upgrade", "--cask", "--greedy", "--", "firefox"]])
        host.decline(plan)
    }
}


extension ReviewedToolTaskTests {
}


extension ReviewedToolTaskTests {
    func testTaskPreparationHonorsCanonicalItemTrustWithoutGrantingWholeTapTrust() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("fixture-cli")
        try Data("""
        #!/bin/sh
        if [ "$1" = trust ] && [ "$2" = --formula ] && [ "$3" = --json=v1 ]; then
          printf '%s\\n' '["acme/tools/canonical"]'
        else
          printf '%s\\n' '[]'
        fi
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let host = HostReviewedToolTasks(activities: HostActivities(), journal: root.appendingPathComponent("journal"), runnerURL: URL(fileURLWithPath: "/missing"),
            executable: { executable }, preflight: { _ in .object(["name": .string("acme/tools/canonical"), "kind": .string("formula"), "tap": .string("acme/tools"), "version": .string("1")]) }, trustedTaps: { [] })
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("install"), "kind": .string("formula"), "name": .string("acme/tools/alias")]))
        let plan = try host.prepare(input, owner: PluginID("item-trust"), pluginName: "Homebrew")
        XCTAssertEqual(plan.resolvedInput.name, "acme/tools/canonical")
        XCTAssertTrue(plan.confirmation.message.contains("acme/tools/canonical"))
        host.decline(plan)
    }
}

extension ReviewedToolTaskTests {
    func testEmptyAutoremovePreparationReportsNoWorkAndNeverCreatesATask() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = HostReviewedToolTasks(activities: .init(), journal: root, runnerURL: URL(fileURLWithPath: "/missing"),
            executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, preflight: { _ in
                .object(["available": .bool(true), "succeeded": .bool(true), "complete": .bool(true), "no_op": .bool(true), "packages": .array([])])
            }, trustedTaps: { [] })
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("autoremove")]))
        XCTAssertThrowsError(try host.prepare(input, owner: .init("empty-autoremove"), pluginName: "Homebrew")) {
            XCTAssertEqual($0 as? PluginHostServiceError, .toolReadFailed("No unused Homebrew dependencies to remove. No Task was started."))
        }
        XCTAssertFalse(host.hasRunningTasks)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testAutoremoveRequiresGlobalFormulaScopeAndFreshConcreteHostConfirmation() throws {
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("autoremove")]))
        XCTAssertEqual(input.arguments, ["autoremove"])
        XCTAssertEqual(input.kind, "formula")
        for extra: [String: JSONValue] in [["name": .string("wget")], ["kind": .string("cask")], ["force": .bool(true)]] {
            var fields = input.fields; fields.merge(extra, uniquingKeysWith: { _, b in b })
            XCTAssertThrowsError(try HomebrewTaskInput(.object(fields)))
        }
        XCTAssertThrowsError(try input.authorize(in: .init(capability: .runReviewedToolTasks, commandIDs: [.init("manage")], reviewedTools: [.init(tool: "homebrew", operations: ["autoremove"], kinds: ["cask"])])))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var preview: JSONValue = .object(["available": .bool(true), "succeeded": .bool(true), "complete": .bool(true), "no_op": .bool(false),
            "packages": .array([.object(["name": .string("old-lib"), "kind": .string("formula")])])])
        let host = HostReviewedToolTasks(activities: HostActivities(), journal: root, runnerURL: URL(fileURLWithPath: "/missing"), executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, preflight: { _ in preview }, trustedTaps: { [] })
        let plan = try host.prepare(input, owner: .init("management"), pluginName: "Homebrew")
        XCTAssertTrue(plan.confirmation.message.contains("old-lib"))
        XCTAssertTrue(plan.confirmation.message.contains("installed only as dependencies"))
        XCTAssertTrue(try XCTUnwrap(plan.confirmation.details).rows.contains { $0.title.contains("old-lib") })
        XCTAssertEqual(plan.confirmation.details?.title, "Remove Unused Dependencies")
        XCTAssertTrue(plan.confirmation.details?.summary.contains("1 installed formula") == true)
        XCTAssertTrue(plan.confirmation.message.contains("Stopping does not undo"))
        preview = .object(["available": .bool(true), "succeeded": .bool(true), "complete": .bool(true), "no_op": .bool(true), "packages": .array([])])
        XCTAssertThrowsError(try host.launch(plan)) { XCTAssertEqual($0 as? PluginHostServiceError, .tool(.planChanged)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "A changed preview must never create a Task journal or launch a runner")
        XCTAssertThrowsError(try host.prepare(input, owner: .init("management"), pluginName: "Homebrew"), "A no-op cannot start a mutating Task")
    }
}
