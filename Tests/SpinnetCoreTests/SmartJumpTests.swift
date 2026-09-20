import XCTest
@testable import SpinnetCore

/// The Smart Jump Bundled Plugin reads the selected text and asks the Host to
/// recognise and act on it in the Host. These tests pin its package shape,
/// Host-side validation, and authorization in front of each effect.
/// No test opens a real URL: the opener is always a recording closure.
final class SmartJumpTests: XCTestCase {

    func testSmartJumpAppearsOnceInTheLibraryAsAReadyToUsePreset() throws {
        let package = try SmartJumpFixture.load()
        let registry = PluginRegistry()
        try registry.register(package)

        let presets = registry.menuItemPresets().filter { $0.pluginID == package.manifest.id }
        XCTAssertEqual(presets.count, 1)
        let preset = try XCTUnwrap(presets.first)
        XCTAssertEqual(preset.name, "Smart Jump")
        XCTAssertEqual(preset.readiness, .readyToUse)
        XCTAssertEqual(preset.commands.map(\.id.rawValue), ["smart_jump.open_selection"])
        XCTAssertTrue(preset.commands.allSatisfy { $0.execution == .javascript && !$0.isConfigurable })
        XCTAssertTrue(preset.commands.allSatisfy { $0.explanation?.isEmpty == false }, "Every Command has a description")
    }

    func testSmartJumpDeclaresEachEffectSeparatelyWithoutNetworkFetch() throws {
        let manifest = try SmartJumpFixture.load().manifest
        XCTAssertEqual(manifest.settingsFields.map(\.kind), [.searchEngines])
        guard case .string(let searchEngines)? = manifest.defaultSettings["search_engines"] else {
            return XCTFail("Search defaults should be an ordered string")
        }
        XCTAssertEqual(try SmartJumpSearchEngine.parse(searchEngines).map(\.name), ["Google", "Bing", "DuckDuckGo"])
        XCTAssertEqual(manifest.capabilities, [.readSelectedText, .readCurrentClipboard, .openURL, .writeClipboard, .openLocalPath])
        XCTAssertEqual(manifest.optionalCapabilities, [.readCurrentClipboard, .writeClipboard, .openLocalPath])
        XCTAssertEqual(manifest.scope(for: .readCurrentClipboard)?.dataTypes, ["text"])
        XCTAssertFalse(manifest.scope(for: .readCurrentClipboard)?.includesExistingHostData ?? true)
        XCTAssertFalse(manifest.capabilities.contains(.contactHTTPS), "Opening a link grants no fetch")
        let command = manifest.commands[0]
        XCTAssertEqual(manifest.requiredCapabilities(for: command), [.readSelectedText, .openURL])
        XCTAssertEqual(manifest.requiredSystemPermissions(for: command), [.accessibility])
    }

    func testOpeningALinkIsItsOwnServiceWithoutASystemPermission() {
        let service = PluginHostService.openURL
        XCTAssertEqual(service.rawValue, "open_url")
        XCTAssertEqual(service.requiredCapability, .openURL)
        XCTAssertNil(service.requiredSystemPermission)
        XCTAssertEqual(PluginCapability.openURL.rawValue, "open_url")
        XCTAssertTrue(PluginCapability.openURL.isSupportedByHostServices)
        XCTAssertEqual(PluginCapability.openURL.consentGroup, .controls)
    }

    func testConsentDisclosesThatTheBrowserReceivesTheLink() throws {
        let manifest = try SmartJumpFixture.load().manifest
        let disclosure = PluginPermissionDisclosure(manifest: manifest)
        let controls = disclosure.details(for: .controls)
        XCTAssertTrue(controls.contains("Open http and https links in the default browser"), controls)
        XCTAssertTrue(controls.contains("Open Selected Link"), controls)
        let reads = disclosure.details(for: .reads)
        XCTAssertTrue(reads.contains("Selected text"), reads)
        XCTAssertTrue(reads.contains("Read Current Clipboard"), reads)
        XCTAssertTrue(reads.contains("Optional for these Commands"), reads)
        XCTAssertTrue(reads.contains("Accessibility-only selection"), reads)
        XCTAssertTrue(controls.contains("Open local files and folders"), controls)
        XCTAssertTrue(controls.contains("Optional for Commands"), controls)
        let changes = disclosure.details(for: .changes)
        XCTAssertTrue(changes.contains("Replace current clipboard text"), changes)
        XCTAssertTrue(changes.contains("Optional for Commands"), changes)
        XCTAssertEqual(disclosure.details(for: .contacts), "None")
    }

