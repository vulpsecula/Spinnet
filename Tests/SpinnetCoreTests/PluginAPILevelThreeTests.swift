import Foundation
import XCTest
import SpinnetCore

/// Bundled packages declare stable Level 3 and receive only the proved additions.
final class PluginAPILevelThreeTests: XCTestCase {
    private func manifest(level: Int, candidate: CandidateContractRevision? = nil) throws -> PluginManifest {
        var value: [String: JSONValue] = ["protocol_version": .string("1.0"), "api_level": .number(Double(level)),
            "id": .string("com.example.stable-proof"), "name": .string("Stable proof"), "version": .string("1.0"),
            "commands": .array([.object(["id": .string("show"), "title": .string("Show"),
                "execution": .string("javascript"), "script": .string("show.js")])])]
        if let candidate { value["candidate_contracts"] = .array([.object(["name": .string(candidate.name), "revision": .number(Double(candidate.revision))])]) }
        return try PluginManifestLoader.decode(JSONEncoder().encode(value))
    }

    func testBundledStablePackageCanPresentTheProvedAdaptiveViewport() throws {
        let manifest = try manifest(level: 3)
        try PluginInterfaceContracts.host.check(manifest, origin: .bundled)
        let page = try PluginPage(parsing: AdaptiveViewportContractTests.page(), permits: PluginInterfaceContracts.host.permitting(manifest))
        XCTAssertEqual(page.inputs.map(\.id), ["note"])
        XCTAssertThrowsError(try PluginPage(parsing: AdaptiveViewportContractTests.page(),
            permits: PluginInterfaceContracts.host.permitting(self.manifest(level: 2))))
    }
    func testRetiredDeclarationsNameTheStableMigrationAndGrantNoMembers() throws {
        for declaration in [CandidateContractRevision(name: "adaptive_layout", revision: 1),
            .init(name: "adaptive_layout", revision: 2), .init(name: "spotify_controls", revision: 1),
            .init(name: "external_app_connections", revision: 1), .init(name: "homebrew_autoremove", revision: 1)] {
            let retired = try manifest(level: 2, candidate: declaration)
            XCTAssertThrowsError(try PluginInterfaceContracts.host.check(retired, origin: .installed)) {
                XCTAssertEqual($0 as? CandidateContractRefusal,
                    .retired(plugin: "Stable proof", declared: declaration, promotedToLevel: 3))
                XCTAssertTrue($0.localizedDescription.contains("declares Level 3 instead"))
            }
            XCTAssertFalse(PluginInterfaceContracts.host.permits(.viewComponent("adaptive"), declaredBy: retired))
            XCTAssertFalse(PluginInterfaceContracts.host.permits(.behaviour("spotify_controls"), declaredBy: retired))
        }
    }

}
