#if DEBUG
import AppKit
import SpinnetCore
import SwiftUI

/// Renders Host-rendered surfaces to PNGs so their layout can be looked at
/// without clicking through the app. Debug builds only; `--render-ui <dir>`
/// writes the images and exits before the Host sets anything up. Each surface
/// is drawn from a real window, so the images show real controls.
@MainActor
enum UIPreviewRenderer {
    static func renderIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--render-ui"), arguments.count > flag + 1 else { return false }
        let directory = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try renderPluginSettings(into: directory)
            try renderPopup(into: directory)
            FileHandle.standardError.write(Data("rendered into \(directory.path)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
            exit(1)
        }
        exit(0)
    }

    private static func translatorManifest() throws -> PluginManifest {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try PluginManifestLoader.load(
            packageAt: root.appendingPathComponent("Plugins/Translator.spinnetplugin")
        ).manifest
    }

    private static func renderPluginSettings(into directory: URL) throws {
        let manifest = try translatorManifest()
        let grants = PluginCapabilityGrantStore()
        let store = try PluginSettingsStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("SpinnetPreview-\(UUID().uuidString).json")
        )
        let model = PluginSettingsModel(
            manifest: manifest, store: store, credentialStore: InMemoryPluginCredentialStore(),
            approveConsent: { _, _ in },
            consent: { HTTPSEndpointConsent(manifest: manifest, settings: $0, grantStore: grants) },
            onSaved: {}
        )
        model.values["sources"] = .array([.string("Google"), .string("DeepL"), .string("OpenAI")])
        try inWindow(PluginSettingsForm(model: model).frame(width: 440).padding(12),
                     size: NSSize(width: 464, height: 760), named: "plugin-settings", in: directory)
    }

    private static func renderPopup(into directory: URL) throws {
        let answers = ["google": "早上好。你今天怎么样？",
                       "deepl": "早上好，你今天过得怎么样？",
                       "openai": "早安。今天过得如何？"]
        let presentation = try ResultsPresentation(serviceInput: .object([
            "title": .string("Translate"),
            "original": .string("Good morning. How are you today?"),
            "settings": .object(["keys": .array([.string("source_language"), .string("target_language"),
                                                 .string("auto_detect")]),
                                 "swap": .array([.string("source_language"), .string("target_language")])]),
            "sections": .array([section("Google", host: "google"), section("DeepL", host: "deepl"),
                                section("OpenAI · gpt-4.1-mini", host: "openai")])
        ]))
        let session = ResultsPresentationSession(
            presentation: presentation,
            send: { request, _ in
                guard case .object(let fields) = request, case .string(let url)? = fields["url"],
                      let answer = answers.first(where: { url.contains($0.key) })?.value else {
                    throw PluginHostServiceError.failed("The request to example.com failed")
                }
                return .object(["status": .number(200), "headers": .object([:]),
                                "body": .string(#"{"text":"\#(answer)"}"#)])
            },
            settings: {
                [.init(key: "source_language", title: "Input", kind: .choice, value: .string("EN-US"),
                       choices: [("EN-US", "English (American)"), ("ZH-HANS", "Simplified Chinese")]),
                 .init(key: "target_language", title: "Target", kind: .choice, value: .string("ZH-HANS"),
                       choices: [("EN-US", "English (American)"), ("ZH-HANS", "Simplified Chinese")]),
                 .init(key: "auto_detect", title: "Detect Direction", kind: .toggle, value: .bool(true), choices: [])]
            },
            swappableSettings: ("source_language", "target_language")
        )
        let model = ResultsPopupModel(session: session, copy: { _ in })
        model.start()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        try inWindow(ResultsPopupView(model: model), size: NSSize(width: 420, height: 460),
                     named: "translation-popup", in: directory)
    }

    private static func section(_ title: String, host: String) -> JSONValue {
        .object(["title": .string(title),
                 "request": .object(["method": .string("GET"),
                                     "url": .string("https://\(host).example.com/t")]),
                 "result_pointer": .string("/text")])
    }

    /// Draws a view to a PNG. Interactive controls come out as placeholders,
    /// which is enough to judge layout.
    private static func inWindow(_ view: some View, size: NSSize, named name: String, in directory: URL) throws {
        let renderer = ImageRenderer(
            content: view
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor))
        )
        renderer.scale = 2
        guard let image = renderer.nsImage, let data = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else {
            throw ConfigurationError.persistence("could not render \(name)")
        }
        try png.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
#endif
