import XCTest

/// The architecture guard (#49): the Host's modules under `Sources/` do not
/// name the Plugin IDs, Command IDs or External App bundle IDs that the
/// manifests in `Plugins/` declare. Plugin behaviour belongs in the Plugin
/// (ADR 0009).
///
/// Every occurrence the Host still has is listed below, per file and literal,
/// with the reason it may stay or the W ticket under #47 that removes it. The
/// list may only shrink: a new occurrence fails, and so does an exception
/// that no longer matches what it excuses.
final class ArchitectureGuardTests: XCTestCase {
    private static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static let exceptions: [ArchitectureGuard.Exception] = [
        // Bob's Apple Events go to the adapter that sends its `request`
        // handler; W8 turns that adapter into Bob's Reviewed App Interface.
        .init("Sources/SpinnetHost/main.swift", "com.hezongyidev.Bob", .reviewedAppInterface),

        // The bundle-ID switches in the broker, the registry and the External
        // App invoker, Shottr's route table and its URL scheme adapter give
        // way to a Reviewed App Interface and Deep Link Templates.
        .init("Sources/SpinnetCore/PluginCapabilities.swift", "com.hezongyidev.Bob", .removedBy("W8 #55")),
        .init("Sources/SpinnetCore/PluginCapabilities.swift", "cc.ffitch.shottr", count: 2, .removedBy("W8 #55")),
        .init("Sources/SpinnetCore/PluginRegistry.swift", "com.hezongyidev.Bob", .removedBy("W8 #55")),
        .init("Sources/SpinnetCore/PluginRegistry.swift", "cc.ffitch.shottr", count: 2, .removedBy("W8 #55")),
        .init("Sources/SpinnetHost/main.swift", "cc.ffitch.shottr", .removedBy("W8 #55")),
        .init("Sources/SpinnetHost/ShottrURLSchemeAdapter.swift", "cc.ffitch.shottr", .removedBy("W8 #55")),
        .init("Sources/SpinnetCore/ShottrCaptureRequest.swift", "shottr.capture_area", .removedBy("W8 #55")),
        .init("Sources/SpinnetCore/ShottrCaptureRequest.swift", "shottr.capture_fullscreen", .removedBy("W8 #55")),
        .init("Sources/SpinnetCore/ShottrCaptureRequest.swift", "shottr.capture_window", .removedBy("W8 #55")),
        .init("Sources/SpinnetCore/ShottrCaptureRequest.swift", "shottr.capture_repeat_area", .removedBy("W8 #55")),
        .init("Sources/SpinnetCore/ShottrCaptureRequest.swift", "shottr.capture_scrolling", .removedBy("W8 #55")),
        .init("Sources/SpinnetCore/ShottrCaptureRequest.swift", "shottr.capture_scrolling_reverse",
              .removedBy("W8 #55")),
        .init("Sources/SpinnetCore/ShottrCaptureRequest.swift", "shottr.capture_delayed", .removedBy("W8 #55")),
        .init("Sources/SpinnetCore/ShottrCaptureRequest.swift", "shottr.append_capture", .removedBy("W8 #55")),

        // Translator's version 1 to 2 migration becomes manifest `migrations`.
        .init("Sources/SpinnetHost/TranslatorCommandMigration.swift", "com.spinnet.translator", .removedBy("W5 #52")),
        .init("Sources/SpinnetHost/TranslatorCommandMigration.swift", "translator.selection", .removedBy("W5 #52")),
        .init("Sources/SpinnetHost/TranslatorCommandMigration.swift", "translator.input", .removedBy("W5 #52"))
    ]

    func testHostModulesNameNoPluginSpecificLiteralsBeyondTheExceptions() throws {
        let declared = try declaredLiterals()
        let sources = try hostSources()
        XCTAssertGreaterThanOrEqual(Set(declared.map(\.pluginID)).count, 6, "the manifests were not found")
        XCTAssertFalse(sources.isEmpty, "the Host's sources were not found")

        for violation in ArchitectureGuard.violations(declared: declared, sources: sources,
                                                      exceptions: Self.exceptions) {
            XCTFail(violation)
        }
    }

