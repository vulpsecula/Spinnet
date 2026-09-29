import XCTest
@testable import SpinnetCore
import SpinnetPluginTestKit

/// The Smart Jump Bundled Plugin recognises the selected text in its script
/// and asks the Host to open what it found. These tests pin its package
/// shape, the Host's own validation of a link, and authorization in front
/// of each effect. No test opens a real URL: the opener is always a
/// recording closure.
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
        XCTAssertEqual(manifest.settingsFields.map(\.kind), [.list])
        guard case .array(let engines)? = manifest.defaultSettings["search_engines"] else {
            return XCTFail("Smart Jump ships its engines as list rows")
        }
        XCTAssertEqual(engines.map { row -> JSONValue? in
            guard case .object(let cells) = row else { return nil }
            return cells["name"]
        }, [.string("Google"), .string("Bing"), .string("DuckDuckGo")])
        XCTAssertEqual(manifest.capabilities, [.readSelectedText, .readCurrentClipboard, .openURL, .writeClipboard, .openLocalPath])
        XCTAssertEqual(manifest.optionalCapabilities, [.readCurrentClipboard, .writeClipboard, .openLocalPath])
        XCTAssertEqual(manifest.scope(for: .readCurrentClipboard)?.dataTypes, ["text"])
        XCTAssertFalse(manifest.scope(for: .readCurrentClipboard)?.includesExistingHostData ?? true)
        XCTAssertFalse(manifest.capabilities.contains(.contactHTTPS), "Opening a link grants no fetch")
        let command = manifest.commands[0]
        XCTAssertEqual(manifest.requiredCapabilities(for: command), [.readSelectedText, .openURL])
        XCTAssertEqual(manifest.requiredSystemPermissions(for: command), [.accessibility])
    }

    /// The engines setting refuses what the text setting before it refused:
    /// no engine, more than ten, a blank, long or repeated name, and a URL
    /// that is not https or does not hold `{query}` once in its path or query.
    func testTheEnginesSettingRefusesWhatItRefusedAsText() throws {
        let manifest = try SmartJumpFixture.load().manifest
        let field = try XCTUnwrap(manifest.settingsFields.first)
        func engine(_ name: String, _ url: String) -> JSONValue { .object(["name": .string(name), "url": .string(url)]) }
        let good = "https://example.com/search?q={query}"
        XCTAssertTrue(field.acceptsMemberValue(.array([engine(String(repeating: "n", count: 50), good)])))
        XCTAssertTrue(field.acceptsMemberValue(.array((1...10).map { engine("E\($0)", good) })))
        XCTAssertEqual(manifest.missingSettings(in: ["search_engines": .array([])], hasSecret: { _ in true }).count, 1,
                       "no engine leaves Smart Jump unavailable")
        for rows in [
            (1...11).map { engine("E\($0)", good) },
            [engine(" ", good)],
            [engine(String(repeating: "n", count: 51), good)],
            [engine("A", good), engine("A", "https://b.example/?q={query}")],
            [engine("A", "")],
            [engine("A", "javascript:{query}")],
            [engine("A", "http://example.com/search?q={query}")],
            [engine("A", "https://{query}.com/")],
            [engine("A", "https://user:secret@example.com/?q={query}")],
            [engine("A", "https://example.com")],
            [engine("A", "https://example.com/?q={query}&r={query}")],
            [engine("A", "https://example.com/#{query}")]
        ] {
            XCTAssertFalse(field.acceptsMemberValue(.array(rows)), "\(rows)")
        }
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
            selectedTextProvider: { _ in "" }, clipboardWriter: { _ in },
            urlOpener: open
        )
    }

    private func request(_ service: PluginHostService, _ input: JSONValue, _ action: ActionConfiguration) -> PluginRuntimeHostServiceRequest {
        PluginRuntimeHostServiceRequest(invocationID: UUID().uuidString, actionID: action.id,
                                        requestID: UUID().uuidString, service: service, input: input)
    }
}

