import XCTest
@testable import SpinnetCore

/// Deep Link Templates (ADR 0012): a Plugin declares the links it may open
/// into an External App, with a fixed path and bounded parameters, in its
/// `control_external_app` scope. The Host checks them when it loads the
/// manifest, lists them when it asks for consent, fills them in, and opens
/// nothing else.
final class DeepLinkTemplateTests: XCTestCase {
    private static let notes = #"""
    {"bundle_id": "com.example.notes", "name": "Notes Example", "deep_link_templates": [
      {"id": "new", "url": "notes-example://note/new"},
      {"id": "search", "url": "notes-example://search?q={query}",
       "parameters": [{"key": "query", "kind": "text", "max_length": 100}]},
      {"id": "open", "url": "notes-example://folder/{folder}",
       "parameters": [{"key": "folder", "kind": "choice", "choices": ["inbox", "archive"]}]}
    ]}
    """#

    private static let commands = #"""
    [
      {"id": "notes.new", "title": "New Note", "execution": "host", "is_configurable": false,
       "host_command": "deep_link.open", "deep_link_template": "new"},
      {"id": "notes.open", "title": "Open Folder", "execution": "host", "is_configurable": true,
       "host_command": "deep_link.open", "deep_link_template": "open",
       "configuration_fields": [{"key": "folder", "kind": "choice", "title": "Folder", "choices": ["inbox", "archive"]}]},
      {"id": "notes.search", "title": "Search Notes", "execution": "javascript", "is_configurable": false,
       "script": "search.js"}
    ]
    """#

    static func manifest(externalApp: String = notes, commands: String = commands,
                         commandIDs: String = #"["notes.new", "notes.open", "notes.search"]"#,
                         defaultInputs: String = #"{"notes.open": {"folder": "inbox"}}"#,
                         primary: String = "notes.new") throws -> PluginManifest {
        try PluginManifestLoader.decode(Data("""
        {
          "protocol_version": "1.0",
          "api_level": 1,
          "id": "com.example.notes-links",
          "name": "Notes Links",
          "version": "1.0.0",
          "capabilities": ["control_external_app"],
          "capability_scopes": [{
            "capability": "control_external_app",
            "command_ids": \(commandIDs),
            "data_types": [],
            "includes_existing_host_data": false,
            "https_hosts": [],
            "external_apps": [\(externalApp)]
          }],
          "preset": {"readiness": "ready_to_use", "is_configurable": true,
                     "default_primary_command_id": "\(primary)", "default_inputs": \(defaultInputs)},
          "commands": \(commands)
        }
        """.utf8))
    }

    private func assertRejected(_ externalApp: String, _ message: String, line: UInt = #line) {
        XCTAssertThrowsError(try Self.manifest(externalApp: externalApp), message, line: line) { error in
            guard case ConfigurationError.invalidManifest = error else {
                return XCTFail("Expected an invalid manifest, got \(error)", line: line)
            }
        }
    }

    // MARK: Manifest

    func testTemplatesDecodeIntoTheExternalAppScope() throws {
        let manifest = try Self.manifest()
        let app = try XCTUnwrap(manifest.scope(for: .controlExternalApp)?.externalApps.first)

        XCTAssertEqual(app.bundleID, "com.example.notes")
        XCTAssertEqual(app.name, "Notes Example")
        XCTAssertEqual(app.operationFamilies, [])
        XCTAssertEqual(app.deepLinkTemplates.map(\.id), ["new", "search", "open"])
        XCTAssertEqual(app.deepLinkTemplates[1].parameters,
                       [.init(key: "query", kind: .text, maxLength: 100)])
        XCTAssertEqual(app.deepLinkTemplates[2].parameters,
                       [.init(key: "folder", kind: .choice, choices: ["inbox", "archive"])])
        let open = try XCTUnwrap(manifest.commands.first { $0.id == CommandID("notes.open") })
        XCTAssertEqual(open.hostCommand, .openDeepLink)
        XCTAssertEqual(open.deepLinkTemplate, "open")
        XCTAssertEqual(HostCommand.openDeepLink.requiredCapability, .controlExternalApp)
        XCTAssertNil(HostCommand.openDeepLink.requiredSystemPermission)
    }

    /// Bob's grant carries over only if its scope is persisted exactly as
    /// before: no name and no templates are written for it.
    func testAnOperationOnlyScopeKeepsItsPersistedForm() throws {
        let scope = PluginCapabilityScope(capability: .controlExternalApp, commandIDs: [CommandID("bob.translate")],
                                          externalApps: [.init(bundleID: "com.example.Bob", operationFamilies: ["translate"])])
        let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(scope))

        XCTAssertEqual(encoded, .object([
            "capability": .string("control_external_app"),
            "command_ids": .array([.string("bob.translate")]),
            "data_types": .array([]),
            "includes_existing_host_data": .bool(false),
            "https_hosts": .array([]),
            "external_apps": .array([.object([
                "bundle_id": .string("com.example.Bob"),
                "operation_families": .array([.string("translate")])
            ])])
        ]))
        let templated = try XCTUnwrap(Self.manifest().scope(for: .controlExternalApp))
        XCTAssertEqual(try JSONDecoder().decode(PluginCapabilityScope.self, from: JSONEncoder().encode(templated)),
                       templated, "a templated scope survives the grant file")
    }

    func testTemplatesThatCouldReachBeyondTheirAppAreRejected() {
        func app(_ url: String, parameters: String = "[]") -> String {
            #"{"bundle_id": "com.example.notes", "name": "Notes", "deep_link_templates": [{"id": "t", "url": "\#(url)", "parameters": \#(parameters)}]}"#
        }
        assertRejected(app("https://example.com/note"), "web links are opened through open_url, not a template")
        assertRejected(app("HTTP://example.com"), "a web scheme in capitals is still a web scheme")
        assertRejected(app("file:///etc/hosts"), "local files are not deep links")
        assertRejected(app("notes example://new"), "a scheme needs the scheme syntax")
        assertRejected(app("//note/new"), "a template names its scheme")
        assertRejected(app("{app}://new", parameters: #"[{"key": "app", "kind": "text", "max_length": 5}]"#),
                       "the scheme is fixed")
        assertRejected(app("notes://{host}/new", parameters: #"[{"key": "host", "kind": "choice", "choices": ["a"]}]"#),
                       "the host is fixed")
        assertRejected(app("notes://note/{missing}"), "every placeholder names a parameter")
        assertRejected(app("notes://note/new", parameters: #"[{"key": "unused", "kind": "text", "max_length": 5}]"#),
                       "every parameter is used")
        assertRejected(app("notes://note/{a}", parameters: #"[{"key": "a", "kind": "choice", "choices": ["x/../y"]}]"#),
                       "a choice cannot change the link's structure")
        assertRejected(app("notes://note/{a}", parameters: #"[{"key": "a", "kind": "choice", "choices": []}]"#),
                       "a choice parameter offers choices")
        assertRejected(app("notes://note/{a}", parameters: #"[{"key": "a", "kind": "text", "max_length": 0}]"#),
                       "a text parameter is bounded")
        assertRejected(app("notes://note/{a}", parameters: #"[{"key": "a", "kind": "text", "max_length": 4096}]"#),
                       "a text parameter is bounded")
        assertRejected(app("notes://note/{a}", parameters: #"[{"key": "a", "kind": "text"}]"#),
                       "a text parameter declares its bound")
        assertRejected(app("notes://note/{a}{a}", parameters: #"[{"key": "a", "kind": "text", "max_length": 5}]"#),
                       "a parameter is used once")
        assertRejected(#"{"bundle_id": "com.example.notes", "deep_link_templates": [{"id": "t", "url": "notes://new"}]}"#,
                       "the app whose links a Plugin opens is named for consent and repair")
        assertRejected(#"{"bundle_id": "com.example.notes", "name": "Notes"}"#,
                       "an External App entry names operations or templates")
        assertRejected(#"""
        {"bundle_id": "com.example.notes", "name": "Notes", "deep_link_templates": [
          {"id": "t", "url": "notes://a"}, {"id": "t", "url": "notes://b"}]}
        """#, "template IDs are unique")
    }

    func testADeepLinkCommandMustNameATemplateItsScopeAllows() throws {
        func manifest(_ command: String, inputs: String = "{}") throws -> PluginManifest {
            try Self.manifest(commands: "[\(command)]", commandIDs: #"["notes.one"]"#, defaultInputs: inputs,
                              primary: "notes.one")
        }
        func assertRefused(_ make: @autoclosure () throws -> PluginManifest, _ reason: String, line: UInt = #line) {
            XCTAssertThrowsError(try make(), reason, line: line) { error in
                XCTAssertTrue("\(error)".contains("Command notes.one"), "\(reason): \(error)", line: line)
            }
        }
        XCTAssertNoThrow(try manifest(#"""
        {"id": "notes.one", "title": "One", "execution": "host", "is_configurable": false,
         "host_command": "deep_link.open", "deep_link_template": "new"}
        """#))
        assertRefused(try manifest(#"""
        {"id": "notes.one", "title": "One", "execution": "host", "is_configurable": false,
         "host_command": "deep_link.open"}
        """#), "deep_link.open needs its template")
        assertRefused(try manifest(#"""
        {"id": "notes.one", "title": "One", "execution": "host", "is_configurable": false,
         "host_command": "deep_link.open", "deep_link_template": "elsewhere"}
        """#), "the template is declared")
        assertRefused(try manifest(#"""
        {"id": "notes.one", "title": "One", "execution": "host", "is_configurable": false,
         "host_command": "url.open", "deep_link_template": "new"}
        """#), "only deep_link.open names a template")
        assertRefused(try Self.manifest(commands: #"""
        [{"id": "notes.one", "title": "One", "execution": "host", "is_configurable": false,
          "host_command": "deep_link.open", "deep_link_template": "new"},
         {"id": "notes.two", "title": "Two", "execution": "javascript", "is_configurable": false, "script": "two.js"}]
        """#, commandIDs: #"["notes.two"]"#, defaultInputs: "{}", primary: "notes.one"), "the scope covers the Command")
        assertRefused(try manifest(#"""
        {"id": "notes.one", "title": "One", "execution": "host", "is_configurable": false,
         "host_command": "deep_link.open", "deep_link_template": "open"}
        """#), "a parameter is filled from a configuration field")
        assertRefused(try manifest(#"""
        {"id": "notes.one", "title": "One", "execution": "host", "is_configurable": true,
         "host_command": "deep_link.open", "deep_link_template": "open",
         "configuration_fields": [{"key": "folder", "kind": "choice", "choices": ["inbox", "trash"]}]}
        """#, inputs: #"{"notes.one": {"folder": "inbox"}}"#), "a field offers only the parameter's choices")
        XCTAssertNoThrow(try manifest(#"""
        {"id": "notes.one", "title": "One", "execution": "host", "is_configurable": true,
         "host_command": "deep_link.open", "deep_link_template": "search",
         "configuration_fields": [{"key": "query", "kind": "text"}]}
        """#, inputs: #"{"notes.one": {"query": "plans"}}"#))
    }

    // MARK: Filling a template in

    func testATemplateIsFilledOnlyWithItsDeclaredBoundedValues() throws {
        let app = try XCTUnwrap(Self.manifest().scope(for: .controlExternalApp)?.externalApps.first)
        let new = app.deepLinkTemplates[0], search = app.deepLinkTemplates[1], open = app.deepLinkTemplates[2]

        XCTAssertEqual(try new.link(with: [:]).absoluteString, "notes-example://note/new")
        XCTAssertEqual(try open.link(with: ["folder": .string("archive")]).absoluteString,
                       "notes-example://folder/archive")
        XCTAssertEqual(try search.link(with: ["query": .string("a&b=c/d?#e f ü")]).absoluteString,
                       "notes-example://search?q=a%26b%3Dc%2Fd%3F%23e%20f%20%C3%BC",
                       "text cannot add a query member, a path segment or a fragment")

        for (template, parameters) in [
            (open, ["folder": JSONValue.string("trash")]),
            (open, [:]),
            (open, ["folder": .number(1)]),
            (new, ["extra": .string("x")]),
            (search, ["query": .string(String(repeating: "q", count: 101))]),
            (search, ["query": .string("")])
        ] {
            XCTAssertThrowsError(try template.link(with: parameters), "\(template.id) \(parameters)") { error in
                guard case PluginHostServiceError.invalidInput = error else { return XCTFail("\(error)") }
            }
        }
    }

    func testEveryLinkATemplateSetCanOpenIsKnownOnlyWithoutText() throws {
        let app = try XCTUnwrap(Self.manifest().scope(for: .controlExternalApp)?.externalApps.first)

        XCTAssertEqual(app.deepLinkTemplates[0].concreteLinks, ["notes-example://note/new"])
        XCTAssertEqual(app.deepLinkTemplates[2].concreteLinks,
                       ["notes-example://folder/inbox", "notes-example://folder/archive"])
        XCTAssertNil(app.deepLinkTemplates[1].concreteLinks, "free text makes the set open-ended")
    }

    // MARK: Consent

    func testConsentListsEveryTemplate() throws {
        let details = PluginPermissionDisclosure(manifest: try Self.manifest()).details(for: .controls)

        XCTAssertTrue(details.contains("Notes Example (com.example.notes)"), details)
        XCTAssertTrue(details.contains("notes-example://note/new"), details)
        XCTAssertTrue(details.contains("notes-example://search?q={query} (query: text, at most 100 characters)"), details)
        XCTAssertTrue(details.contains("notes-example://folder/{folder} (folder: inbox, archive)"), details)
    }

    func testChangingATemplateAsksForConsentAgain() throws {
        let manifest = try Self.manifest()
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(.granted, for: manifest.id, pluginVersion: manifest.version,
                           capability: .controlExternalApp, scope: manifest.scope(for: .controlExternalApp))
        let changed = try Self.manifest(externalApp: Self.notes.replacingOccurrences(of: "note/new", with: "note/delete"))

        XCTAssertEqual(grants.decision(for: manifest.id, pluginVersion: manifest.version, capability: .controlExternalApp,
                                       scope: manifest.scope(for: .controlExternalApp)), .granted)
        XCTAssertEqual(grants.decision(for: changed.id, pluginVersion: changed.version, capability: .controlExternalApp,
                                       scope: changed.scope(for: .controlExternalApp)), .notDetermined,
                       "even with the version string reused")
        grants.prepareInstallation(of: changed, replacing: manifest)
        XCTAssertEqual(grants.requestsAfterInstallation(of: changed, replacing: manifest), [.controlExternalApp])
    }
}

/// `open_deep_link` lets a script open one of its Plugin's templates, with
/// the same checks a `deep_link.open` Command gets.
final class DeepLinkHostServiceTests: XCTestCase {
    func testAScriptOpensOnlyItsOwnTemplatesWithBoundedValues() throws {
        let manifest = try DeepLinkTemplateTests.manifest()
        let package = PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/notes-links"), manifest: manifest)
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(.granted, for: manifest.id, pluginVersion: manifest.version,
                           capability: .controlExternalApp, scope: manifest.scope(for: .controlExternalApp))
        var opened: [DeepLink] = []
        let broker = CapabilityCheckedHostServiceBroker(
            grantStore: grants, systemPermissionCheck: { _ in true },
            selectedTextProvider: { _ in "" }, clipboardWriter: { _ in },
            deepLinkOpener: { opened.append($0) }
        )
        let search = try XCTUnwrap(manifest.commands.first { $0.id == CommandID("notes.search") })
        let action = try ActionConfiguration(id: ActionID("search"), pluginID: manifest.id, command: search, input: .null)
        func open(_ input: JSONValue) throws -> JSONValue {
            try broker.execute(request: PluginRuntimeHostServiceRequest(
                invocationID: "invocation", actionID: action.id, service: .openDeepLink, input: input
            ), for: package, action: action)
        }

        XCTAssertEqual(try open(.object(["template": .string("search"),
                                         "parameters": .object(["query": .string("plans")])])), .null)
        XCTAssertEqual(try open(.object(["template": .string("new")])), .null)
        XCTAssertEqual(opened, [
            DeepLink(bundleID: "com.example.notes", applicationName: "Notes Example",
                     url: URL(string: "notes-example://search?q=plans")!),
            DeepLink(bundleID: "com.example.notes", applicationName: "Notes Example",
                     url: URL(string: "notes-example://note/new")!)
        ])

        let refusals: [(JSONValue, PluginHostServiceError)] = [
            (.object(["template": .string("delete-all")]), .capabilityDenied(.controlExternalApp)),
            (.string("notes-example://note/new"),
             .invalidInput("open_deep_link expects a template and optional parameters")),
            (.object(["template": .string("new"), "url": .string("notes-example://x")]),
             .invalidInput("open_deep_link expects a template and optional parameters")),
            (.object(["template": .string("search")]), .invalidInput("Deep Link Template search takes exactly: query"))
        ]
        for (input, expected) in refusals {
            XCTAssertThrowsError(try open(input), "\(input)") { error in
                XCTAssertEqual(error as? PluginHostServiceError, expected, "\(input)")
            }
        }
        XCTAssertEqual(opened.count, 2)
    }
}
