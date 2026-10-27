import XCTest
@testable import SpinnetCore
@testable import SpinnetReviewedTools

final class HomebrewCommandOutputTests: XCTestCase {
    func testACommandThatExceededItsDeadlineCannotReturnACompletedOutput() throws {
        let profile = HomebrewReadProfile(executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, execute: { _, _, _, _ in
            Thread.sleep(forTimeInterval: 0.03)
            return HomebrewReadOutput(status: 0, stdout: Data("late output\n".utf8))
        })
        XCTAssertThrowsError(try profile.read(.object(["tool": .string("homebrew"), "operation": .string("commandOutput"), "command": .string("version")]), owner: .init("deadline"), timeout: 0.01)) {
            XCTAssertEqual($0 as? PluginHostServiceError, .tool(.timedOut))
        }
    }

    func testNativeVersionReadWithTheInstalledHomebrew() throws {
        guard ProcessInfo.processInfo.environment["SPINNET_HOMEBREW_NATIVE_PROBE"] == "1" else { throw XCTSkip("Opt-in read-only installed Homebrew probe") }
        let result = try HomebrewReadProfile().read(.object(["tool": .string("homebrew"), "operation": .string("commandOutput"), "command": .string("version")]), owner: .init("native-probe"), timeout: 15)
        XCTAssertEqual(result.value(atPointer: "/exit_status"), .number(0))
        guard case .string(let output)? = result.value(atPointer: "/output") else { return XCTFail("Native text is required") }
        XCTAssertTrue(output.hasPrefix("Homebrew "))
        print("NATIVE_COMMAND_OUTPUT_VERSION \(output)")
    }

    func testFullOwnerHistoryCannotDisplaceTheCurrentTranscriptOrOverflowTheSource() throws {
        let output = String(repeating: "\\\"\n", count: 22000)
        let values: [JSONValue] = (0..<8).map { index in .object([
            "id": .string("task\(index)"), "status": .string(index == 0 ? "running" : "ended"),
            "log": .array([.string("legacy")]), "output": .string(output), "output_truncated": .bool(false)]) }
        let projected = HomebrewCommandOutput.activities(values)
        XCTAssertLessThan(try JSONEncoder().encode(JSONValue.array(projected)).count, 512 * 1024)
        XCTAssertEqual(projected.first?.value(atPointer: "/output"), .string(String(decoding: Data(output.utf8).suffix(HomebrewCommandOutput.maximumOutputBytes), as: UTF8.self)))
        XCTAssertTrue(projected.dropFirst().contains { $0.value(atPointer: "/output_truncated") == .bool(true) })
        XCTAssertEqual(projected.count, 8)
    }

    func testOutputTextIsExplicitlyLiteralAndRequiresCurrentMembership() throws {
        let json: JSONValue = .object(["id": .string("command"), "title": .string("Command"), "content": .array([
            .object(["kind": .string("text"), "id": .string("stdout"), "text": .string("**raw** [not a link](https://example.com)"), "format": .string("output")])])])
        let contracts = PluginInterfaceContracts.host
        let manifest = try PluginManifest(id: .init("format"), name: "Format", version: "1", commands: [.init(id: .init("show"), title: "Show", execution: .javascript, script: "show.js")])
        let page = try PluginPage(parsing: json, permits: contracts.permitting(manifest))
        guard case .text(let text)? = page.component("stdout") else { return XCTFail("Output text is required") }
        XCTAssertTrue(text.isOutput); XCTAssertTrue(text.text.contains("**raw**"))
        XCTAssertThrowsError(try PluginPage(parsing: json, permits: { $0 != HomebrewCommandOutput.member }))
    }

    func testOnlyTypedReadonlyCommandsCanUseTheOutputRead() throws {
        XCTAssertEqual(try HomebrewCommandOutput.arguments(.object(["tool": .string("homebrew"), "operation": .string("commandOutput"), "command": .string("version")])), ["--version"])
        for fields: [String: JSONValue] in [
            ["command": .string("update")], ["command": .string("upgrade")],
            ["command": .string("tap"), "package": .string("owner/repository")],
            ["command": .string("services"), "action": .string("start"), "package": .string("redis")],
            ["command": .string("info"), "package": .string("x; echo injected")],
            ["command": .string("version"), "argv": .array([])]
        ] {
            XCTAssertThrowsError(try HomebrewCommandOutput.arguments(.object(fields.merging(["tool": .string("homebrew"), "operation": .string("commandOutput")]) { a, _ in a })))
        }
    }