/// Smart Jump's script runs in the real helper through the Plugin test kit:
/// what it reads, what it opens, and the view it shows when there is
/// nothing to open yet, with recorded answers in place of the Host. Each
/// effect goes through its own Host Service, which the Host authorizes
/// when it is asked, so a refusal reaches the script as the Host's own.
final class SmartJumpScriptTests: XCTestCase {
    private var smartJump: SmartJumpDriver!

    override func setUpWithError() throws {
        smartJump = try SmartJumpDriver()
    }

    override func tearDown() {
        smartJump?.shutdown()
        smartJump = nil
    }

    /// Starts the Action with `selection` selected.
    private func start(_ selection: JSONValue, settings: JSONValue? = nil,
                       _ overrides: [PluginHostService: RecordedHostServices.Answer] = [:]) -> PluginTestRun {
        smartJump.run(settings: settings, answering: SmartJumpDriver.services(selection: selection, overrides))
    }

    private func assertOpens(_ selection: String, _ service: PluginHostService, _ target: String,
                             settings: JSONValue? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let run = start(.string(selection), settings: settings)
        XCTAssertEqual(try run.result.get(), .null, "Opening shows no view", file: file, line: line)
        XCTAssertEqual(run.requests, [
            PluginTestRequest(service: .readSelectedText, input: .object(["best_effort": .bool(true)])),
            PluginTestRequest(service: service, input: .string(target))
        ], file: file, line: line)
    }