    // MARK: - Link validation

    func testValidLinksAreTrimmedAndOpenedAsGiven() throws {
        XCTAssertEqual(try OpenableURL.validate("https://example.com").absoluteString, "https://example.com")
        XCTAssertEqual(try OpenableURL.validate("  http://example.com/a?b=c#d \n").absoluteString, "http://example.com/a?b=c#d")
        XCTAssertEqual(try OpenableURL.validate("HTTPS://Example.com/Path").absoluteString, "HTTPS://Example.com/Path")
        XCTAssertEqual(try OpenableURL.validate("https://example.com:8443/x").absoluteString, "https://example.com:8443/x")
        let longest = "https://example.com/" + String(repeating: "a", count: OpenableURL.maximumLength - 20)
        XCTAssertEqual(try OpenableURL.validate(longest).absoluteString, longest)
    }

    func testEmptyTextIsRefused() {
        for text in ["", "   ", "\n\t "] {
            assertRejected(text, OpenableURL.emptyMessage)
        }
    }

    func testOnlyHTTPAndHTTPSSchemesAreOpened() {
        for text in ["mailto:someone@example.com", "javascript:alert(1)", "file:///etc/passwd",
                     "ftp://example.com", "spinnet://settings", "data:text/html,hi", "example.com",
                     "www.example.com/path"] {
            assertRejected(text, OpenableURL.unsupportedSchemeMessage)
        }
    }

    func testMalformedTextIsRefused() {
        for text in ["https://", "https:///path", "http:example.com", "https://exa mple.com",
                     "https://a.example\nhttps://b.example", "https://example.com/\u{0}",
                     "just some words", "https://[not-an-ip"] {
            assertRejected(text, OpenableURL.malformedMessage)
        }
        let tooLong = "https://example.com/" + String(repeating: "a", count: OpenableURL.maximumLength)
        assertRejected(tooLong, OpenableURL.tooLongMessage)
    }

    // MARK: - Broker

    func testOpeningALinkRequiresTheGrantButNoSystemPermission() throws {
        let package = try SmartJumpFixture.load()
        let action = try makeAction(in: package)
        let grants = PluginCapabilityGrantStore()
        var opened: [URL] = []
        let broker = makeBroker(grants: grants, accessibility: { false }, open: { opened.append($0) })
        let link = JSONValue.string("https://example.com")

        XCTAssertThrowsError(try broker.execute(request: request(.openURL, link, action), for: package, action: action)) {
            XCTAssertEqual($0 as? PluginHostServiceError, .capabilityDenied(.openURL))
        }
        SmartJumpFixture.grant(package, in: grants)
        // Accessibility is off: opening a link does not need it.
        XCTAssertEqual(try broker.execute(request: request(.openURL, link, action), for: package, action: action), .null)
        XCTAssertEqual(opened, [URL(string: "https://example.com")!])

        grants.setDecision(.denied, for: package.manifest.id, pluginVersion: package.manifest.version, capability: .openURL)
        XCTAssertThrowsError(try broker.execute(request: request(.openURL, link, action), for: package, action: action)) {
            XCTAssertEqual($0 as? PluginHostServiceError, .capabilityDenied(.openURL))
        }
        XCTAssertEqual(opened.count, 1)
    }