    func testCommandTextRetainsLongOutputAndNonzeroExitInsteadOfParsingPackages() throws {
        let stdout = (0..<80).map { "line \($0) " + String(repeating: "x", count: 220) }.joined(separator: "\n") + "\n"
        let profile = HomebrewReadProfile(executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, execute: { _, args, _, _ in
            XCTAssertEqual(args, ["doctor"])
            return HomebrewReadOutput(status: 1, stdout: Data(stdout.utf8), stderr: Data("Warning: original diagnostic\n".utf8))
        })
        let result = try profile.read(.object(["tool": .string("homebrew"), "operation": .string("commandOutput"), "command": .string("doctor")]), owner: .init("probe"))
        guard case .string(let output)? = result.value(atPointer: "/output") else { return XCTFail("Native output is required") }
        XCTAssertTrue(output.contains("line 0 " + String(repeating: "x", count: 220)))
        XCTAssertTrue(output.contains("line 79")); XCTAssertTrue(output.contains("Warning: original diagnostic"))
        XCTAssertEqual(result.value(atPointer: "/exit_status"), .number(1))
        XCTAssertEqual(result.value(atPointer: "/output_truncated"), .bool(false))
    }

    func testTranscriptIsBoundedRedactedAndDoesNotChangeTheLegacyLog() {
        let log = HomebrewTaskLog()
        log.append(Data((0..<300).map { "\($0) " + String(repeating: "x", count: 240) + "\n" }.joined().utf8))
        log.append(Data("password=split".utf8)); log.append(Data("secret\nlast line\n".utf8)); log.finish()
        XCTAssertLessThanOrEqual(log.output.utf8.count, HomebrewCommandOutput.maximumOutputBytes)
        XCTAssertTrue(log.outputTruncated); XCTAssertFalse(log.output.contains("splitsecret"))
        XCTAssertTrue(log.output.contains("password=…")); XCTAssertTrue(log.output.hasSuffix("last line"))
        XCTAssertEqual(log.lines.count, 20); XCTAssertTrue(log.lines.allSatisfy { $0.count <= 200 })
    }

    func testCurrentOutputUsesRealBrokerGrantsForEveryAdmittedPlugin() throws {
        let command = CommandDeclaration(id: .init("run"), title: "Run", execution: .javascript, script: "run.js")
        let scope = PluginCapabilityScope(capability: .readReviewedTools, commandIDs: [command.id], reviewedTools: [.init(tool: "homebrew", operations: ["commandOutput"], kinds: ["formula", "cask"])])
        let current = try PluginManifest(id: .init("probe"), name: "Probe", version: "1", capabilities: [.readReviewedTools], capabilityScopes: [scope], commands: [command])
        try PluginInterfaceContracts.host.check(current, origin: .installed)
        let package = PluginPackage(rootURL: FileManager.default.temporaryDirectory, manifest: current)
        let action = try ActionConfiguration(id: .init("run"), pluginID: current.id, command: command, input: .null)
        let grants = PluginCapabilityGrantStore(); var launches = 0
        let profile = HomebrewReadProfile(executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, execute: { _, _, _, _ in
            launches += 1; return .init(status: 0, stdout: Data("Homebrew native output\n".utf8))
        })
        let broker = CapabilityCheckedHostServiceBroker(
            grantStore: grants,
            systemPermissionCheck: { _ in true },
            clipboard: .init(selectedTextProvider: { _ in "" }, clipboardWriter: { _ in }),
            tools: .init(reader: profile)
        )
        let request = PluginRuntimeHostServiceRequest(invocationID: "run", actionID: action.id, service: .reviewedToolRead, input: .object(["tool": .string("homebrew"), "operation": .string("commandOutput"), "command": .string("version")]), operation: "tools.read")
        XCTAssertThrowsError(try broker.execute(request: request, for: package, action: action)); XCTAssertEqual(launches, 0)
        grants.setDecision(.granted, for: current.id, pluginVersion: current.version, capability: .readReviewedTools, scope: scope)
        XCTAssertEqual(try broker.execute(request: request, for: package, action: action).value(atPointer: "/output"), .string("Homebrew native output"))
        grants.setDecision(.denied, for: current.id, pluginVersion: current.version, capability: .readReviewedTools, scope: scope)
        XCTAssertThrowsError(try broker.execute(request: request, for: package, action: action)); XCTAssertEqual(launches, 1)
        let activity: JSONValue = .object(["log": .array([.string("legacy")]), "output": .string("full output"), "output_truncated": .bool(false)])
        XCTAssertEqual(HomebrewCommandOutput.activities([activity]), [activity])
        XCTAssertTrue(PluginInterfaceContracts.currentMembers.contains(HomebrewCommandOutput.member))
    }
}
