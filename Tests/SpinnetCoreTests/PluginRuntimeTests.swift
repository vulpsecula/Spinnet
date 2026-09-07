import Foundation
import XCTest
@testable import SpinnetCore

final class PluginRuntimeTests: XCTestCase {
    func testInvocationSchemaDeclaresItsMessageVariant() throws {
        let invocation = PluginRuntimeInvocation(
            pluginID: PluginID("com.example.fixture"),
            actionID: ActionID("action-1"),
            commandID: CommandID("fixture.transform_text"),
            scriptPath: "transform-text.js",
            scriptSource: "input",
            input: .string("value")
        )
        let data = try JSONEncoder().encode(invocation)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(object["type"] as? String, "invocation")

        var unsupported = object
        unsupported["type"] = "host_service_request"
        let unsupportedData = try JSONSerialization.data(withJSONObject: unsupported)
        XCTAssertThrowsError(
            try JSONDecoder().decode(PluginRuntimeInvocation.self, from: unsupportedData)
        )
    }

    func testConnectionBindsPluginAndEnforcesRequestLifecycle() throws {
        let pluginID = PluginID("com.example.fixture")
        let connection = PluginRuntimeConnection(pluginID: pluginID)
        let invocation = PluginRuntimeInvocation(
            invocationID: "invocation-1",
            pluginID: pluginID,
            actionID: ActionID("action-1"),
            commandID: CommandID("fixture.transform_text"),
            scriptPath: "transform-text.js",
            scriptSource: "input",
            input: .string("value")
        )

        let requestData = try connection.prepareInvocation(invocation)
        XCTAssertEqual(try PluginRuntimeProtocol.decodeInvocation(requestData), invocation)

        let response = PluginRuntimeResponse(
            invocationID: invocation.invocationID,
            actionID: invocation.actionID,
            terminal: .succeeded(.string("result"))
        )
        XCTAssertEqual(
            try connection.acceptResponse(response),
            response.terminal
        )

        let duplicateAction = PluginRuntimeInvocation(
            invocationID: "invocation-2",
            pluginID: pluginID,
            actionID: invocation.actionID,
            commandID: invocation.commandID,
            scriptPath: invocation.scriptPath,
            scriptSource: invocation.scriptSource,
            input: invocation.input
        )
        let duplicateConnection = PluginRuntimeConnection(pluginID: pluginID)
        _ = try duplicateConnection.prepareInvocation(invocation)
        _ = try duplicateConnection.acceptResponse(response)
        XCTAssertThrowsError(try duplicateConnection.prepareInvocation(duplicateAction))

        let duplicateInvocation = PluginRuntimeInvocation(
            invocationID: invocation.invocationID,
            pluginID: pluginID,
            actionID: ActionID("action-2"),
            commandID: invocation.commandID,
            scriptPath: invocation.scriptPath,
            scriptSource: invocation.scriptSource,
            input: invocation.input
        )
        let duplicateRequestConnection = PluginRuntimeConnection(pluginID: pluginID)
        _ = try duplicateRequestConnection.prepareInvocation(invocation)
        _ = try duplicateRequestConnection.acceptResponse(response)
        XCTAssertThrowsError(
            try duplicateRequestConnection.prepareInvocation(duplicateInvocation)
        )

        let outOfOrderConnection = PluginRuntimeConnection(pluginID: pluginID)
        XCTAssertThrowsError(try outOfOrderConnection.acceptResponse(response))

        let impersonation = PluginRuntimeInvocation(
            invocationID: "invocation-3",
            pluginID: PluginID("com.example.other"),
            actionID: ActionID("action-3"),
            commandID: invocation.commandID,
            scriptPath: invocation.scriptPath,
            scriptSource: invocation.scriptSource,
            input: invocation.input
        )
        let freshConnection = PluginRuntimeConnection(pluginID: pluginID)
        XCTAssertThrowsError(try freshConnection.prepareInvocation(impersonation))
    }

    func testHostServiceMessagesRoundTripThroughTheBoundConnection() throws {
        let pluginID = PluginID("com.example.fixture")
        let actionID = ActionID("action-1")
        let connection = PluginRuntimeConnection(pluginID: pluginID)
        let invocation = PluginRuntimeInvocation(
            invocationID: "invocation-1",
            pluginID: pluginID,
            actionID: actionID,
            commandID: CommandID("fixture.transform_text"),
            scriptPath: "transform-text.js",
            scriptSource: "input",
            input: .string("value")
        )
        _ = try connection.prepareInvocation(invocation)

        let request = PluginRuntimeHostServiceRequest(
            invocationID: invocation.invocationID,
            actionID: actionID,
            requestID: "service-request-1",
            service: .readSelectedText,
            input: .null
        )
        let requestData = try PluginRuntimeProtocol.encodeHostServiceRequest(request)
        let decodedRequest = try PluginRuntimeProtocol.decodeHostServiceRequest(requestData)
        XCTAssertEqual(try connection.acceptHostServiceRequest(decodedRequest), request)

        let serviceResponse = PluginRuntimeHostServiceResponse(
            invocationID: invocation.invocationID,
            actionID: actionID,
            requestID: request.requestID,
            outcome: .succeeded(.string("selected text"))
        )
        let responseData = try connection.prepareHostServiceResponse(serviceResponse)
        XCTAssertEqual(
            try PluginRuntimeProtocol.decodeHostServiceResponse(responseData),
            serviceResponse
        )

        let terminal = PluginRuntimeResponse(
            invocationID: invocation.invocationID,
            actionID: actionID,
            terminal: .succeeded(.string("done"))
        )
        XCTAssertEqual(try connection.acceptResponse(terminal), terminal.terminal)
    }