    private func assertRefused(_ run: PluginTestRun, _ capability: PluginCapability,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try run.result.get(), file: file, line: line) {
            XCTAssertEqual($0 as? PluginRuntimeError,
                           .capabilityDenied(PluginHostServiceError.capabilityDenied(capability).description),
                           file: file, line: line)
        }
    }

    // MARK: A selection

    func testSmartJumpOpensTheSelectedLink() {
        assertOpens("  https://example.com/path?q=1 \n", .openURL, "https://example.com/path?q=1")
    }

    func testSmartJumpFindsAnAddressInASelection() {
        assertOpens("See github.com for the project", .openURL, "https://github.com")
    }

    func testSmartJumpOpensPathsWithTheirOwnService() throws {
        assertOpens("Look in /tmp/report.pdf, please.", .openLocalPath, "/tmp/report.pdf")
        let package = smartJump.plugin.package
        XCTAssertTrue(PluginPermissionDisclosure(manifest: package.manifest).details(for: .controls).contains("local files and folders"))
        XCTAssertFalse(package.manifest.capabilities.contains(.contactHTTPS))
    }

    func testSmartJumpSearchesUnrecognisedTextWithoutOpeningUnsupportedSchemes() throws {
        for selection in ["mailto:someone@example.com", "javascript:alert(1)", "ordinary search text", "https://"] {
            guard case .search(let url, _) = SmartJumpDriver.google(selection) else { return XCTFail() }
            assertOpens(selection, .openURL, url)
        }
    }

    /// The same engines serve a selection and the view: the first is the default.
    func testSmartJumpSharesConfiguredEnginesBetweenSelectionAndInput() throws {
        let settings = smartJump.settings(engines: .array([
            SmartJumpDriver.engine("DuckDuckGo", "https://duckduckgo.com/?q={query}"),
            SmartJumpDriver.engine("Google", "https://www.google.com/search?q={query}")
        ]))
        assertOpens("cats & dogs", .openURL, "https://duckduckgo.com/?q=cats%20%26%20dogs", settings: settings)
        let submitted = smartJump.run(SmartJumpDriver.submitted("cats & dogs"), state: .object(["query": .string("")]),
                                      settings: settings)
        XCTAssertEqual(submitted.inputs(to: .openURL), [.string("https://duckduckgo.com/?q=cats%20%26%20dogs")])
    }

    /// Engines a user saved before the `list` kind, as text, migrate to rows
    /// and still search in their order: the first stays the default.
    func testEnginesSavedAsTextStillSearchWithTheFirst() throws {
        let manifest = smartJump.plugin.manifest
        let stored = try XCTUnwrap(manifest.listSettingsAsRows(["search_engines": .string(
            "DuckDuckGo | https://duckduckgo.com/?q={query}\nGoogle | https://www.google.com/search?q={query}"
        )]))
        assertOpens("cats", .openURL, "https://duckduckgo.com/?q=cats",
                    settings: .object(manifest.resolvedSettings(stored: stored)))
    }

    /// Opening a link needs neither of the optional grants: copying and
    /// opening local paths.
    func testSmartJumpOpensLinksWithoutTheOptionalGrants() throws {
        let run = start(.string("https://example.com"), [
            .writeClipboard: .failure(.capabilityDenied(.writeClipboard)),
            .openLocalPath: .failure(.capabilityDenied(.openLocalPath))
        ])
        XCTAssertEqual(try run.result.get(), .null)
        XCTAssertEqual(run.inputs(to: .openURL), [.string("https://example.com")])
    }

    /// A grant refused or revoked by the time the script opens the target
    /// ends the Action with the Host's refusal, and nothing opens instead.
    func testARefusedEffectEndsTheActionWithoutAFallback() {
        let link = start(.string("https://example.com"), [.openURL: .failure(.capabilityDenied(.openURL))])
        assertRefused(link, .openURL)
        XCTAssertEqual(link.requests.map(\.service), [.readSelectedText, .openURL])
        let path = start(.string("/tmp/report.pdf"), [.openLocalPath: .failure(.capabilityDenied(.openLocalPath))])
        assertRefused(path, .openLocalPath)
        XCTAssertEqual(path.requests.map(\.service), [.readSelectedText, .openLocalPath])
    }

    func testASelectionOverSixteenKiBIsRefusedNearThePointer() throws {
        let run = start(.string(String(repeating: "x", count: 16 * 1024 + 1)))
        let answer = try run.answer()
        XCTAssertNil(answer.view)
        XCTAssertEqual(answer.toast, "Smart Jump accepts up to 16 KiB of text")
        XCTAssertEqual(run.requests.map(\.service), [.readSelectedText])
    }

    // MARK: The view

    /// With nothing selected the view opens with an empty field; what is
    /// typed is recognized with no effect, and submitting it opens it and
    /// closes the view.
    func testSmartJumpWithoutASelectionPresentsInputAndOpensWhatIsSubmitted() throws {
        let opened = try smartJump.view(of: start(.string("   ")))
        XCTAssertEqual(opened.view.title, "Smart Jump")
        XCTAssertEqual(opened.view.form?.fields.map(\.kind), [.text])
        XCTAssertEqual(opened.query, .string(""))
        XCTAssertEqual(opened.statusTitle, "Type to preview")
        XCTAssertEqual(opened.view.form?.submitTitle, "Jump")
        XCTAssertEqual(opened.view.actions, [])

        let typed = smartJump.run(SmartJumpDriver.typed("github.com"), state: opened.answer.state)
        XCTAssertEqual(typed.requests, [], "Recognizing has no effect")
        let preview = try smartJump.view(of: typed)
        XCTAssertEqual(preview.statusTitle, "Open web address")
        XCTAssertEqual(preview.statusText, "https://github.com")
        XCTAssertEqual(preview.view.form?.submitTitle, "Open")

        let submitted = smartJump.run(SmartJumpDriver.submitted("github.com"), state: preview.answer.state)
        XCTAssertEqual(submitted.inputs(to: .openURL), [.string("https://github.com")])
        XCTAssertEqual(try submitted.answer().close, true)

        let revoked = smartJump.run(SmartJumpDriver.submitted("example.com"), state: preview.answer.state,
                                    answering: SmartJumpDriver.services([.openURL: .failure(.capabilityDenied(.openURL))]))
        assertRefused(revoked, .openURL)
    }

    /// An App that keeps its selection to itself leaves the view waiting for
    /// text rather than failing.
    func testSmartJumpPresentsInputWhenSelectedTextCannotBeRead() throws {
        let run = start(.null)
        XCTAssertEqual(run.inputs(to: .readSelectedText), [.object(["best_effort": .bool(true)])])
        let opened = try smartJump.view(of: run)
        XCTAssertEqual(opened.query, .string(""))
        XCTAssertEqual(opened.statusTitle, "Type to preview")
    }

    func testSubmittingNothingAsksForText() throws {
        let submitted = smartJump.run(SmartJumpDriver.submitted(" "), state: .object(["query": .string("")]))
        XCTAssertEqual(submitted.requests, [])
        let shown = try smartJump.view(of: submitted)
        XCTAssertEqual(shown.answer.toast, "Enter text to jump")
        XCTAssertFalse(shown.answer.close)
    }

    /// A pasted text far over 16 KiB is refused in the view rather than
    /// ending it: it stays out of the field and the state, which the Host
    /// bounds.
    func testAHugeTextIsRefusedWithoutEndingTheView() throws {
        let huge = String(repeating: "x", count: 100_000)
        let shown = try smartJump.view(of: smartJump.run(SmartJumpDriver.typed(huge), state: .object(["query": .string("")])))
        XCTAssertEqual(shown.statusText, "Smart Jump accepts up to 16 KiB of text")
        XCTAssertEqual(shown.query, .string(""))
        XCTAssertEqual(shown.answer.state, .object(["query": .string("")]))
    }

    /// Each kind of target names its own button.
    func testTheSubmitButtonSaysWhatItDoes() throws {
        for (text, title) in [("cats", "Search"), ("BV1Et41137T6", "Watch"), ("https://example.com/a.zip", "Download"),
                              ("10.1000/123", "Open"), ("/tmp", "Open"), ("1+1", "Calculate"), ("1/0", "Jump")] {
            let shown = try smartJump.view(of: smartJump.run(SmartJumpDriver.typed(text), state: .object(["query": .string("")])))
            XCTAssertEqual(shown.view.form?.submitTitle, title, text)
        }
    }

    /// Arithmetic shows its result in the view, which stays open when the
    /// user submits it; copying the result needs the clipboard grant.
    func testSmartJumpShowsArithmeticAndCopiesOnlyWithTheClipboardGrant() throws {
        let run = start(.string("2+3*4"))
        XCTAssertEqual(run.requests.map(\.service), [.readSelectedText], "Showing a result must not overwrite the clipboard")
        let shown = try smartJump.view(of: run)
        XCTAssertEqual(shown.query, .string("2+3*4"))
        XCTAssertEqual(shown.statusTitle, "Calculate")
        XCTAssertEqual(shown.statusText, "Result: 14")

        let submitted = try smartJump.view(of: smartJump.run(SmartJumpDriver.submitted("(4+2)/3"), state: shown.answer.state))
        XCTAssertEqual(submitted.statusText, "Result: 2")
        XCTAssertFalse(submitted.answer.close, "A calculation keeps the view open")

        let copied = smartJump.run(.actionChosen("copy_result"), state: submitted.answer.state)
        XCTAssertEqual(copied.inputs(to: .writeClipboard), [.string("2")])
        XCTAssertEqual(try copied.answer().toast, "Copied")

        let refused = smartJump.run(.actionChosen("copy_result"), state: .object(["query": .string("2+3")]),
                                    answering: SmartJumpDriver.services([.writeClipboard: .failure(.capabilityDenied(.writeClipboard))]))
        assertRefused(refused, .writeClipboard)
    }

    /// The state holds only the field's text, so the helper may retire
    /// between View Events.
    func testTheViewKeepsOnlyTheFieldsTextBetweenEvents() throws {
        let shown = try smartJump.view(of: start(.string("6*7")))
        XCTAssertEqual(shown.answer.state, .object(["query": .string("6*7")]))
        smartJump.helper.retireHelper(of: smartJump.plugin)
        let copied = smartJump.run(.actionChosen("copy_result"), state: shown.answer.state)
        XCTAssertEqual(copied.inputs(to: .writeClipboard), [.string("42")])
    }

    /// Smart Jump installed from a file behaves as the copy the app ships:
    /// where a Plugin came from grants it nothing.
    func testAnInstalledSmartJumpPresentsTheSameView() throws {
        let installed = try SmartJumpDriver(origin: .installed)
        defer { installed.shutdown() }
        for selection in ["", "1+1"] {
            let shown = try installed.view(of: installed.run(answering: SmartJumpDriver.services(selection: .string(selection))))
            XCTAssertEqual(shown.query, .string(selection))
        }
    }
}