    /// The Host validates the link itself, so a Plugin cannot open another
    /// scheme by skipping its own checks; nothing invalid reaches the opener.
    func testTheBrokerRefusesAnythingButAValidLink() throws {
        let package = try SmartJumpFixture.load()
        let action = try makeAction(in: package)
        let grants = PluginCapabilityGrantStore()
        SmartJumpFixture.grant(package, in: grants)
        var opened: [URL] = []
        let broker = makeBroker(grants: grants, accessibility: { true }, open: { opened.append($0) })

        let invalid: [JSONValue] = [
            .null, .bool(true), .number(1), .string(""), .string("mailto:a@example.com"),
            .string("file:///etc/passwd"), .string("https://exa mple.com"),
            .object(["url": .string("https://example.com")]), .array([.string("https://example.com")])
        ]
        for input in invalid {
            XCTAssertThrowsError(try broker.execute(request: request(.openURL, input, action), for: package, action: action),
                                 "\(input)") { error in
                guard case .invalidInput = error as? PluginHostServiceError else {
                    return XCTFail("Expected invalid input for \(input), got \(error)")
                }
                XCTAssertEqual((error as? PluginHostServiceError)?.actionFailureCategory, .hostServiceFailed)
            }
        }
        XCTAssertEqual(opened, [])
    }

    func testAPluginThatDidNotDeclareTheCapabilityCannotOpenLinks() throws {
        let manifest = try PluginManifest(
            id: PluginID("com.example.reader"), name: "Reader", version: "1.0.0",
            capabilities: [.readSelectedText],
            commands: [CommandDeclaration(id: CommandID("read"), title: "Read", execution: .javascript, script: "read.js")]
        )
        let package = PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/reader"), manifest: manifest)
        let action = try ActionConfiguration(id: ActionID("read"), pluginID: manifest.id, command: manifest.commands[0], input: .null)
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(.granted, for: manifest.id, pluginVersion: manifest.version, capability: .readSelectedText)
        var opened: [URL] = []
        let broker = makeBroker(grants: grants, accessibility: { true }, open: { opened.append($0) })

        XCTAssertThrowsError(try broker.execute(request: request(.openURL, .string("https://example.com"), action),
                                                for: package, action: action)) {
            XCTAssertEqual($0 as? PluginHostServiceError, .capabilityDenied(.openURL))
        }
        XCTAssertEqual(opened, [])
    }

    func testTheCapabilityCarriesNoDataHostsOrAppsInItsScope() throws {
        func manifest(scope: String) -> Data {
            Data("""
            {
              "protocol_version": "1.0", "id": "com.example.jump", "name": "Jump", "version": "1.0.0",
              "capabilities": ["open_url"],
              "capability_scopes": [\(scope)],
              "commands": [{"id": "jump", "title": "Jump", "execution": "javascript", "is_configurable": false, "script": "jump.js"}]
            }
            """.utf8)
        }
        XCTAssertNoThrow(try PluginManifestLoader.decode(manifest(scope: "")))
        XCTAssertNoThrow(try PluginManifestLoader.decode(manifest(scope: """
            {"capability": "open_url", "command_ids": ["jump"], "data_types": [],
             "includes_existing_host_data": false, "https_hosts": [], "external_apps": []}
            """)))
        XCTAssertThrowsError(try PluginManifestLoader.decode(manifest(scope: """
            {"capability": "open_url", "command_ids": ["jump"], "data_types": [],
             "includes_existing_host_data": false, "https_hosts": ["example.com"], "external_apps": []}
            """)))
        XCTAssertThrowsError(try PluginManifestLoader.decode(manifest(scope: """
            {"capability": "open_url", "command_ids": ["jump"], "data_types": ["text"],
             "includes_existing_host_data": false, "https_hosts": [], "external_apps": []}
            """)))
    }

    // MARK: - Availability