    func testInvocationMessageLimitAcceptsAtMostOneMiB() throws {
        let base = try PluginRuntimeProtocol.encodeInvocation(
            makeInvocation(scriptSource: "")
        ).count
        let below = makeInvocation(
            scriptSource: String(repeating: "x", count: PluginRuntimeProtocol.maximumMessageBytes - base - 1)
        )
        let at = makeInvocation(
            scriptSource: String(repeating: "x", count: PluginRuntimeProtocol.maximumMessageBytes - base)
        )
        let above = makeInvocation(
            scriptSource: String(repeating: "x", count: PluginRuntimeProtocol.maximumMessageBytes - base + 1)
        )

        XCTAssertEqual(
            try PluginRuntimeProtocol.encodeInvocation(below).count,
            PluginRuntimeProtocol.maximumMessageBytes - 1
        )
        XCTAssertEqual(
            try PluginRuntimeProtocol.encodeInvocation(at).count,
            PluginRuntimeProtocol.maximumMessageBytes
        )
        XCTAssertEqual(
            try PluginRuntimeProtocol.decodeInvocation(
                PluginRuntimeProtocol.encodeInvocation(at)
            ),
            at
        )
        XCTAssertThrowsError(try PluginRuntimeProtocol.encodeInvocation(above))
    }

    func testResponseMessageLimitAcceptsAtMostOneMiB() throws {
        let makeResponse: (String) -> PluginRuntimeResponse = { value in
            PluginRuntimeResponse(
                invocationID: "invocation-1",
                actionID: ActionID("action-1"),
                terminal: .succeeded(.string(value))
            )
        }
        let base = try PluginRuntimeProtocol.encodeResponse(makeResponse("")).count
        let below = makeResponse(
            String(repeating: "x", count: PluginRuntimeProtocol.maximumMessageBytes - base - 1)
        )
        let at = makeResponse(
            String(repeating: "x", count: PluginRuntimeProtocol.maximumMessageBytes - base)
        )
        let above = makeResponse(
            String(repeating: "x", count: PluginRuntimeProtocol.maximumMessageBytes - base + 1)
        )

        XCTAssertEqual(
            try PluginRuntimeProtocol.encodeResponse(below).count,
            PluginRuntimeProtocol.maximumMessageBytes - 1
        )
        XCTAssertEqual(
            try PluginRuntimeProtocol.encodeResponse(at).count,
            PluginRuntimeProtocol.maximumMessageBytes
        )
        XCTAssertEqual(
            try PluginRuntimeProtocol.decodeResponse(
                PluginRuntimeProtocol.encodeResponse(at)
            ),
            at
        )
        XCTAssertThrowsError(try PluginRuntimeProtocol.encodeResponse(above))
    }

    func testPublicFrameReaderEnforcesOneMiBBodyLimitAtPipeBoundary() throws {
        let below = Data(repeating: 0x78, count: PluginRuntimeProtocol.maximumMessageBytes - 1)
        let at = Data(repeating: 0x78, count: PluginRuntimeProtocol.maximumMessageBytes)
        let above = Data(repeating: 0x78, count: PluginRuntimeProtocol.maximumMessageBytes + 1)

        XCTAssertEqual(try readFramedBody(below)?.count, below.count)
        XCTAssertEqual(try readFramedBody(at)?.count, at.count)
        XCTAssertThrowsError(try readFramedBody(above))
    }

