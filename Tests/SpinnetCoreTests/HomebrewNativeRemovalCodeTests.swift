import XCTest
import SpinnetCore
import Darwin

final class HomebrewNativeRemovalCodeTests: XCTestCase {
    func testIndependentlySignedOldVersionSourceFreezesOnlyDeclaredActions() throws {
        let envelope = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/Homebrew/api/internal/packages.arm64_golden_gate.jws.json")
        let evidence = try HomebrewSignedCaskCatalog.load(envelope, deadline: Date().addingTimeInterval(5))
        let configuration = try HomebrewSignedCaskCatalog.Configuration(languages: [], home: URL(fileURLWithPath: NSHomeDirectory()), prefix: URL(fileURLWithPath: "/opt/homebrew"), appDirectory: URL(fileURLWithPath: "/Applications"))
        let metadata = try evidence.catalog.project("adobe-air", configuration: configuration)
        guard case .string(let version)? = metadata["version"] else { return XCTFail("missing actual signed version") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spinnet-old-source-" + UUID().uuidString)
        try NativeFileQuarantine.makePrivateDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let heldEnvelope = directory.appendingPathComponent("homebrew-source.jws.json")
        try evidence.envelope.write(to: heldEnvelope)
        let proof = HomebrewPrivilegePlan.SourceProof(envelope: heldEnvelope, envelopeSHA256: evidence.catalog.envelopeSHA256,
            projectionSHA256: try evidence.catalog.projectionDigest("adobe-air", configuration: configuration), configuration: configuration)
        let selection = try HomebrewNativeRemovalCode.selectSource(proof: proof, name: "homebrew/cask/adobe-air", installedVersion: version, includeZap: false, deadline: Date().addingTimeInterval(5))
        XCTAssertEqual(selection.actions.first?.script.arguments, ["-uninstall"])
        XCTAssertEqual(selection.actions.first?.script.phase, .uninstall)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let fields: [String: Any] = ["fileURL": directory.appendingPathComponent("native-payload-fixture.archive").absoluteString,
            "sha256": selection.publishedSHA256, "sourceURL": selection.sourceURL.absoluteString, "byteCount": 1,
            "sourceSHA256": proof.envelopeSHA256, "projectionSHA256": proof.projectionSHA256,
            "configurationSHA256": HomebrewSystemAuthorization.digest(try encoder.encode(configuration))]
        let download = try JSONDecoder().decode(HomebrewNoCheckSnapshot.Result.self, from: JSONSerialization.data(withJSONObject: fields))
        let grant = try HomebrewNativeRemovalCode.freeze(selection, download: download)
        let cask = HomebrewPrivilegePlan.Cask(name: selection.name, version: version, sha256: "", packages: [], removalCode: grant)
        let plan = try HomebrewPrivilegePlan(taskID: "activity_old_code", prefix: "/opt/homebrew", casks: [cask], operation: "uninstall")
        XCTAssertTrue(plan.requiresSystemAuthorization)
        try plan.validate(.init(taskID: plan.taskID, package: cask.name, operation: .executeRemovalCode, source: "0", sha256: download.sha256))
        XCTAssertThrowsError(try plan.validate(.init(taskID: plan.taskID, package: cask.name, operation: .executeRemovalCode, source: "00", sha256: download.sha256)))
        XCTAssertThrowsError(try plan.validate(.init(taskID: plan.taskID, package: cask.name, operation: .executeRemovalCode, source: "0", sha256: String(repeating: "a", count: 64))))
        var changed = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(grant)) as? [String: Any])
        var actions = try XCTUnwrap(changed["actions"] as? [[String: Any]])
        var script = try XCTUnwrap(actions[0]["script"] as? [String: Any]); script["arguments"] = ["--unreviewed"]
        actions[0]["script"] = script; changed["actions"] = actions
        let forged = try JSONDecoder().decode(HomebrewNativeRemovalCode.Grant.self, from: JSONSerialization.data(withJSONObject: changed))
        XCTAssertTrue(forged.valid) // Structural validity grants no publisher authority.
        XCTAssertThrowsError(try forged.verify(owner: getuid(), prefix: "/opt/homebrew", deadline: Date().addingTimeInterval(5)))
        XCTAssertThrowsError(try HomebrewNativeRemovalCode.selectSource(proof: proof, name: "homebrew/cask/adobe-air", installedVersion: "unrelated-old-version", includeZap: false, deadline: Date().addingTimeInterval(5)))
        XCTAssertThrowsError(try HomebrewNativeRemovalCode.selectSource(proof: proof, name: "homebrew/cask/not-adobe-air", installedVersion: version, includeZap: false, deadline: Date().addingTimeInterval(5)))
        // Inventing an archive-origin proof cannot make an unrelated installed
        // program part of the independently signed source grant.
        changed = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(grant)) as? [String: Any])
        changed["origins"] = [["kind": "publisherChecksum", "token": "unrelated", "version": version,
            "sourceSHA256": proof.envelopeSHA256, "projectionSHA256": proof.projectionSHA256,
            "configurationSHA256": download.configurationSHA256, "downloadSHA256": download.sha256,
            "recipeExecutable": "/unrelated", "archiveTreeSHA256": String(repeating: "a", count: 64),
            "resourceDirectory": "original", "expandedBytes": 1, "expandedEntries": 1,
            "match": ["member": "unrelated", "resolvedMember": "unrelated", "executableSHA256": String(repeating: "a", count: 64),
                "resourceTreeSHA256": String(repeating: "a", count: 64),
                "installed": ["device": 1, "inode": 2, "mode": 33152, "owner": 501, "group": 20, "links": 1, "size": 1,
                    "sha256": String(repeating: "a", count: 64), "directory": false, "modifiedSeconds": 0, "modifiedNanoseconds": 0,
                    "aclSHA256": String(repeating: "a", count: 64), "writableACL": false]]]]
        let unrelated = try JSONDecoder().decode(HomebrewNativeRemovalCode.Grant.self, from: JSONSerialization.data(withJSONObject: changed))
        XCTAssertThrowsError(try unrelated.verify(owner: getuid(), prefix: "/opt/homebrew", deadline: Date().addingTimeInterval(5)))
    }
}