    /// Missing Accessibility keeps the Menu Item and its Action but marks the
    /// Action unavailable with the Accessibility repair route; a withheld
    /// Capability gives the Grant Access route instead.
    func testMissingGrantOrAccessibilityKeepsTheMenuItemWithTheRightRepairRoute() throws {
        let package = try SmartJumpFixture.load()
        let grants = PluginCapabilityGrantStore()
        var accessibility = true
        let registry = PluginRegistry(grantStore: grants, systemPermissionCheck: { _ in accessibility })
        try registry.register(package)
        let editor = HostConfigurationEditor(
            registry: registry,
            configuration: try HostConfiguration(actions: [], menu: MenuConfiguration(slots: [.empty]))
        )
        let item = try editor.placePreset(pluginID: package.manifest.id, inSlotAt: 0)

        XCTAssertEqual(editor.availability(for: item.primaryActionID), .unavailable(.capabilityDenied))
        SmartJumpFixture.grant(package, in: grants)
        XCTAssertEqual(editor.availability(for: item.primaryActionID), .available)
        accessibility = false
        XCTAssertEqual(editor.availability(for: item.primaryActionID), .unavailable(.systemPermissionDenied))
        XCTAssertEqual(ActionUnavailableReason.systemPermissionDenied.description, "Enable Accessibility in Privacy & Permissions")
        accessibility = true
        grants.setDecision(.denied, for: package.manifest.id, pluginVersion: package.manifest.version, capability: .openURL)
        XCTAssertEqual(editor.availability(for: item.primaryActionID), .unavailable(.capabilityDenied))

        XCTAssertEqual(editor.configuration.menu.slots[0].item, item, "The Menu Item stays in its Slot")
        XCTAssertEqual(editor.configuration.actions.map(\.id), [item.primaryActionID])
    }

    // MARK: - Support

    private func assertRejected(_ text: String, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try OpenableURL.validate(text), "\(text.debugDescription)", file: file, line: line) {
            XCTAssertEqual($0 as? PluginHostServiceError, .invalidInput(message), "\(text.debugDescription)", file: file, line: line)
        }
    }

    private func makeAction(in package: PluginPackage) throws -> ActionConfiguration {
        try ActionConfiguration(id: ActionID("smart-jump"), pluginID: package.manifest.id,
                                command: package.manifest.commands[0], input: .null)
    }

    private func makeBroker(
        grants: PluginCapabilityGrantStore,
        accessibility: @escaping () -> Bool,
        open: @escaping (URL) throws -> Void
    ) -> CapabilityCheckedHostServiceBroker {
        CapabilityCheckedHostServiceBroker(
            grantStore: grants, systemPermissionCheck: { _ in accessibility() },
            selectedTextProvider: { "" }, clipboardWriter: { _ in },
            urlOpener: open
        )
    }

    private func request(_ service: PluginHostService, _ input: JSONValue, _ action: ActionConfiguration) -> PluginRuntimeHostServiceRequest {
        PluginRuntimeHostServiceRequest(invocationID: UUID().uuidString, actionID: action.id,
                                        requestID: UUID().uuidString, service: service, input: input)
    }
}

/// Smart Jump's script runs in the real helper, driven through the Host
/// Action seam with recording adapters.
extension PluginRuntimeTests {

    func testInstalledPluginsCannotPresentTheHostOwnedSmartJumpWindow() throws {
        for selection in ["", "1+1"] {
            var presented = false
            let outcome = try smartJumpOutcome(selection: { selection }, open: { _ in XCTFail("No URL expected") },
                                              present: { _ in presented = true }, origin: .installed)
            guard case .failed(let failure) = outcome else { XCTFail("Installed Plugin must not present Host UI"); continue }
            XCTAssertEqual(failure.category, .capabilityDenied)
            XCTAssertFalse(presented)
        }
    }

    func testSmartJumpSharesConfiguredEnginesBetweenSelectionAndInput() throws {
        let settings: [String: JSONValue] = ["search_engines": .string("DuckDuckGo | https://duckduckgo.com/?q={query}\nGoogle | https://www.google.com/search?q={query}")]
        var opened: [URL] = []
        let search = try smartJumpOutcome(selection: { "cats & dogs" }, open: { opened.append($0) }, settings: settings)
        guard case .succeeded = search else { return XCTFail("Search should succeed: \(search)") }
        XCTAssertEqual(opened, [URL(string: "https://duckduckgo.com/?q=cats%20%26%20dogs")!])
        var session: SmartJumpSession?
        _ = try smartJumpOutcome(selection: { "" }, open: { opened.append($0) }, present: { session = $0 }, settings: settings)
        let input = try XCTUnwrap(session)
        XCTAssertEqual(input.searchEngines.map(\.name), ["DuckDuckGo", "Google"])
        _ = try input.submit("cats & dogs")
        XCTAssertEqual(opened.last, URL(string: "https://duckduckgo.com/?q=cats%20%26%20dogs"))
    }

