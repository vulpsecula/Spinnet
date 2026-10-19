import XCTest
import SpinnetCore
import SpinnetPluginTestKit

final class ReviewedToolTaskTests: XCTestCase {
    func testOpaqueNativePreparationFailureNamesTheStageAndReleasesTheLane() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = HostReviewedToolTasks(activities: .init(), journal: root, runnerURL: URL(fileURLWithPath: "/missing"), executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, preflight: { _ in
            .object(["name": .string("example"), "kind": .string("cask"), "tap": .string("homebrew/cask"), "version": .string("2"), "outdated": .bool(true), "needs_privileges": .bool(true)])
        }, privilegeReview: { _, _, _ in throw PluginHostServiceError.tool(.failed) }, nativeInspection: nil)
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("upgrade"), "kind": .string("cask"), "name": .string("example")]))
        XCTAssertThrowsError(try host.prepare(input, owner: .init("native-failure"), pluginName: "Homebrew")) { error in
            guard case .toolReadFailed(let message) = error as? PluginHostServiceError else { return XCTFail("Missing preparation context: \(error)") }
            XCTAssertTrue(message.contains("inspecting native cask changes"))
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
    func testRequestedTaskOperationRoutesBothConfirmationsAndViewClosureCancelsBeforeAdmission() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let activities = HostActivities(), transport = RecordedNativeTaskInspection()
        transport.heldAfterCancel = true
        let owner = PluginID("com.example.native-receipts")
        let command = CommandDeclaration(id: .init("uninstall"), title: "Uninstall", execution: .javascript, script: "uninstall.js")
        let scope = PluginCapabilityScope(capability: .runReviewedToolTasks, commandIDs: [command.id], reviewedTools: [.init(tool: "homebrew", operations: ["uninstall"], kinds: ["cask"])])
        let manifest = try PluginManifest(apiLevel: 2, id: owner, name: "Homebrew", version: "1.0", capabilities: [.runReviewedToolTasks], capabilityScopes: [scope], commands: [command])
        let package = PluginPackage(rootURL: root, manifest: manifest, origin: .installed)
        let registry = PluginRegistry(); try registry.register(package)
        let action = try ActionConfiguration(id: .init("uninstall"), pluginID: owner, command: command, input: .null)
        let host = HostReviewedToolTasks(activities: activities, journal: root.appendingPathComponent("journal"), runnerURL: URL(fileURLWithPath: "/missing"),
            executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, preflight: { _ in RecordedNativeTaskInspection.metadata },
            trustedTaps: { [] }, privilegeReview: { _, _, _ in [RecordedNativeTaskInspection.cask] },
            nativeInspection: transport, inspectionDraft: { plan in try transport.draft(taskID: plan.activityID) }, prepareSystemAuthorization: {})
        let confirmation = WaitingNativeConfirmation()
        let performer = ReviewedTaskOperationPerformer(tasks: host, confirmations: confirmation, registry: registry, background: { $0() }, executor: { $0() }, schedule: { _, _ in })
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("uninstall"), "kind": .string("cask"), "name": .string("example")]))
        var outcomes: [HostOperationOutcome] = []
        performer.perform(input, for: action, accepted: performer.accept(owner: owner), authorize: {}, completion: { outcomes.append($0.outcome) })
        XCTAssertEqual(confirmation.shown.count, 1)
        XCTAssertEqual(transport.inspections, 0)
        confirmation.answers[0](.confirmed)
        XCTAssertEqual(confirmation.shown.count, 2)
        XCTAssertNotNil(confirmation.shown[1].details)
        XCTAssertEqual(transport.inspections, 1)
        XCTAssertTrue(outcomes.isEmpty)
        performer.abandon(owner, because: .viewClosed)
        confirmation.answers[1](.confirmed)
        XCTAssertEqual(outcomes, [.cancelled])
        XCTAssertEqual(transport.admissions, 0)
        XCTAssertTrue(host.hasRunningTasks, "A cancelled read-only worker still owns its lane until Root confirms reaping")
        XCTAssertTrue(activities.list(for: owner).isEmpty)
        XCTAssertEqual(activities.list().filter { $0.kind == "inspection" }.count, 1)
        XCTAssertThrowsError(try host.prepare(input, owner: .init("other"), pluginName: "Other")) { XCTAssertEqual($0 as? PluginHostServiceError, .tool(.busy)) }
        transport.heldAfterCancel = false; host.refresh()
        let reaped = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !host.hasRunningTasks }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [reaped], timeout: 2), .completed)
        XCTAssertTrue(activities.list().isEmpty)
    }

    func testReceiptInspectionRequiresTwoHostConfirmationsAndTheWholeConcreteReview() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = RecordedNativeTaskInspection()
        let host = HostReviewedToolTasks(activities: HostActivities(), journal: root, runnerURL: URL(fileURLWithPath: "/usr/bin/true"),
            executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, preflight: { _ in RecordedNativeTaskInspection.metadata },
            trustedTaps: { [] }, privilegeReview: { _, _, _ in [RecordedNativeTaskInspection.cask] },
            nativeInspection: transport, inspectionDraft: { plan in try transport.draft(taskID: plan.activityID) }, prepareSystemAuthorization: {})
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("uninstall"), "kind": .string("cask"), "name": .string("example")]))
        let first = try host.prepare(input, owner: .init("receipt-browser"), pluginName: "Homebrew")
        XCTAssertTrue(first.requiresNativeInspection)
        XCTAssertTrue(first.confirmation.message.contains("all installed receipts"))
        XCTAssertNil(first.confirmation.details)
        XCTAssertEqual(transport.inspections, 0, "Read-only system authorization follows the first Host confirmation")
        XCTAssertThrowsError(try host.launch(first), "A summary cannot be admitted as the concrete mutation")
        let reaped = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !host.hasRunningTasks }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [reaped], timeout: 2), .completed)
        let initial = try host.prepare(input, owner: .init("receipt-browser"), pluginName: "Homebrew")
        let final = try host.completeInspection(initial)
        XCTAssertFalse(final.requiresNativeInspection)
        XCTAssertEqual(transport.inspections, 1)
        let details = try XCTUnwrap(final.confirmation.details)
        XCTAssertTrue(details.rows.contains { $0.detail.contains("/Library/Example/file") })
        XCTAssertTrue(details.rows.contains { $0.detail.contains("/Library/Example/keep") && $0.title.contains("Retain") })
        XCTAssertTrue(details.rows.contains { $0.detail.contains("org.example.receipt") && $0.title.contains("Forget") })
        XCTAssertEqual(transport.admissions, 0, "The second Host confirmation has not answered")
        _ = try host.launch(final)
        XCTAssertEqual(transport.admissions, 1)
    }

    func testNativeInstallerConfirmationShowsChoicesAndVendorCodeAndManualPlansDoNotClaimRootWork() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let choices = [HomebrewPrivilegePlan.PackageInstaller.Choice(identifier: "component", customLocation: "/Applications")]
        let native = HomebrewPrivilegePlan.Cask(name: "example", version: "1", sha256: RecordedNativeTaskInspection.digest, packages: ["Example.pkg"],
            packageInstallers: [.init(path: "Example.pkg", choices: choices, allowUntrusted: true)],
            nativeScripts: [.init(phase: .install, executable: "install.sh", arguments: ["--quiet", "component"])])
        let manual = HomebrewPrivilegePlan.Cask(name: "example", version: "1", sha256: RecordedNativeTaskInspection.digest, packages: [], manualInstallers: ["Installer.app"])
        for binding in [native, manual] {
            let host = HostReviewedToolTasks(activities: HostActivities(), journal: root, runnerURL: URL(fileURLWithPath: "/missing"),
                executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, preflight: { _ in .object(["name": .string("example"), "kind": .string("cask"), "tap": .string("homebrew/cask"), "needs_privileges": .bool(true)]) },
                trustedTaps: { [] }, privilegeReview: { _, _, _ in [binding] })
            let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("install"), "kind": .string("cask"), "name": .string("example")]))
            let plan = try host.prepare(input, owner: .init("installer-review"), pluginName: "Homebrew")
            let details = try XCTUnwrap(plan.confirmation.details)
            if binding == native {
                XCTAssertTrue(details.rows.contains { $0.detail.contains("Example.pkg") && $0.detail.contains("component") && $0.detail.contains("/Applications") && $0.detail.contains("allowUntrusted") })
                XCTAssertTrue(details.rows.contains { $0.detail.contains("install.sh") && $0.detail.contains("--quiet") })
            } else {
                XCTAssertTrue(details.rows.contains { $0.detail.contains("Installer.app") && $0.detail.contains("not verified installation") })
                XCTAssertFalse(plan.needsSystemAuthorization)
                XCTAssertFalse(plan.confirmation.message.contains("macOS system authorization is required"))
            }
            host.decline(plan)
        }
    }

    func testRootRecoveryLaneBlocksNewOrdinaryTaskWithoutRestoringOldAuthority() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = RecordedNativeTaskInspection(); transport.laneBusy = true
        var metadataReads = 0
        let activities = HostActivities()
        let host = HostReviewedToolTasks(activities: activities, journal: root, runnerURL: URL(fileURLWithPath: "/missing"),
            executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, preflight: { _ in metadataReads += 1; return .object([:]) },
            nativeInspection: transport)
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("install"), "kind": .string("formula"), "name": .string("wget")]))
        XCTAssertThrowsError(try host.prepare(input, owner: .init("new-host"), pluginName: "Homebrew")) { XCTAssertEqual($0 as? PluginHostServiceError, .tool(.busy)) }
        XCTAssertEqual(metadataReads, 0)
        XCTAssertEqual(transport.admissions, 0)
        XCTAssertTrue(host.hasRunningTasks)
        XCTAssertTrue(activities.list(for: .init("new-host")).isEmpty, "Recovery liveness must never restore a Plugin's authority")
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

    func testSelectedNativeUpgradeReviewKeepsOrdinaryPackagesAlongsideNativeActions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let packages: [JSONValue] = (0..<3).map { .object(["kind": .string("cask"), "name": .string("package\($0)"),
            "tap": .string("homebrew/cask"), "installed_version": .string("1"), "version": .string("2"), "needs_privileges": .bool($0 == 2)]) }
        let native = HomebrewPrivilegePlan.Cask(name: "package2", version: "2", sha256: RecordedNativeTaskInspection.digest, packages: ["New.pkg"])
        let host = HostReviewedToolTasks(activities: HostActivities(), journal: root, runnerURL: URL(fileURLWithPath: "/missing"),
            executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, preflight: { _ in .object(["packages": .array(packages)]) },
            trustedTaps: { [] }, privilegeReview: { _, _, _ in [native] })
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("upgradeSelected"), "kind": .string("cask"),
            "names": .array((0..<3).map { .string("alias\($0)") })]))
        let plan = try host.prepare(input, owner: .init("selected-native"), pluginName: "Homebrew")
        let details = try XCTUnwrap(plan.confirmation.details)
        let rows = details.rows.filter { $0.id.hasPrefix("package-target/") }
        XCTAssertEqual(rows.count, 3)
        for index in 0..<3 { XCTAssertTrue(rows.contains { $0.id == "package-target/cask/package\(index)" && $0.detail.contains("1 → 2") }) }
        XCTAssertTrue(details.rows.contains { $0.detail.contains("New.pkg") })
        host.decline(plan)
    }

    func testAllUpgradeTargetsIncludingOrdinaryPackagesRemainVisibleInNativeFinalReview() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let packages: [JSONValue] = (0..<150).map { index in
            let kind = index < 100 ? "formula" : "cask", name = "package\(index)"
            return .object(["kind": .string(kind), "name": .string(name), "tap": .string(kind == "formula" ? "homebrew/core" : "homebrew/cask"),
                "installed_version": .string("1"), "version": .string("2"), "needs_privileges": .bool(index == 149)])
        }
        let native = HomebrewPrivilegePlan.Cask(name: "package149", version: "2", sha256: RecordedNativeTaskInspection.digest, packages: ["New.pkg"])
        let host = HostReviewedToolTasks(activities: HostActivities(), journal: root, runnerURL: URL(fileURLWithPath: "/missing"),
            executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, preflight: { _ in .object(["packages": .array(packages)]) },
            trustedTaps: { [] }, privilegeReview: { _, _, _ in [native] })
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("upgradeAll")]))
        let plan = try host.prepare(input, owner: .init("all-upgrades"), pluginName: "Homebrew")
        let details = try XCTUnwrap(plan.confirmation.details)
        let targetRows = details.rows.filter { $0.id.hasPrefix("package-target/") }
        XCTAssertEqual(targetRows.count, 150)
        for index in 0..<150 {
            XCTAssertTrue(targetRows.contains { $0.title == "Upgrade package\(index)" && $0.detail.contains("1 → 2") })
        }
        XCTAssertTrue(details.rows.contains { $0.detail.contains("New.pkg") })
        XCTAssertFalse(plan.confirmation.message.contains("(150 total)"), "A count cannot replace undisclosed executable package targets")
        host.decline(plan)
    }

    func testUninstallDoesNotBorrowTheCurrentCatalogInstallerAuthorization() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var nativeReviews = 0
        let host = HostReviewedToolTasks(activities: HostActivities(), journal: root, runnerURL: URL(fileURLWithPath: "/missing"),
            executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, preflight: { _ in
                .object(["name": .string("example"), "kind": .string("cask"), "tap": .string("homebrew/cask"), "installed_version": .string("1"), "needs_privileges": .bool(true)])
            }, trustedTaps: { [] }, privilegeReview: { _, _, _ in nativeReviews += 1; throw PluginHostServiceError.tool(.planChanged) })
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("uninstall"), "kind": .string("cask"), "name": .string("example")]))
        let plan = try host.prepare(input, owner: .init("ordinary-removal"), pluginName: "Homebrew")
        XCTAssertFalse(plan.needsPrivileges)
        XCTAssertEqual(nativeReviews, 0)
        XCTAssertFalse(plan.confirmation.message.contains("macOS system authorization"))
        host.decline(plan)
    }

    func testNativeZapAdmissionFlagAppliesOnlyToExplicitUninstallZap() throws {
        for zap in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            var nativeReviews = 0
            let host = HostReviewedToolTasks(activities: HostActivities(), journal: root, runnerURL: URL(fileURLWithPath: "/missing"), executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, preflight: { _ in
                .object(["name": .string("example"), "kind": .string("cask"), "tap": .string("homebrew/cask"), "installed_version": .string("1"), "zap_needs_privileges": .bool(true)])
            }, privilegeReview: { _, _, _ in
                nativeReviews += 1
                return [.init(name: "example", version: "1", sha256: "", packages: [], nativeScripts: [.init(phase: .zap, executable: "zap.sh", arguments: [])])]
            })
            let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("uninstall"), "kind": .string("cask"), "name": .string("example"), "zap": .bool(zap)]))
            let plan = try host.prepare(input, owner: PluginID("zap-review"), pluginName: "Homebrew")
            XCTAssertEqual(plan.needsPrivileges, zap)
            XCTAssertEqual(nativeReviews, zap ? 1 : 0)
            XCTAssertEqual(plan.confirmation.message.contains("macOS system authorization"), zap)
            host.decline(plan)
        }
    }
    func testPrefixLinkAndPinActionsDoNotBorrowCaskInstallerSystemAuthorization() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for operation in ["link", "unlink", "pin", "unpin"] {
            var reviews = 0
            let change: JSONValue = operation == "unlink" ? .object(["action": .string("unlink"), "path": .string("/opt/homebrew/bin/example")]) : .object(["action": .string("link"), "path": .string("/opt/homebrew/bin/example"), "source": .string("/opt/homebrew/Caskroom/example/1/example")])
            let host = HostReviewedToolTasks(activities: HostActivities(), journal: root, runnerURL: URL(fileURLWithPath: "/missing"), executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, preflight: { _ in
                .object(["kind": .string("cask"), "name": .string("example"), "tap": .string("homebrew/cask"), "installed_version": .string("1"),
                    "needs_privileges": .bool(true), "uninstall_needs_privileges": .bool(true), "quits_app": .bool(true), "link_preview": .object([
                        "succeeded": .bool(true), "complete": .bool(true), "truncated": .bool(false), "no_op": .bool(false), "paths": .array([.string("/opt/homebrew/bin/example")]),
                        "paths_fingerprint": .string(String(repeating: "a", count: 64)), "changes": .array([change])])])
            }, trustedTaps: { [] }, privilegeReview: { _, _, _ in reviews += 1; throw PluginHostServiceError.unavailable("Installer authorization must not apply to a prefix/metadata operation") })
            let plan = try host.prepare(HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string(operation), "kind": .string("cask"), "name": .string("example")])), owner: PluginID("cask-metadata"), pluginName: "Homebrew")
            XCTAssertFalse(plan.needsPrivileges)
            XCTAssertEqual(reviews, 0)
            XCTAssertFalse(plan.confirmation.message.contains("macOS system authorization"))
            XCTAssertFalse(plan.confirmation.message.contains("quit the affected App"))
            host.decline(plan)
        }
    }

    func testLinkConfirmationBindsConcreteFilesAndChangedTargetsRefuseLaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var fingerprint = String(repeating: "a", count: 64)
        let host = HostReviewedToolTasks(activities: HostActivities(), journal: root, runnerURL: URL(fileURLWithPath: "/missing"),
            executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, preflight: { _ in
                .object(["name": .string("wget"), "kind": .string("formula"), "tap": .string("homebrew/core"), "link_preview": .object([
                    "succeeded": .bool(true), "complete": .bool(true), "no_op": .bool(false), "truncated": .bool(false),
                    "paths": .array([.string("/opt/homebrew/bin/wget")]), "paths_fingerprint": .string(fingerprint),
                    "changes": .array([.object(["action": .string("link"), "path": .string("/opt/homebrew/bin/wget"), "source": .string("/opt/homebrew/Cellar/wget/1/bin/wget")])]),
                    "warnings": .array([.string("Parent directories may be created")])])])
            }, trustedTaps: { [] })
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("link"), "kind": .string("formula"), "name": .string("wget")]))
        let plan = try host.prepare(input, owner: PluginID("concrete-links"), pluginName: "Homebrew")
        XCTAssertTrue(plan.confirmation.message.contains("/opt/homebrew/bin/wget"))
        XCTAssertTrue(plan.confirmation.message.contains("/opt/homebrew/Cellar/wget/1/bin/wget"))
        XCTAssertTrue(plan.confirmation.message.contains("Parent directories may be created"))
        fingerprint = String(repeating: "b", count: 64)
        XCTAssertThrowsError(try host.launch(plan)) { XCTAssertEqual($0 as? PluginHostServiceError, .tool(.planChanged)) }
    }
    func testNoopIncompleteOrAmbiguousLinkPlansCannotReachConfirmation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("link"), "kind": .string("formula"), "name": .string("wget")]))
        let good: [String: JSONValue] = ["succeeded": .bool(true), "complete": .bool(true), "no_op": .bool(false), "truncated": .bool(false),
            "paths_fingerprint": .string(String(repeating: "a", count: 64)), "paths": .array([.string("/opt/homebrew/bin/wget")]),
            "changes": .array([.object(["action": .string("link"), "path": .string("/opt/homebrew/bin/wget"), "source": .string("/opt/homebrew/Cellar/wget/1/bin/wget")])])]
        let invalid: [[String: JSONValue]] = [ ["no_op": .bool(true)], ["complete": .bool(false)], ["truncated": .bool(true)],
            ["changes": .array([])], ["changes": .array([.object(["action": .string("link"), "path": .string("/opt/homebrew/bin/wget")])])],
            ["changes": .array([.object(["action": .string("shell"), "path": .string("/opt/homebrew/bin/wget")])])] ]
        for bad in invalid {
            let host = HostReviewedToolTasks(activities: HostActivities(), journal: root, runnerURL: URL(fileURLWithPath: "/missing"), executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, preflight: { _ in
                .object(["name": .string("wget"), "tap": .string("homebrew/core"), "link_preview": .object(good.merging(bad) { _, new in new })])
            }, trustedTaps: { [] })
            XCTAssertThrowsError(try host.prepare(input, owner: PluginID("bad-link"), pluginName: "Homebrew")) { XCTAssertEqual($0 as? PluginHostServiceError, .tool(.planChanged)) }
        }
    }
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
        }, trustedTaps: { [] }, privilegeReview: { _, _, _ in [.init(name: "firefox", version: "1", sha256: RecordedNativeTaskInspection.digest, packages: ["New.pkg"])] })
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("upgradeAll")]))
        let plan = try host.prepare(input, owner: PluginID("brew"), pluginName: "Homebrew")
        XCTAssertEqual(plan.steps.map(\.arguments), [["upgrade", "--formula", "--", "wget"], ["upgrade", "--cask", "--", "firefox"]])
        XCTAssertTrue(plan.confirmation.message.contains("wget"))
        XCTAssertTrue(plan.confirmation.message.contains("firefox"))
        XCTAssertFalse(plan.confirmation.message.contains(" git"))
        XCTAssertTrue(plan.confirmation.message.contains("macOS system authorization"))
        XCTAssertTrue(plan.confirmation.message.contains("may quit the affected App"))
    }
}

