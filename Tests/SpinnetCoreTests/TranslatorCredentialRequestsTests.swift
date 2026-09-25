import XCTest
@testable import SpinnetCore

/// Pins what Translator's keyed sources put on the wire, byte for byte, so
/// moving their keys onto Credential Uses cannot change a request. The
/// Translator package runs through the real helper and broker; a transport
/// records what would have left the machine.
final class TranslatorCredentialRequestsTests: XCTestCase {
    private static let answers: [String: RoutedHTTPSTransport.Route] = [
        "api-free.deepl.com": RoutedHTTPSTransport.json(#"{"translations":[{"text":"Guten Morgen"}]}"#),
        "api.openai.com": RoutedHTTPSTransport.json(#"{"choices":[{"message":{"content":"Guten Morgen."}}]}"#)
    ]

    /// The requests Translator sends for "Good morning" into German with
    /// DeepL (formality on) and OpenAI turned on.
    private func sentRequests() throws -> [HTTPSTransportRequest] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let loaded = try PluginManifestLoader.load(packageAt: root.appendingPathComponent("Plugins/Translator.spinnetplugin"))
        let package = PluginPackage(rootURL: loaded.rootURL, manifest: loaded.manifest, origin: .bundled)
        let manifest = package.manifest
        let grants = PluginCapabilityGrantStore()
        for capability in manifest.capabilities {
            grants.setDecision(.granted, for: manifest.id, pluginVersion: manifest.version,
                               capability: capability, scope: manifest.scope(for: capability))
        }
        let registry = PluginRegistry(grantStore: grants, systemPermissionCheck: { _ in true })
        try registry.register(package)
        let credentials = InMemoryPluginCredentialStore()
        try credentials.setSecret("deepl-secret:fx", for: manifest.id, reference: "deepl")
        try credentials.setSecret("sk-openai-secret", for: manifest.id, reference: "openai")
        let stored: [String: JSONValue] = [
            "sources": .array([.string("DeepL"), .string("OpenAI")]), "source_language": .string("EN-US"),
            "target_language": .string("DE"), "auto_detect": .bool(false), "formality": .string("prefer_more"),
            "deepl_endpoint": .string("https://api-free.deepl.com"), "deepl_credential": .string("deepl"),
            "openai_endpoint": .string("https://api.openai.com/v1"), "openai_model": .string("gpt-test"),
            "openai_credential": .string("openai")
        ]
        let transport = RoutedHTTPSTransport(Self.answers)
        var session: ResultsPresentationSession?
        let broker = CapabilityCheckedHostServiceBroker(
            grantStore: grants, systemPermissionCheck: { _ in true },
            selectedTextProvider: { _ in "Good morning" }, clipboardWriter: { _ in },
            httpsTransport: transport, credentialStore: credentials,
            resultsPresenter: { session = $0 },
            pluginSettingsReader: { $0.resolvedSettings(stored: stored) }
        )
        let supervisor = PluginRuntimeSupervisor(helperURL: try XCTUnwrap(Self.helperURL()))
        defer { supervisor.shutdown() }
        let command = try XCTUnwrap(manifest.commands.first { $0.id.rawValue == "translator.selection" })
        let action = try ActionConfiguration(id: ActionID("translator.selection"), pluginID: manifest.id,
                                             command: command, input: .object([:]))
        let outcome = HostActionRunner(executor: NoHostCommands(), scriptedExecutor: supervisor,
                                       hostServiceBroker: broker,
                                       pluginSettings: { $0.resolvedSettings(stored: stored) })
            .invoke(action, using: registry).terminal
        guard case .succeeded = outcome else {
            XCTFail("Translator did not present: \(outcome)")
            return []
        }
        try XCTUnwrap(session).resolve(text: "Good morning", started: { _ in }, update: { _, _ in })
        return transport.requests.sorted { ($0.url.host ?? "") < ($1.url.host ?? "") }
    }

    /// The body exactly as sent. Its object members once followed a Swift
    /// dictionary's order, which changed between launches and even between
    /// two sends of the same request; they are sorted now, and every other
    /// byte is what it was.
    private func text(_ body: Data?) throws -> String {
        String(decoding: try XCTUnwrap(body), as: UTF8.self)
    }

    func testDeepLAndOpenAIRequestsAreUnchanged() throws {
        let requests = try sentRequests()
        XCTAssertEqual(requests.count, 2)
        let deepL = try XCTUnwrap(requests.first)
        let openAI = try XCTUnwrap(requests.last)

        XCTAssertEqual(deepL.method, "POST")
        XCTAssertEqual(deepL.url.absoluteString, "https://api-free.deepl.com/v2/translate")
        XCTAssertEqual(deepL.headers, ["Authorization": "DeepL-Auth-Key deepl-secret:fx",
                                       "Content-Type": "application/json"])
        XCTAssertEqual(try text(deepL.body),
                       #"{"formality":"prefer_more","target_lang":"DE","text":["Good morning"]}"#)
        XCTAssertEqual(deepL.maximumResponseBytes, HTTPSRequestBudgets.maximumResponseBodyBytes)

        XCTAssertEqual(openAI.method, "POST")
        XCTAssertEqual(openAI.url.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(openAI.headers, ["Authorization": "Bearer sk-openai-secret",
                                        "Content-Type": "application/json"])
        XCTAssertEqual(try text(openAI.body), #"{"messages":[{"content":"You are a translation engine. "#
            + #"Translate the text the user sends into German. Reply with the translation only, without quotes, "#
            + #"notes, or explanations, and keep its line breaks and formatting.","role":"system"},"#
            + #"{"content":"Good morning","role":"user"}],"model":"gpt-test"}"#)
    }

    private static func helperURL() -> URL? {
        if let value = ProcessInfo.processInfo.environment["SPINNET_PLUGIN_HELPER_URL"] {
            return FileManager.default.isExecutableFile(atPath: value) ? URL(fileURLWithPath: value) : nil
        }
        for bundle in Bundle.allBundles where bundle.bundleURL.pathExtension == "xctest" {
            let candidate = bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("SpinnetPluginHelper")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

private struct NoHostCommands: HostCommandExecutor {
    func execute(_ action: ActionConfiguration) throws -> JSONValue { .null }
}