    func testSmartJumpOpensPathsWithSeparateAuthorityAndDisclosure() throws {
        var paths: [URL] = []
        var grants: PluginCapabilityGrantStore!
        let package = try SmartJumpFixture.load()
        let run = try smartJumpOutcome(selection: { "Look in /tmp/report.pdf, please." },
                                       open: { _ in XCTFail("No browser for a local path") }, path: { paths.append($0) })
        guard case .succeeded = run else { return XCTFail("Path should open: \(run)") }
        XCTAssertEqual(paths, [URL(fileURLWithPath: "/tmp/report.pdf")])
        let denied = try smartJumpOutcome(selection: {
            grants.setDecision(.denied, for: package.manifest.id, pluginVersion: package.manifest.version, capability: .openLocalPath)
            return "/tmp/report.pdf"
        }, open: { _ in XCTFail("No fallback after denial") }, grantStore: { grants = $0 }, path: { paths.append($0) })
        guard case .failed(let failure) = denied else { return XCTFail("A revoked path grant must fail") }
        XCTAssertEqual(failure.category, .capabilityDenied)
        XCTAssertEqual(paths.count, 1)
        XCTAssertTrue(PluginPermissionDisclosure(manifest: package.manifest).details(for: .controls).contains("local files and folders"))
        XCTAssertFalse(package.manifest.capabilities.contains(.contactHTTPS))
    }

    func testSmartJumpShowsArithmeticAndCopiesOnlyWithCurrentClipboardGrant() throws {
        var session: SmartJumpSession?
        var copied: [String] = []
        var grants: PluginCapabilityGrantStore!
        let outcome = try smartJumpOutcome(selection: { "2+3*4" }, open: { _ in XCTFail("No browser for arithmetic") },
                                          grantStore: { grants = $0 }, present: { session = $0 }, copy: { copied.append($0) })
        guard case .succeeded = outcome else { return XCTFail("Calculation should display: \(outcome)") }
        let result = try XCTUnwrap(session)
        XCTAssertEqual(try result.preview(result.initialText), .calculation(14))
        XCTAssertTrue(copied.isEmpty, "Showing a result must not overwrite the clipboard")
        XCTAssertEqual(try result.submit("(4+2)/3"), .calculation(2))
        try result.copyResult(for: "(4+2)/3")
        XCTAssertEqual(copied, ["2"])
        let package = try SmartJumpFixture.load()
        grants.setDecision(.denied, for: package.manifest.id, pluginVersion: package.manifest.version, capability: .writeClipboard)
        XCTAssertThrowsError(try result.copyResult(for: "2+3")) {
            XCTAssertEqual($0 as? PluginHostServiceError, .capabilityDenied(.writeClipboard))
        }
        XCTAssertEqual(copied, ["2"])
    }

    func testSmartJumpWithoutASelectionPresentsInputAndRechecksPermissionOnSubmit() throws {
        var session: SmartJumpSession?
        var opened: [URL] = []
        var grants: PluginCapabilityGrantStore!
        let outcome = try smartJumpOutcome(selection: { "" }, open: { opened.append($0) },
                                          grantStore: { grants = $0 }, present: { session = $0 })
        guard case .succeeded = outcome else { return XCTFail("Input should open: \(outcome)") }
        let input = try XCTUnwrap(session)
        XCTAssertEqual(input.initialText, "")
        XCTAssertEqual(try input.preview("github.com"), .link(URL(string: "https://github.com")!, .web))
        XCTAssertTrue(opened.isEmpty, "Preview must have no side effect")
        _ = try input.submit("github.com")
        XCTAssertEqual(opened, [URL(string: "https://github.com")!])
        let package = try SmartJumpFixture.load()
        grants.setDecision(.denied, for: package.manifest.id, pluginVersion: package.manifest.version, capability: .openURL)
        XCTAssertThrowsError(try input.submit("example.com")) {
            XCTAssertEqual($0 as? PluginHostServiceError, .capabilityDenied(.openURL))
        }
        XCTAssertEqual(opened.count, 1)
    }