extension ReviewedToolTaskTests {
    func testNativeRemovalCannotBorrowCurrentOfficialSourceForUntrustedInstalledHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let receipt = HomebrewPrivilegePlan.Receipt(identifier: "org.example.pkg", manifestSHA256: String(repeating: "a", count: 64), fileCount: 1)
        let binding = HomebrewPrivilegePlan.Cask(name: "example", version: "1", sha256: "", packages: [], receipts: [receipt], installedTap: "other/tap")
        let host = HostReviewedToolTasks(activities: HostActivities(), journal: root, runnerURL: URL(fileURLWithPath: "/missing"), executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, preflight: { _ in .object(["name": .string("example"), "tap": .string("homebrew/cask"), "kind": .string("cask"), "uninstall_needs_privileges": .bool(true)]) }, trustedTaps: { [] }, privilegeReview: { _, _, _ in [binding] })
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("uninstall"), "kind": .string("cask"), "name": .string("example")]))
        XCTAssertThrowsError(try host.prepare(input, owner: .init("test"), pluginName: "Homebrew")) { XCTAssertEqual($0 as? PluginHostServiceError, .tool(.sourceNotAllowed)) }
    }
    func testPrivilegedUninstallConfirmationDisclosesExactReceiptAndFileCount() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let receipt = HomebrewPrivilegePlan.Receipt(identifier: "org.example.pkg", manifestSHA256: String(repeating: "a", count: 64), fileCount: 12)
        let host = HostReviewedToolTasks(activities: HostActivities(), journal: root, runnerURL: URL(fileURLWithPath: "/missing"), executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, preflight: { _ in .object(["name": .string("example"), "kind": .string("cask"), "uninstall_needs_privileges": .bool(true)]) }, trustedTaps: { [] }, privilegeReview: { _, _, _ in [.init(name: "example", version: "1", sha256: "", packages: [], receipts: [receipt])] }, nativeInspection: nil)
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("uninstall"), "kind": .string("cask"), "name": .string("example")]))
        let plan = try host.prepare(input, owner: .init("test"), pluginName: "Homebrew")
        XCTAssertTrue(plan.confirmation.message.contains("org.example.pkg"))
        XCTAssertTrue(plan.confirmation.message.contains("12"))
        XCTAssertTrue(plan.confirmation.message.contains("receipt-owned"))
    }
    func testNativeRemovalDetailsRefuseBeforeConfirmationWhenConcreteDisclosureExceedsItsBound() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let receipts = (0..<16).map { HomebrewPrivilegePlan.Receipt(identifier: "org.example." + String(repeating: "x", count: 170) + String($0), manifestSHA256: String(repeating: "a", count: 64), fileCount: 1) }
        let bindings = (0..<4).map { HomebrewPrivilegePlan.Cask(name: "example\($0)", version: "2", sha256: String(repeating: "b", count: 64), packages: ["New.pkg"], receipts: receipts, uninstallVersion: "1") }
        let host = HostReviewedToolTasks(activities: HostActivities(), journal: root, runnerURL: URL(fileURLWithPath: "/missing"), executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, preflight: { _ in .object(["packages": .array(bindings.map { .object(["name": .string($0.name), "kind": .string("cask"), "needs_privileges": .bool(true)]) })]) }, trustedTaps: { [] }, privilegeReview: { _, _, _ in bindings }, nativeInspection: nil)
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("upgradeAll"), "kind": .string("cask")]))
        XCTAssertThrowsError(try host.prepare(input, owner: .init("test"), pluginName: "Homebrew")) { XCTAssertEqual($0 as? PluginHostServiceError, .tool(.outputTooLarge)) }
    }
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
    func testPrivilegedTaskRequiresAuthenticatedHostAdmissionBeforeRunnerStarts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let binding = HomebrewPrivilegePlan.Cask(name: "example", version: "1", sha256: String(repeating: "a", count: 64), packages: ["Example.pkg"])
        var reviewed: HomebrewPrivilegePlan?
        let host = HostReviewedToolTasks(activities: HostActivities(), journal: root, runnerURL: URL(fileURLWithPath: "/missing"), executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, preflight: { _ in .object(["name": .string("example"), "needs_privileges": .bool(true)]) }, trustedTaps: { [] }, privilegeReview: { _, _, _ in [binding] }, prepareSystemAuthorization: {}, admitSystemAuthorization: { plan in reviewed = plan; throw PluginHostServiceError.unavailable("Host admission refused") }, cancelSystemAuthorization: { _ in })
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("install"), "kind": .string("cask"), "name": .string("example")]))
        let plan = try host.prepare(input, owner: PluginID("installer"), pluginName: "Homebrew")
        XCTAssertThrowsError(try host.launch(plan)) { XCTAssertEqual($0 as? PluginHostServiceError, .unavailable("Host admission refused")) }
        XCTAssertEqual(reviewed?.casks, [binding])
        XCTAssertEqual(reviewed?.operation, "install")
        XCTAssertFalse(host.hasRunningTasks)
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
    func testUninstallOnlyPrivilegesReachNativeReviewBeforeHostConfirmation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var reviews = 0
        let host = HostReviewedToolTasks(activities: HostActivities(), journal: root, runnerURL: URL(fileURLWithPath: "/missing"), executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, preflight: { _ in
            .object(["name": .string("example"), "kind": .string("cask"), "uninstall_needs_privileges": .bool(true)])
        }, trustedTaps: { [] }, privilegeReview: { _, _, _ in reviews += 1; throw PluginHostServiceError.unavailable("Unsupported native uninstall directive") })
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("uninstall"), "kind": .string("cask"), "name": .string("example")]))
        XCTAssertThrowsError(try host.prepare(input, owner: PluginID("uninstaller"), pluginName: "Homebrew"))
        XCTAssertEqual(reviews, 1)
        XCTAssertFalse(host.hasRunningTasks)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
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
        XCTAssertThrowsError(try host.launch(plan))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "A changed preview must never create a Task journal or launch a runner")
        XCTAssertThrowsError(try host.prepare(input, owner: .init("management"), pluginName: "Homebrew"), "A no-op cannot start a mutating Task")
    }
}