    func testResponseSchemaRejectsUnsupportedVersionsAndVariants() throws {
        let response = PluginRuntimeResponse(
            invocationID: "invocation-1",
            actionID: ActionID("action-1"),
            terminal: .succeeded(.null)
        )
        let encoded = try PluginRuntimeProtocol.encodeResponse(response)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        object["protocol_version"] = "2.0"
        let unsupportedVersion = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(
            try PluginRuntimeProtocol.decodeResponse(unsupportedVersion)
        )

        object["protocol_version"] = PluginRuntimeProtocol.version
        object["type"] = "progress"
        let unsupportedType = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(
            try PluginRuntimeProtocol.decodeResponse(unsupportedType)
        )

        var invocation = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: PluginRuntimeProtocol.encodeInvocation(makeInvocation(scriptSource: "input"))
            ) as? [String: Any]
        )
        invocation["protocol_version"] = "2.0"
        let unsupportedInvocationVersion = try JSONSerialization.data(withJSONObject: invocation)
        XCTAssertThrowsError(
            try PluginRuntimeProtocol.decodeInvocation(unsupportedInvocationVersion)
        )
    }

    func testSchemasRejectMalformedValuesAndUnknownTerminalKinds() throws {
        var invocation = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: PluginRuntimeProtocol.encodeInvocation(makeInvocation(scriptSource: "input"))
            ) as? [String: Any]
        )
        invocation["action_id"] = "   "
        let emptyActionID = try JSONSerialization.data(withJSONObject: invocation)
        XCTAssertThrowsError(try PluginRuntimeProtocol.decodeInvocation(emptyActionID))

        let response = PluginRuntimeResponse(
            invocationID: "invocation-1",
            actionID: ActionID("action-1"),
            terminal: .succeeded(.null)
        )
        var terminal = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: PluginRuntimeProtocol.encodeResponse(response)
            ) as? [String: Any]
        )
        terminal["terminal"] = ["kind": "progress", "result": NSNull()]
        let unknownTerminal = try JSONSerialization.data(withJSONObject: terminal)
        XCTAssertThrowsError(try PluginRuntimeProtocol.decodeResponse(unknownTerminal))

        terminal["terminal"] = [
            "kind": "succeeded",
            "result": NSNull(),
            "failure": ["category": "helper_error", "message": "unexpected"]
        ]
        let ambiguousTerminal = try JSONSerialization.data(withJSONObject: terminal)
        XCTAssertThrowsError(try PluginRuntimeProtocol.decodeResponse(ambiguousTerminal))

        let connection = PluginRuntimeConnection(pluginID: PluginID("com.example.fixture"))
        XCTAssertThrowsError(try connection.acceptResponse(response))
        XCTAssertEqual(connection.state, .closed)
    }

    func testHelperIdentityAndCapabilityClaimsAreNotPartOfResponseAuthority() throws {
        let pluginID = PluginID("com.example.fixture")
        let invocation = makeInvocation(scriptSource: "input")
        let connection = PluginRuntimeConnection(pluginID: pluginID)
        _ = try connection.prepareInvocation(invocation)

        let response = PluginRuntimeResponse(
            invocationID: invocation.invocationID,
            actionID: invocation.actionID,
            terminal: .succeeded(.string("result"))
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: PluginRuntimeProtocol.encodeResponse(response)
            ) as? [String: Any]
        )
        object["plugin_id"] = "com.example.impersonator"
        object["capabilities"] = ["clipboard.read", "network"]
        let claimed = try JSONSerialization.data(withJSONObject: object)

        let decoded = try PluginRuntimeProtocol.decodeResponse(claimed)
        XCTAssertEqual(try connection.acceptResponse(decoded), .succeeded(.string("result")))
    }

    func testMalformedHelperTerminatesOnlyItsActionAndSecondPluginStillRuns() throws {
        let helperURL = try XCTUnwrap(
            helperURLIfBuilt(),
            "Build SpinnetPluginHelper before running integration tests"
        )
        let hostileHelperURL = try makeShellHelper(
            """
            #!/bin/sh
            IFS= read -r request
            printf '%s\\n' '{"type":"progress","protocol_version":"1.0","invocation_id":"wrong","action_id":"wrong","terminal":{"kind":"succeeded","result":null}}'
            """
        )
        defer { try? FileManager.default.removeItem(at: hostileHelperURL) }

        let first = try makeScriptedPackage(
            pluginID: PluginID("com.example.first"),
            script: "input"
        )
        let second = try makeScriptedPackage(
            pluginID: PluginID("com.example.second"),
            script: "input"
        )
        defer {
            try? FileManager.default.removeItem(at: first.rootURL)
            try? FileManager.default.removeItem(at: second.rootURL)
        }

        let firstAction = try ActionConfiguration(
            id: ActionID("first-action"),
            pluginID: first.manifest.id,
            command: first.manifest.commands[0],
            input: .string("first")
        )
        let secondAction = try ActionConfiguration(
            id: ActionID("second-action"),
            pluginID: second.manifest.id,
            command: second.manifest.commands[0],
            input: .string("second")
        )
        let registry = PluginRegistry()
        try registry.register(first)
        try registry.register(second)

        let failed = HostActionRunner(
            executor: NoopHostCommandExecutor(),
            scriptedExecutor: PluginRuntimeSupervisor(helperURL: hostileHelperURL)
        ).invoke(firstAction, using: registry)
        guard case .failed(let failure) = failed.terminal else {
            return XCTFail("A hostile terminal message should fail its Action")
        }
        XCTAssertEqual(failure.category, .runtimeProtocolFailed)
        XCTAssertEqual(failure.pluginID, firstAction.pluginID)
        XCTAssertEqual(failure.actionID, firstAction.id)

        let secondOutcome = HostActionRunner(
            executor: NoopHostCommandExecutor(),
            scriptedExecutor: PluginRuntimeSupervisor(helperURL: helperURL)
        ).invoke(secondAction, using: registry)
        XCTAssertEqual(secondOutcome.terminal, .succeeded(.string("second")))
    }

    func testOversizedHelperResponseFailsClosedWithoutAffectingAnotherPlugin() throws {
        let helperURL = try XCTUnwrap(
            helperURLIfBuilt(),
            "Build SpinnetPluginHelper before running integration tests"
        )
        let oversizedHelperURL = try makeShellHelper(
            """
            #!/bin/sh
            IFS= read -r request
            printf '%s' '{"type":"terminal","protocol_version":"1.0","invocation_id":"wrong","action_id":"wrong","terminal":{"kind":"succeeded","result":"'
            awk 'BEGIN { for (i = 0; i < 1048500; i++) printf "x" }'
            printf '%s\\n' '"}}'
            """
        )
        defer { try? FileManager.default.removeItem(at: oversizedHelperURL) }

        let first = try makeScriptedPackage(
            pluginID: PluginID("com.example.oversized"),
            script: "input"
        )
        let second = try makeScriptedPackage(
            pluginID: PluginID("com.example.after-oversized"),
            script: "input"
        )
        defer {
            try? FileManager.default.removeItem(at: first.rootURL)
            try? FileManager.default.removeItem(at: second.rootURL)
        }
        let firstAction = try ActionConfiguration(
            id: ActionID("oversized-action"),
            pluginID: first.manifest.id,
            command: first.manifest.commands[0],
            input: .string("first")
        )
        let secondAction = try ActionConfiguration(
            id: ActionID("after-oversized-action"),
            pluginID: second.manifest.id,
            command: second.manifest.commands[0],
            input: .string("second")
        )
        let registry = PluginRegistry()
        try registry.register(first)
        try registry.register(second)

        let failed = HostActionRunner(
            executor: NoopHostCommandExecutor(),
            scriptedExecutor: PluginRuntimeSupervisor(helperURL: oversizedHelperURL)
        ).invoke(firstAction, using: registry)
        guard case .failed(let failure) = failed.terminal else {
            return XCTFail("An oversized terminal message should fail its Action")
        }
        XCTAssertEqual(failure.category, .runtimeProtocolFailed)

        let secondOutcome = HostActionRunner(
            executor: NoopHostCommandExecutor(),
            scriptedExecutor: PluginRuntimeSupervisor(helperURL: helperURL)
        ).invoke(secondAction, using: registry)
        XCTAssertEqual(secondOutcome.terminal, .succeeded(.string("second")))
    }

    func testDuplicateTerminalMessagesFailClosed() throws {
        let duplicateHelperURL = try makeShellHelper(
            """
            #!/bin/sh
            IFS= read -r request
            invocation_id=$(printf '%s' "$request" | sed -n 's/.*"invocation_id":"\\([^"]*\\)".*/\\1/p')
            action_id=$(printf '%s' "$request" | sed -n 's/.*"action_id":"\\([^"]*\\)".*/\\1/p')
            response=$(printf '{"type":"terminal","protocol_version":"1.0","invocation_id":"%s","action_id":"%s","terminal":{"kind":"succeeded","result":null}}' "$invocation_id" "$action_id")
            printf '%s\\n' "$response"
            sleep 1
            printf '%s\\n' "$response"
            """
        )
        defer { try? FileManager.default.removeItem(at: duplicateHelperURL) }

        let package = try makeScriptedPackage(
            pluginID: PluginID("com.example.duplicate"),
            script: "input"
        )
        defer { try? FileManager.default.removeItem(at: package.rootURL) }
        let action = try ActionConfiguration(
            id: ActionID("duplicate-action"),
            pluginID: package.manifest.id,
            command: package.manifest.commands[0],
            input: .string("value")
        )
        let registry = PluginRegistry()
        try registry.register(package)

        let outcome = HostActionRunner(
            executor: NoopHostCommandExecutor(),
            scriptedExecutor: PluginRuntimeSupervisor(helperURL: duplicateHelperURL)
        ).invoke(action, using: registry)
        guard case .failed(let failure) = outcome.terminal else {
            return XCTFail("A duplicate terminal message should fail the Action")
        }
        XCTAssertEqual(failure.category, .runtimeProtocolFailed)
    }

    func testCancellationTerminatesOnlyTheAffectedHelperWithin250Milliseconds() throws {
        let helper = try XCTUnwrap(helperURLIfBuilt())
        let package = try makeScriptedPackage(pluginID: PluginID("test.cancel"), script: "while (true) {}")
        defer { try? FileManager.default.removeItem(at: package.rootURL) }
        let action = try ActionConfiguration(id: ActionID("cancel"), pluginID: package.manifest.id,
            command: package.manifest.commands[0], input: .null)
        let process = Process()
        let control = ActionExecutionControl()
        let completed = expectation(description: "cancelled execution finished")
        DispatchQueue.global().async {
            defer { completed.fulfill() }
            do {
                _ = try PluginRuntimeSupervisor(helperURL: helper, processFactory: { process })
                    .execute(action, in: package, using: nil, control: control)
                XCTFail("The cancelled script must not succeed")
            } catch {
                XCTAssertEqual(error as? PluginRuntimeError, .cancelled)
            }
        }
        let launchDeadline = ProcessInfo.processInfo.systemUptime + 2
        while !process.isRunning && ProcessInfo.processInfo.systemUptime < launchDeadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertTrue(process.isRunning)
        let cancelledAt = ProcessInfo.processInfo.systemUptime
        control.stop(.cancelled)
        wait(for: [completed], timeout: 0.25)
        XCTAssertFalse(process.isRunning)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - cancelledAt, 0.25)

        let healthy = try makeScriptedPackage(pluginID: PluginID("test.healthy"), script: "42")
        defer { try? FileManager.default.removeItem(at: healthy.rootURL) }
        let healthyAction = try ActionConfiguration(id: ActionID("healthy"), pluginID: healthy.manifest.id,
            command: healthy.manifest.commands[0], input: .null)
        XCTAssertEqual(try PluginRuntimeSupervisor(helperURL: helper).execute(healthyAction, in: healthy), .number(42))
    }

    func testCancellationDuringHostServiceWorkKillsHelperAndRejectsLateServiceResult() throws {
        let helper = try XCTUnwrap(helperURLIfBuilt())
        let package = try loadFixturePackage()
        let command = try XCTUnwrap(package.manifest.commands.first { $0.execution == .javascript })
        let action = try ActionConfiguration(id: ActionID("blocked-service"), pluginID: package.manifest.id,
                                            command: command, input: .null)
        let grants = PluginCapabilityGrantStore()
        for capability in [PluginCapability.readSelectedText, .writeClipboard] {
            grants.setDecision(.granted, for: package.manifest.id,
                               pluginVersion: package.manifest.version, capability: capability)
        }
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let broker = CapabilityCheckedHostServiceBroker(grantStore: grants,
            systemPermissionCheck: { _ in true }, selectedTextProvider: {
                entered.signal()
                _ = release.wait(timeout: .now() + 5)
                return "late result"
            }, clipboardWriter: { _ in XCTFail("Cancelled execution must not request another service") })
        let process = Process()
        let control = ActionExecutionControl()
        let completed = expectation(description: "late service discarded")
        DispatchQueue.global().async {
            defer { completed.fulfill() }
            do {
                _ = try PluginRuntimeSupervisor(helperURL: helper, processFactory: { process })
                    .execute(action, in: package, using: broker, control: control)
                XCTFail("Cancelled execution cannot succeed")
            } catch { XCTAssertEqual(error as? PluginRuntimeError, .cancelled) }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        control.stop(.cancelled)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertFalse(process.isRunning)
        release.signal()
        wait(for: [completed], timeout: 1)
    }

    func testExternalHelperTerminationHasAStableCategory() throws {
        let helper = try makeShellHelper("#!/bin/sh\nkill -TERM $$\n")
        defer { try? FileManager.default.removeItem(at: helper) }
        let package = try makeScriptedPackage(pluginID: PluginID("test.terminated"), script: "input")
        defer { try? FileManager.default.removeItem(at: package.rootURL) }
        let action = try ActionConfiguration(id: ActionID("terminated"), pluginID: package.manifest.id,
                                            command: package.manifest.commands[0], input: .null)
        XCTAssertThrowsError(try PluginRuntimeSupervisor(helperURL: helper).execute(action, in: package)) {
            XCTAssertEqual($0 as? PluginRuntimeError, .helperTerminated)
        }
    }

    func testSilentHelperReachesAStableTimeoutAtTheActionDeadline() throws {
        let silentHelperURL = try makeShellHelper(
            """
            #!/bin/sh
            IFS= read -r request
            sleep 10
            """
        )
        defer { try? FileManager.default.removeItem(at: silentHelperURL) }

        let package = try loadFixturePackage()
        let command = try XCTUnwrap(package.manifest.commands.first {
            $0.id == CommandID("fixture.transform_text")
        })
        let action = try ActionConfiguration(
            id: ActionID("fixture-transform-silent"),
            pluginID: package.manifest.id,
            command: command,
            input: .string("Spinnet Plugin fixture")
        )
        let registry = PluginRegistry()
        try registry.register(package)

        let invokedAt = ProcessInfo.processInfo.systemUptime
        let outcome = HostActionRunner(
            executor: NoopHostCommandExecutor(),
            scriptedExecutor: PluginRuntimeSupervisor(helperURL: silentHelperURL, processFactory: {
                Thread.sleep(forTimeInterval: 0.4)
                return Process()
            })
        ).invoke(action, using: registry)
        guard case .failed(let failure) = outcome.terminal else {
            return XCTFail("A silent helper should produce a terminal timeout")
        }
        XCTAssertEqual(failure.category, .timedOut)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - invokedAt, 4.25)
    }

    func testFixtureTextCommandRunsInTheJavaScriptCoreHelper() throws {
        let helperURL = try XCTUnwrap(helperURLIfBuilt(), "Build SpinnetPluginHelper before running integration tests")
        let package = try loadFixturePackage()
        let command = try XCTUnwrap(package.manifest.commands.first {
            $0.id == CommandID("fixture.transform_text")
        })
        let action = try ActionConfiguration(
            id: ActionID("fixture-transform-text"),
            pluginID: package.manifest.id,
            command: command,
            input: .string("Spinnet Plugin fixture")
        )

        let grantStore = PluginCapabilityGrantStore()
        grantStore.setDecision(
            .granted,
            for: package.manifest.id,
            pluginVersion: package.manifest.version,
            capability: .readSelectedText
        )
        grantStore.setDecision(
            .granted,
            for: package.manifest.id,
            pluginVersion: package.manifest.version,
            capability: .writeClipboard
        )
        var clipboardValue: String?
        let hostServiceBroker = CapabilityCheckedHostServiceBroker(
            grantStore: grantStore,
            systemPermissionCheck: { _ in true },
            selectedTextProvider: { "Spinnet Plugin fixture" },
            clipboardWriter: { clipboardValue = $0 }
        )
        let supervisor = PluginRuntimeSupervisor(helperURL: helperURL)
        let result = try supervisor.execute(
            action,
            in: package,
            using: hostServiceBroker
        )

        XCTAssertEqual(
            result,
            .object([
                "checksum": .string("1559691768"),
                "output_bytes": .number(22)
            ])
        )
        XCTAssertEqual(clipboardValue, "SPINNET-plugin-FIXTURE")
        XCTAssertEqual(supervisor.launchCount, 1)
    }

    func testHostActionRunnerReturnsTheFixtureTextResult() throws {
        let helperURL = try XCTUnwrap(helperURLIfBuilt(), "Build SpinnetPluginHelper before running integration tests")
        let package = try loadFixturePackage()
        let command = try XCTUnwrap(package.manifest.commands.first {
            $0.id == CommandID("fixture.transform_text")
        })
        let action = try ActionConfiguration(
            id: ActionID("fixture-transform-text-seam"),
            pluginID: package.manifest.id,
            command: command,
            input: .string("Spinnet Plugin fixture")
        )
        let registry = PluginRegistry()
        try registry.register(package)
        let grantStore = PluginCapabilityGrantStore()
        grantStore.setDecision(
            .granted,
            for: package.manifest.id,
            pluginVersion: package.manifest.version,
            capability: .readSelectedText
        )
        grantStore.setDecision(
            .granted,
            for: package.manifest.id,
            pluginVersion: package.manifest.version,
            capability: .writeClipboard
        )
        var clipboardValue: String?
        let hostServiceBroker = CapabilityCheckedHostServiceBroker(
            grantStore: grantStore,
            systemPermissionCheck: { _ in true },
            selectedTextProvider: { "Spinnet Plugin fixture" },
            clipboardWriter: { clipboardValue = $0 }
        )
        let runner = HostActionRunner(
            executor: NoopHostCommandExecutor(),
            scriptedExecutor: PluginRuntimeSupervisor(helperURL: helperURL),
            hostServiceBroker: hostServiceBroker
        )

        let outcome = runner.invoke(action, using: registry)

        XCTAssertEqual(outcome.actionID, action.id)
        XCTAssertEqual(outcome.pluginID, action.pluginID)
        XCTAssertEqual(
            outcome.terminal,
            .succeeded(.object([
                "checksum": .string("1559691768"),
                "output_bytes": .number(22)
            ]))
        )
        XCTAssertEqual(clipboardValue, "SPINNET-plugin-FIXTURE")
    }

    func testHostActionRunnerReturnsCapabilityDeniedWhenReadGrantIsWithheld() throws {
        let helperURL = try XCTUnwrap(helperURLIfBuilt(), "Build SpinnetPluginHelper before running integration tests")
        let package = try loadFixturePackage()
        XCTAssertEqual(
            package.manifest.capabilities,
            [.readSelectedText, .writeClipboard]
        )
        let command = try XCTUnwrap(package.manifest.commands.first {
            $0.id == CommandID("fixture.transform_text")
        })
        let action = try ActionConfiguration(
            id: ActionID("fixture-transform-text-denied"),
            pluginID: package.manifest.id,
            command: command,
            input: .string("Spinnet Plugin fixture")
        )
        let registry = PluginRegistry()
        try registry.register(package)

        let grantStore = PluginCapabilityGrantStore()
        grantStore.setDecision(
            .denied,
            for: package.manifest.id,
            pluginVersion: package.manifest.version,
            capability: .readSelectedText
        )
        grantStore.setDecision(
            .granted,
            for: package.manifest.id,
            pluginVersion: package.manifest.version,
            capability: .writeClipboard
        )
        var selectedTextProviderCalled = false
        var clipboardWriterCalled = false
        let hostServiceBroker = CapabilityCheckedHostServiceBroker(
            grantStore: grantStore,
            systemPermissionCheck: { _ in true },
            selectedTextProvider: {
                selectedTextProviderCalled = true
                return "Spinnet Plugin fixture"
            },
            clipboardWriter: { _ in clipboardWriterCalled = true }
        )

        let outcome = HostActionRunner(
            executor: NoopHostCommandExecutor(),
            scriptedExecutor: PluginRuntimeSupervisor(helperURL: helperURL),
            hostServiceBroker: hostServiceBroker
        ).invoke(action, using: registry)

        guard case .failed(let failure) = outcome.terminal else {
            return XCTFail("A withheld read Capability should fail the Action")
        }
        XCTAssertEqual(failure.category, .capabilityDenied)
        XCTAssertFalse(selectedTextProviderCalled)
        XCTAssertFalse(clipboardWriterCalled)
    }

    func testHostActionRunnerReturnsCapabilityDeniedWhenWriteGrantIsWithheld() throws {
        let helperURL = try XCTUnwrap(helperURLIfBuilt(), "Build SpinnetPluginHelper before running integration tests")
        let package = try loadFixturePackage()
        let command = try XCTUnwrap(package.manifest.commands.first {
            $0.id == CommandID("fixture.transform_text")
        })
        let action = try ActionConfiguration(
            id: ActionID("fixture-transform-text-write-denied"),
            pluginID: package.manifest.id,
            command: command,
            input: .string("Spinnet Plugin fixture")
        )
        let registry = PluginRegistry()
        try registry.register(package)

        let grantStore = PluginCapabilityGrantStore()
        grantStore.setDecision(
            .granted,
            for: package.manifest.id,
            pluginVersion: package.manifest.version,
            capability: .readSelectedText
        )
        grantStore.setDecision(
            .denied,
            for: package.manifest.id,
            pluginVersion: package.manifest.version,
            capability: .writeClipboard
        )
        var selectedTextProviderCalled = false
        var clipboardWriterCalled = false
        let hostServiceBroker = CapabilityCheckedHostServiceBroker(
            grantStore: grantStore,
            systemPermissionCheck: { _ in true },
            selectedTextProvider: {
                selectedTextProviderCalled = true
                return "Spinnet Plugin fixture"
            },
            clipboardWriter: { _ in clipboardWriterCalled = true }
        )

        let outcome = HostActionRunner(
            executor: NoopHostCommandExecutor(),
            scriptedExecutor: PluginRuntimeSupervisor(helperURL: helperURL),
            hostServiceBroker: hostServiceBroker
        ).invoke(action, using: registry)

        guard case .failed(let failure) = outcome.terminal else {
            return XCTFail("A withheld write Capability should fail the Action")
        }
        XCTAssertEqual(failure.category, .capabilityDenied)
        XCTAssertTrue(selectedTextProviderCalled)
        XCTAssertFalse(clipboardWriterCalled)
    }

    func testHostActionRunnerReturnsSystemPermissionDeniedAtTheHostServiceSeam() throws {
        let helperURL = try XCTUnwrap(helperURLIfBuilt(), "Build SpinnetPluginHelper before running integration tests")
        let package = try loadFixturePackage()
        let command = try XCTUnwrap(package.manifest.commands.first {
            $0.id == CommandID("fixture.transform_text")
        })
        let action = try ActionConfiguration(
            id: ActionID("fixture-transform-text-permission-denied"),
            pluginID: package.manifest.id,
            command: command,
            input: .string("Spinnet Plugin fixture")
        )
        let registry = PluginRegistry()
        try registry.register(package)

        let grantStore = PluginCapabilityGrantStore()
        grantStore.setDecision(
            .granted,
            for: package.manifest.id,
            pluginVersion: package.manifest.version,
            capability: .readSelectedText
        )
        grantStore.setDecision(
            .granted,
            for: package.manifest.id,
            pluginVersion: package.manifest.version,
            capability: .writeClipboard
        )
        var selectedTextProviderCalled = false
        let hostServiceBroker = CapabilityCheckedHostServiceBroker(
            grantStore: grantStore,
            systemPermissionCheck: { _ in false },
            selectedTextProvider: {
                selectedTextProviderCalled = true
                return "Spinnet Plugin fixture"
            },
            clipboardWriter: { _ in }
        )

        let outcome = HostActionRunner(
            executor: NoopHostCommandExecutor(),
            scriptedExecutor: PluginRuntimeSupervisor(helperURL: helperURL),
            hostServiceBroker: hostServiceBroker
        ).invoke(action, using: registry)

        guard case .failed(let failure) = outcome.terminal else {
            return XCTFail("A missing System Permission should fail the Action")
        }
        XCTAssertEqual(failure.category, .systemPermissionDenied)
        XCTAssertFalse(selectedTextProviderCalled)
    }

    func testHostActionRunnerRechecksGrantBeforeEachHostServiceRequest() throws {
        let helperURL = try XCTUnwrap(helperURLIfBuilt(), "Build SpinnetPluginHelper before running integration tests")
        let package = try loadFixturePackage()
        let command = try XCTUnwrap(package.manifest.commands.first {
            $0.id == CommandID("fixture.transform_text")
        })
        let action = try ActionConfiguration(
            id: ActionID("fixture-transform-text-revoked"),
            pluginID: package.manifest.id,
            command: command,
            input: .string("Spinnet Plugin fixture")
        )
        let registry = PluginRegistry()
        try registry.register(package)

        let grantStore = PluginCapabilityGrantStore()
        grantStore.setDecision(
            .granted,
            for: package.manifest.id,
            pluginVersion: package.manifest.version,
            capability: .readSelectedText
        )
        grantStore.setDecision(
            .granted,
            for: package.manifest.id,
            pluginVersion: package.manifest.version,
            capability: .writeClipboard
        )
        var clipboardWriterCalled = false
        let hostServiceBroker = CapabilityCheckedHostServiceBroker(
            grantStore: grantStore,
            systemPermissionCheck: { _ in true },
            selectedTextProvider: {
                grantStore.setDecision(
                    .denied,
                    for: package.manifest.id,
                    pluginVersion: package.manifest.version,
                    capability: .writeClipboard
                )
                return "Spinnet Plugin fixture"
            },
            clipboardWriter: { _ in clipboardWriterCalled = true }
        )

        let outcome = HostActionRunner(
            executor: NoopHostCommandExecutor(),
            scriptedExecutor: PluginRuntimeSupervisor(helperURL: helperURL),
            hostServiceBroker: hostServiceBroker
        ).invoke(action, using: registry)

        guard case .failed(let failure) = outcome.terminal else {
            return XCTFail("A Capability revoked between requests should fail the Action")
        }
        XCTAssertEqual(failure.category, .capabilityDenied)
        XCTAssertFalse(clipboardWriterCalled)
    }

    func testHostUsesConnectionBoundIdentityForHostServiceAuthorization() throws {
        let helperURL = try makeShellHelper(
            """
            #!/bin/sh
            IFS= read -r request
            invocation_id=$(printf '%s' "$request" | sed -n 's/.*"invocation_id":"\\([^" ]*\\)".*/\\1/p')
            action_id=$(printf '%s' "$request" | sed -n 's/.*"action_id":"\\([^" ]*\\)".*/\\1/p')
            printf '{"type":"host_service_request","protocol_version":"1.0","invocation_id":"%s","action_id":"%s","request_id":"claim-1","service":"read_selected_text","input":null,"plugin_id":"com.attacker","capabilities":["write_clipboard"]}\\n' "$invocation_id" "$action_id"
            IFS= read -r response
            printf '{"type":"terminal","protocol_version":"1.0","invocation_id":"%s","action_id":"%s","terminal":{"kind":"succeeded","result":"identity-bound"}}\\n' "$invocation_id" "$action_id"
            """
        )
        defer { try? FileManager.default.removeItem(at: helperURL) }

        let package = try loadFixturePackage()
        let command = try XCTUnwrap(package.manifest.commands.first {
            $0.id == CommandID("fixture.transform_text")
        })
        let action = try ActionConfiguration(
            id: ActionID("fixture-transform-text-identity"),
            pluginID: package.manifest.id,
            command: command,
            input: .string("ignored by helper")
        )
        let registry = PluginRegistry()
        try registry.register(package)

        let grantStore = PluginCapabilityGrantStore()
        grantStore.setDecision(
            .granted,
            for: package.manifest.id,
            pluginVersion: package.manifest.version,
            capability: .readSelectedText
        )
        let hostServiceBroker = CapabilityCheckedHostServiceBroker(
            grantStore: grantStore,
            systemPermissionCheck: { _ in true },
            selectedTextProvider: { "selected text" },
            clipboardWriter: { _ in }
        )

        let outcome = HostActionRunner(
            executor: NoopHostCommandExecutor(),
            scriptedExecutor: PluginRuntimeSupervisor(helperURL: helperURL),
            hostServiceBroker: hostServiceBroker
        ).invoke(action, using: registry)

        XCTAssertEqual(outcome.terminal, .succeeded(.string("identity-bound")))
    }

    func testFixtureStructuredDataCommandRunsInTheJavaScriptCoreHelper() throws {
        let helperURL = try XCTUnwrap(helperURLIfBuilt(), "Build SpinnetPluginHelper before running integration tests")
        let package = try loadFixturePackage()
        let command = try XCTUnwrap(package.manifest.commands.first {
            $0.id == CommandID("fixture.transform_data")
        })
        let input = #"{"items":[{"id":2,"name":"beta","enabled":true},{"id":1,"name":"alpha","enabled":true},{"id":3,"name":"disabled","enabled":false}]}"#
        let action = try ActionConfiguration(
            id: ActionID("fixture-transform-data"),
            pluginID: package.manifest.id,
            command: command,
            input: .string(input)
        )

        let registry = PluginRegistry()
        try registry.register(package)
        let runner = HostActionRunner(
            executor: NoopHostCommandExecutor(),
            scriptedExecutor: PluginRuntimeSupervisor(helperURL: helperURL)
        )
        let outcome = runner.invoke(action, using: registry)
        guard case .succeeded(let result) = outcome.terminal else {
            return XCTFail("The structured-data Action should succeed through the Host seam")
        }
        XCTAssertEqual(
            result,
            .object([
                "checksum": .string("3454327220"),
                "output_bytes": .number(20)
            ])
        )

        let objectAction = try ActionConfiguration(
            id: ActionID("fixture-transform-data-object"),
            pluginID: package.manifest.id,
            command: command,
            input: .object([
                "items": .array([
                    .object([
                        "id": .number(2),
                        "name": .string("beta"),
                        "enabled": .bool(true)
                    ]),
                    .object([
                        "id": .number(1),
                        "name": .string("alpha"),
                        "enabled": .bool(true)
                    ]),
                    .object([
                        "id": .number(3),
                        "name": .string("disabled"),
                        "enabled": .bool(false)
                    ])
                ])
            ])
        )
        let objectOutcome = runner.invoke(objectAction, using: registry)
        guard case .succeeded(let objectResult) = objectOutcome.terminal else {
            return XCTFail("The object-form structured-data Action should succeed")
        }
        XCTAssertEqual(objectResult, result)
    }

    func testFatalHelperFaultIsContainedByTheHostProcess() throws {
        let helperURL = try XCTUnwrap(helperURLIfBuilt(), "Build SpinnetPluginHelper before running integration tests")
        let process = Process()
        process.executableURL = helperURL
        process.arguments = ["--fault-abort"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGABRT)
    }

    func testSupervisorReportsAFatalHelperFaultAtTheActionSeam() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpinnetCrashHelper-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let helperURL = directory.appendingPathComponent("crash-helper")
        try Data("#!/bin/sh\nkill -ABRT $$\n".utf8).write(to: helperURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: helperURL.path
        )

        let package = try loadFixturePackage()
        let command = try XCTUnwrap(package.manifest.commands.first {
            $0.id == CommandID("fixture.transform_text")
        })
        let action = try ActionConfiguration(
            id: ActionID("fixture-transform-text-crash"),
            pluginID: package.manifest.id,
            command: command,
            input: .string("Spinnet Plugin fixture")
        )
        let supervisor = PluginRuntimeSupervisor(helperURL: helperURL)
        let registry = PluginRegistry()
        try registry.register(package)
        let outcome = HostActionRunner(
            executor: NoopHostCommandExecutor(),
            scriptedExecutor: supervisor
        ).invoke(action, using: registry)

        guard case .failed(let failure) = outcome.terminal else {
            return XCTFail("A fatal helper fault should produce a terminal Host failure")
        }
        XCTAssertEqual(failure.category, .helperCrashed)
        XCTAssertEqual(failure.pluginID, action.pluginID)
        XCTAssertEqual(failure.actionID, action.id)
        XCTAssertEqual(supervisor.launchCount, 1)
    }

    private func loadFixturePackage() throws -> PluginPackage {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        return try PluginManifestLoader.load(
            packageAt: root.appendingPathComponent("Plugins/SpinnetFixture.spinnetplugin")
        )
    }

    private func makeInvocation(scriptSource: String) -> PluginRuntimeInvocation {
        PluginRuntimeInvocation(
            invocationID: "invocation-1",
            pluginID: PluginID("com.example.fixture"),
            actionID: ActionID("action-1"),
            commandID: CommandID("fixture.transform_text"),
            scriptPath: "transform-text.js",
            scriptSource: scriptSource,
            input: .string("value")
        )
    }

    private func readFramedBody(_ body: Data) throws -> Data? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpinnetProtocolFrame-\(UUID().uuidString)")
        var framed = body
        framed.append(0x0A)
        try framed.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try PluginRuntimeProtocol.readFrame(
            from: handle,
            label: "Test message"
        )
    }

    private func makeScriptedPackage(pluginID: PluginID, script: String) throws -> PluginPackage {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpinnetProtocolPackage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data(script.utf8).write(to: directory.appendingPathComponent("action.js"))
        let command = CommandDeclaration(
            id: CommandID("\(pluginID.rawValue).action"),
            title: "Action",
            execution: .javascript,
            script: "action.js"
        )
        let manifest = try PluginManifest(
            id: pluginID,
            name: pluginID.rawValue,
            version: "1.0.0",
            commands: [command]
        )
        return PluginPackage(rootURL: directory, manifest: manifest)
    }

    private func makeShellHelper(_ source: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpinnetHostileHelper-\(UUID().uuidString)")
        try Data(source.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
        return url
    }

    private func helperURLIfBuilt() -> URL? {
        if let value = ProcessInfo.processInfo.environment["SPINNET_PLUGIN_HELPER_URL"] {
            let url = URL(fileURLWithPath: value)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }

        if let executableURL = Bundle.main.executableURL {
            var directory = executableURL.deletingLastPathComponent()
            for _ in 0..<5 {
                let candidate = directory.appendingPathComponent("SpinnetPluginHelper")
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
                directory.deleteLastPathComponent()
            }
        }

        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let buildRoot = root.appendingPathComponent(".build", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: buildRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isExecutableKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in enumerator {
            guard url.lastPathComponent == "SpinnetPluginHelper",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isExecutableKey]),
                  values.isRegularFile == true,
                  values.isExecutable == true else { continue }
            return url
        }
        return nil
    }
}

private struct NoopHostCommandExecutor: HostCommandExecutor {
    func execute(_ action: ActionConfiguration) throws -> JSONValue { .null }
}