    func testSmartJumpFindsAnAddressInASelectionThroughTheHostActionSeam() throws {
        var opened: [URL] = []
        let outcome = try smartJumpOutcome(selection: { "See github.com for the project" }, open: { opened.append($0) })
        guard case .succeeded = outcome else { return XCTFail("Recognition should succeed: \(outcome)") }
        XCTAssertEqual(opened, [URL(string: "https://github.com")!])
    }

    func testSmartJumpOpensTheSelectedLinkThroughTheHostActionSeam() throws {
        var opened: [URL] = []
        let outcome = try smartJumpOutcome(selection: { "  https://example.com/path?q=1 \n" }, open: { opened.append($0) })
        guard case .succeeded = outcome else { return XCTFail("A valid link should open: \(outcome)") }
        XCTAssertEqual(opened, [URL(string: "https://example.com/path?q=1")!])
    }

    func testSmartJumpUsesAccessibilitySelectionWithoutOptionalEffectGrants() throws {
        let package = try SmartJumpFixture.load()
        var selections = 0
        var opened: [URL] = []
        let outcome = try smartJumpOutcome(
            grant: false,
            selection: { selections += 1; return "https://example.com" },
            open: { opened.append($0) },
            grantStore: { grants in
                for capability in [PluginCapability.readSelectedText, .openURL] {
                    grants.setDecision(.granted, for: package.manifest.id, pluginVersion: package.manifest.version,
                                       capability: capability, scope: package.manifest.scope(for: capability))
                }
                for capability in [PluginCapability.writeClipboard, .openLocalPath] {
                    grants.setDecision(.denied, for: package.manifest.id, pluginVersion: package.manifest.version,
                                       capability: capability, scope: package.manifest.scope(for: capability))
                }
            },
            copyFallback: {
                XCTFail("An ungranted clipboard fallback must not run")
                return ""
            }
        )

        guard case .succeeded = outcome else {
            return XCTFail("Accessibility selection should work without the optional clipboard fallback grant: \(outcome)")
        }
        XCTAssertEqual(selections, 1)
        XCTAssertEqual(opened, [URL(string: "https://example.com")!])
    }

    func testSmartJumpSearchesUnrecognisedTextWithoutOpeningUnsupportedSchemes() throws {
        var opened: [URL] = []
        for selection in ["mailto:someone@example.com", "javascript:alert(1)", "ordinary search text", "https://"] {
            let outcome = try smartJumpOutcome(selection: { selection }, open: { opened.append($0) })
            guard case .succeeded = outcome else { XCTFail("Search should succeed: \(outcome)"); continue }
            XCTAssertEqual(opened.last, try SmartJumpSearchEngine.google.url(for: selection))
        }
    }

    func testSmartJumpIsDeniedWithoutTheGrantAndStopsWhenTheGrantIsRevoked() throws {
        var opened: [URL] = []
        // Never granted: the Action is refused before any helper runs.
        var selections = 0
        let denied = try smartJumpOutcome(grant: false, selection: { selections += 1; return "https://example.com" },
                                          open: { opened.append($0) })
        guard case .failed(let deniedFailure) = denied else { return XCTFail("A withheld grant should fail") }
        XCTAssertEqual(deniedFailure.category, .commandUnavailable)
        XCTAssertEqual(deniedFailure.message, ActionUnavailableReason.capabilityDenied.description)
        XCTAssertEqual(selections, 0)

        // Revoked while the selection is read: the open request is refused.
        let package = try SmartJumpFixture.load()
        var grants: PluginCapabilityGrantStore!
        let revoked = try smartJumpOutcome(
            selection: {
                grants.setDecision(.denied, for: package.manifest.id, pluginVersion: package.manifest.version, capability: .openURL)
                return "https://example.com"
            },
            open: { opened.append($0) },
            grantStore: { grants = $0 }
        )
        guard case .failed(let revokedFailure) = revoked else { return XCTFail("A revoked grant should fail") }
        XCTAssertEqual(revokedFailure.category, .capabilityDenied)
        XCTAssertEqual(opened, [])
    }

