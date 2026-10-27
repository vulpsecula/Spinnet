import XCTest
import SpinnetCore
@testable import SpinnetReviewedTools

/// Retired private execution refuses before launch; installed history remains data-only.
final class HomebrewSourceReadTests: XCTestCase {
    func testPrivateInspectionRejectsChangedLoaderBeforeItsBootstrapCanEvaluateIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("bin/brew")
        let library = root.appendingPathComponent("Library/Homebrew")
        let marker = root.appendingPathComponent("bootstrap-evaluated")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try Data("raise 'UNREVIEWED_BOOTSTRAP_EVALUATED'".utf8).write(to: library.appendingPathComponent("formulary.rb"))
        try Data("""
        #!/bin/sh
        /usr/bin/touch '\(marker.path)'
        printf '%s\\n' '{"formulae":[{"name":"example","tap":"homebrew/core","versions":{"stable":"bootstrap-evaluated"}}],"casks":[]}'
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let profile = HomebrewReadProfile(executable: { executable }, execute: HomebrewReadProfile.execute)
        XCTAssertThrowsError(try profile.read(.object(["tool": .string("homebrew"), "operation": .string("info"), "kind": .string("formula"), "names": .array([.string("example")])]), owner: PluginID("bootstrap-tracer"))) { error in
            guard case .unavailable(let reason) = error as? PluginHostServiceError else { return XCTFail("Expected prelaunch retirement refusal: \(error)") }
            XCTAssertTrue(reason.contains("retired"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "A refused private read must never start the executable")
    }

    func testInstalledHistoryIsDataOnlyAndCannotFallBackToRuby() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("installed-ruby-evaluated")
        let ruby = "File.write('\(marker.path)', 'unexpected execution')\nraise 'INSTALLED_JSON_EVALUATED_AS_RUBY'"
        let receiptArtifacts: [[String: Any]] = [["uninstall": [["pkgutil": "org.example.receipt"]]]]
        let definitionArtifacts: [[String: Any]] = [["uninstall": [["pkgutil": "org.example.definition"]]]]

        func install(_ token: String, definition: String?, artifacts: [[String: Any]]? = nil, flightBlocks: Bool = false) throws {
            let metadata = root.appendingPathComponent("Caskroom/\(token)/.metadata")
            let casks = metadata.appendingPathComponent("1.2.3/20261025000000.000/Casks")
            try FileManager.default.createDirectory(at: casks, withIntermediateDirectories: true)
            var receipt: [String: Any] = ["source": ["version": "1.2.3", "tap": "homebrew/cask"], "uninstall_flight_blocks": flightBlocks]
            if let artifacts { receipt["uninstall_artifacts"] = artifacts }
            try JSONSerialization.data(withJSONObject: receipt).write(to: metadata.appendingPathComponent("INSTALL_RECEIPT.json"))
            // Every case has executable-looking Ruby; it is never a fallback.
            try Data(ruby.utf8).write(to: casks.appendingPathComponent(token + ".rb"))
            if let definition { try Data(definition.utf8).write(to: casks.appendingPathComponent(token + ".json")) }
        }
        func assertNotExecuted(_ context: String) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), context)
        }

        // A present but invalid JSON definition must not fall back to either
        // the valid receipt artifacts or the adjacent executable Ruby recipe.
        for (label, payload) in [("null", "null"), ("array", "[]"), ("scalar", "42"), ("malformed", ruby)] {
            let token = "history-" + label
            try install(token, definition: payload, artifacts: receiptArtifacts)
            XCTAssertThrowsError(try HomebrewInstalledUninstall.read(name: token, prefix: root.path), label)
            assertNotExecuted(label)
        }

        let definition: [String: Any] = ["token": "history-json", "artifacts": definitionArtifacts]
        let definitionBytes = try JSONSerialization.data(withJSONObject: definition)
        try install("history-json", definition: String(decoding: definitionBytes, as: UTF8.self), artifacts: receiptArtifacts)
        let jsonRecord = try HomebrewInstalledUninstall.read(name: "history-json", prefix: root.path)
        XCTAssertEqual(jsonRecord.version, "1.2.3")
        XCTAssertEqual(jsonRecord.tap, "homebrew/cask")
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: jsonRecord.artifacts, options: .sortedKeys),
                       try JSONSerialization.data(withJSONObject: definitionArtifacts, options: .sortedKeys))
        assertNotExecuted("Valid installed JSON remains data")

        try install("history-ruby", definition: nil)
        XCTAssertThrowsError(try HomebrewInstalledUninstall.read(name: "history-ruby", prefix: root.path)) { error in
            guard case .unavailable(let reason) = error as? PluginHostServiceError else { return XCTFail("Expected missing exact installed artifacts to be refused: \(error)") }
            XCTAssertTrue(reason.contains("No exact installed uninstall artifacts"))
        }
        assertNotExecuted("Ruby alone cannot supply installed artifacts")

        // Receipts can independently record exact data without a JSON recipe.
        // Their presence authorizes reading that data, never executing Ruby.
        try install("history-receipt", definition: nil, artifacts: receiptArtifacts)
        let receiptRecord = try HomebrewInstalledUninstall.read(name: "history-receipt", prefix: root.path)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: receiptRecord.artifacts, options: .sortedKeys),
                       try JSONSerialization.data(withJSONObject: receiptArtifacts, options: .sortedKeys))
        assertNotExecuted("Receipt artifacts remain data")

        try install("history-flight", definition: nil, artifacts: receiptArtifacts, flightBlocks: true)
        XCTAssertThrowsError(try HomebrewInstalledUninstall.read(name: "history-flight", prefix: root.path)) { error in
            guard case .unavailable(let reason) = error as? PluginHostServiceError else { return XCTFail("Expected executable installed history to be refused: \(error)") }
            XCTAssertTrue(reason.contains("executable uninstall history"))
        }
        assertNotExecuted("Executable flight blocks cannot be substituted with receipt data")
    }
}
