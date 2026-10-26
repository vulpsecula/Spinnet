import XCTest
import SpinnetCore

final class ReviewedToolConsentTests: XCTestCase {
    private func manifest(operations: [String]) throws -> PluginManifest {
        let choices = operations.map { "\"\($0)\"" }.joined(separator: ",")
        return try PluginManifestLoader.decode(Data("""
        {"protocol_version":"1.0","engines":{"spinnet":"^1.0.0"},"id":"example.reviewed-consent","name":"Reviewed Consent","version":"1.0",
        "capabilities":["read_reviewed_tools"],
        "capability_scopes":[{"capability":"read_reviewed_tools","command_ids":["show"],"data_types":[],"includes_existing_host_data":false,"https_hosts":[],"external_apps":[],"reviewed_tools":[{"tool":"homebrew","operations":[\(choices)],"kinds":["formula"]}]}],
        "commands":[{"id":"show","title":"Show","execution":"javascript","script":"show.js"}]}
        """.utf8))
    }

    func testRequiredReviewedReadGrantDisclosesInstalledInventoryDestination() throws {
        let disclosure = PluginPermissionDisclosure(manifest: try manifest(operations: ["vulnerabilities"]))
        let text = disclosure.details(for: .reads)
        XCTAssertTrue(text.contains("api.osv.dev"), "Required grants must disclose the actual external destination")
        XCTAssertTrue(text.contains("installed"), "The user must know which local data leaves the Mac")
        XCTAssertTrue(text.contains("versions"))
    }

    func testOfflineReviewedReadGrantDoesNotClaimInventoryWillBeSent() throws {
        let disclosure = PluginPermissionDisclosure(manifest: try manifest(operations: ["installed"]))
        let text = disclosure.details(for: .reads)
        XCTAssertFalse(text.contains("api.osv.dev"))
        XCTAssertFalse(text.contains("formulae.brew.sh"))
    }

    func testAdvisoryOnlyGrantDisclosesDestinationWithoutInstalledInventory() throws {
        let disclosure = PluginPermissionDisclosure(manifest: try manifest(operations: ["vulnerabilityDetail"]))
        let text = disclosure.details(for: .reads)
        XCTAssertTrue(text.contains("api.osv.dev"))
        XCTAssertFalse(text.contains("installed upstream"))
    }

    func testFormulaPreviewGrantDisclosesBottleMetadataDestination() throws {
        let disclosure = PluginPermissionDisclosure(manifest: try manifest(operations: ["previewInstall"]))
        let text = disclosure.details(for: .reads)
        XCTAssertTrue(text.contains("ghcr.io"))
        XCTAssertTrue(text.contains("selected"))
        XCTAssertFalse(text.contains("installed upstream"))
    }
}