    func testSmartJumpWithoutAccessibilityIsUnavailableWithThePermissionRepairRoute() throws {
        var selections = 0
        var opened: [URL] = []
        let outcome = try smartJumpOutcome(accessibility: false, selection: { selections += 1; return "https://example.com" },
                                           open: { opened.append($0) })
        guard case .failed(let failure) = outcome else { return XCTFail("Missing Accessibility should fail") }
        XCTAssertEqual(failure.category, .commandUnavailable)
        XCTAssertEqual(failure.message, ActionUnavailableReason.systemPermissionDenied.description)
        XCTAssertEqual(selections, 0)
        XCTAssertEqual(opened, [])
    }

    private func smartJumpOutcome(
        grant: Bool = true,
        accessibility: Bool = true,
        selection: @escaping () throws -> String,
        open: @escaping (URL) throws -> Void,
        grantStore: (PluginCapabilityGrantStore) -> Void = { _ in },
        present: @escaping (SmartJumpSession) throws -> Void = { _ in
            throw PluginHostServiceError.unavailable("Unexpected input window")
        },
        copy: @escaping (String) throws -> Void = { _ in XCTFail("The clipboard was written") },
        path: @escaping (URL) throws -> Void = { _ in XCTFail("A local path was opened") },
        copyFallback: (() throws -> String)? = nil,
        settings: [String: JSONValue] = [:],
        origin: PluginOrigin = .bundled
    ) throws -> ActionTerminalOutcome {
        let loaded = try SmartJumpFixture.load()
        let package = PluginPackage(rootURL: loaded.rootURL, manifest: loaded.manifest, origin: origin)
        let grants = PluginCapabilityGrantStore()
        grantStore(grants)
        if grant { SmartJumpFixture.grant(package, in: grants) }
        let registry = PluginRegistry(grantStore: grants, systemPermissionCheck: { _ in accessibility })
        try registry.register(package)
        let action = try ActionConfiguration(id: ActionID("smart-jump"), pluginID: package.manifest.id,
                                             command: package.manifest.commands[0], input: .null)
        let broker = CapabilityCheckedHostServiceBroker(
            grantStore: grants, systemPermissionCheck: { _ in accessibility },
            selectedTextProvider: selection, selectedTextCopyFallbackProvider: copyFallback,
            clipboardWriter: copy,
            urlOpener: open,
            smartJumpPresenter: present,
            localPathOpener: path
        )
        let supervisor = PluginRuntimeSupervisor(helperURL: try XCTUnwrap(helperURLIfBuilt()))
        defer { supervisor.shutdown() }
        return HostActionRunner(
            executor: SmartJumpNoopExecutor(),
            scriptedExecutor: supervisor,
            hostServiceBroker: broker,
            pluginSettings: { $0.resolvedSettings(stored: settings) }
        ).invoke(action, using: registry).terminal
    }
}

private struct SmartJumpNoopExecutor: HostCommandExecutor {
    func execute(_ action: ActionConfiguration) throws -> JSONValue {
        XCTFail("Smart Jump ran a Host Command")
        return .null
    }
}

/// The repository's Smart Jump package, registered the way the Host registers
/// a Plugin that ships with the app.
enum SmartJumpFixture {
    static func load() throws -> PluginPackage {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let loaded = try PluginManifestLoader.load(packageAt: root.appendingPathComponent("Plugins/SmartJump.spinnetplugin"))
        return PluginPackage(rootURL: loaded.rootURL, manifest: loaded.manifest, origin: .bundled)
    }

    /// Grants the package's Capabilities with their current scopes.
    static func grant(_ package: PluginPackage, in grants: PluginCapabilityGrantStore) {
        for capability in package.manifest.capabilities {
            grants.setDecision(.granted, for: package.manifest.id, pluginVersion: package.manifest.version,
                               capability: capability, scope: package.manifest.scope(for: capability))
        }
    }
}