    private func declaredLiterals() throws -> [ArchitectureGuard.DeclaredLiteral] {
        let plugins = Self.repository.appendingPathComponent("Plugins")
        return try FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)
            .map { $0.appendingPathComponent("manifest.json") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.path < $1.path }
            .flatMap { try ArchitectureGuard.declaredLiterals(inManifest: Data(contentsOf: $0)) }
    }

    /// Every Swift file under `Sources/`, keyed by its path from the
    /// repository root.
    private func hostSources() throws -> [String: String] {
        let root = Self.repository.appendingPathComponent("Sources").standardizedFileURL
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        var sources: [String: String] = [:]
        for file in files {
            let relative = String(file.standardizedFileURL.path.dropFirst(root.path.count + 1))
            sources["Sources/" + relative] = try String(contentsOf: file, encoding: .utf8)
        }
        return sources
    }
}

/// The scanner behind the architecture guard, run against source trees held
/// in memory.
final class ArchitectureGuardScannerTests: XCTestCase {
    private let bob = [
        ArchitectureGuard.DeclaredLiteral(text: "com.spinnet.bob", kind: .pluginID, pluginID: "com.spinnet.bob")
    ]

    func testPluginIDInAGeneralHostModuleIsReported() {
        let violations = ArchitectureGuard.violations(
            declared: bob,
            sources: ["Sources/SpinnetCore/Broker.swift": #"let bob = PluginID("com.spinnet.bob")"#],
            exceptions: []
        )

        XCTAssertEqual(violations, [
            #"Sources/SpinnetCore/Broker.swift names "com.spinnet.bob", the Plugin ID of com.spinnet.bob, 1 time "#
                + "where its exceptions allow 0. Keep Plugin behaviour in the Plugin rather than in a general "
                + "Host module (ADR 0009)."
        ])
    }

    func testExceptionCoversExactlyItsCountInItsFile() {
        let exception = ArchitectureGuard.Exception(
            "Sources/SpinnetCore/Broker.swift", "com.spinnet.bob", count: 1, .removedBy("W8 #55")
        )
        let once = #"let bob = PluginID("com.spinnet.bob")"#
        let twice = once + "\n" + #"let again = PluginID("com.spinnet.bob")"#

        XCTAssertEqual(ArchitectureGuard.violations(
            declared: bob, sources: ["Sources/SpinnetCore/Broker.swift": once], exceptions: [exception]
        ), [])
        XCTAssertEqual(ArchitectureGuard.violations(
            declared: bob, sources: ["Sources/SpinnetCore/Broker.swift": twice], exceptions: [exception]
        ).count, 1, "a new occurrence in an excepted file must fail")
        XCTAssertEqual(ArchitectureGuard.violations(
            declared: bob,
            sources: ["Sources/SpinnetCore/Broker.swift": once, "Sources/SpinnetHost/Other.swift": once],
            exceptions: [exception]
        ).count, 1, "an exception covers only its own file")
    }

    func testExceptionThatNoLongerMatchesIsReportedAsStale() {
        let exception = ArchitectureGuard.Exception(
            "Sources/SpinnetCore/Broker.swift", "com.spinnet.bob", count: 2, .removedBy("W8 #55")
        )
        let once = #"let bob = PluginID("com.spinnet.bob")"#

        let fewer = ArchitectureGuard.violations(
            declared: bob, sources: ["Sources/SpinnetCore/Broker.swift": once], exceptions: [exception]
        )
        let gone = ArchitectureGuard.violations(declared: bob, sources: [:], exceptions: [exception])

        XCTAssertEqual(fewer, [
            #"The exception for "com.spinnet.bob" in Sources/SpinnetCore/Broker.swift (removed by W8 #55) "#
                + "allows 2 but finds 1. The list may only shrink: lower its count to 1."
        ])
        XCTAssertEqual(gone, [
            #"The exception for "com.spinnet.bob" in Sources/SpinnetCore/Broker.swift (removed by W8 #55) "#
                + "allows 2 but finds 0. The list may only shrink: delete it."
        ])
    }

    func testFileAndLiteralTakeOneException() {
        let exception = ArchitectureGuard.Exception(
            "Sources/SpinnetCore/Broker.swift", "com.spinnet.bob", .removedBy("W8 #55")
        )

        XCTAssertEqual(ArchitectureGuard.violations(
            declared: bob,
            sources: ["Sources/SpinnetCore/Broker.swift": #"let bob = PluginID("com.spinnet.bob")"#],
            exceptions: [exception, exception]
        ), [#"The exception for "com.spinnet.bob" in Sources/SpinnetCore/Broker.swift is listed 2 times; "#
            + "keep one and give it the count."])
    }

    func testManifestDeclaresItsPluginCommandAndExternalAppIDs() throws {
        let manifest = Data(#"""
        {
          "api_level": 1,
          "id": "com.example.bob",
          "future_field": {"anything": true},
          "capability_scopes": [
            {"capability": "read_selected_text", "external_apps": []},
            {"capability": "control_external_app", "external_apps": [{"bundle_id": "com.example.Bob"}]}
          ],
          "commands": [{"id": "bob.translate"}, {"id": "bob.capture"}]
        }
        """#.utf8)

        let declared = try ArchitectureGuard.declaredLiterals(inManifest: manifest)

        XCTAssertEqual(declared.map(\.text), ["com.example.bob", "bob.translate", "bob.capture", "com.example.Bob"])
        XCTAssertEqual(declared.map(\.kind), [.pluginID, .commandID, .commandID, .externalAppBundleID])
        XCTAssertEqual(Set(declared.map(\.pluginID)), ["com.example.bob"])
        XCTAssertEqual(try ArchitectureGuard.declaredLiterals(inManifest: Data(#"{"id": "com.example.bare"}"#.utf8))
            .map(\.text), ["com.example.bare"])
    }

    func testOnlyWholeLiteralsInStringLiteralsCount() {
        let center = [
            ArchitectureGuard.DeclaredLiteral(text: "window.center", kind: .commandID,
                                              pluginID: "com.spinnet.window-position")
        ]
        func count(_ source: String) -> Int {
            ArchitectureGuard.violations(declared: center, sources: ["Sources/SpinnetHost/A.swift": source],
                                         exceptions: []).count
        }

        XCTAssertEqual(count("window.center()"), 0, "member access is not a Command ID")
        XCTAssertEqual(count(#"// Runs "window.center" when chosen"#), 0)
        XCTAssertEqual(count(#"/* "window.center" /* nested */ "window.center" */ let a = 1"#), 0)
        XCTAssertEqual(count(#"let queue = "window.center-queue""#), 0)
        XCTAssertEqual(count(#"let other = "window.center_third""#), 0)
        XCTAssertEqual(count(#"let other = "app.window.center""#), 0)

        XCTAssertEqual(count(#"let id = "window.center""#), 1)
        XCTAssertEqual(count(#"let id = "Run window.center." + "#), 1)
        XCTAssertEqual(count(#"let id = "WINDOW.CENTER""#), 1, "IDs differing only in case still name the Command")
        XCTAssertEqual(count(##"let id = #"window.center"#"##), 1)
        XCTAssertEqual(count("let id = \"\"\"\n    window.center\n    \"\"\""), 1)
        XCTAssertEqual(count(#"let id = "\(prefix)window.center""#), 1)
        XCTAssertEqual(count(#"let id = "\(flag ? "window.center" : "other")""#), 1)
        XCTAssertEqual(count(#"let a = "\"", b = "window.center""#), 1, "an escaped quote does not end a literal")
    }
}
