import XCTest
import SpinnetCore
@testable import SpinnetHost

final class SpotifyNativeTests: XCTestCase {
    func testInstalledSpotifyReadNeverPromptsOrLaunches() throws {
        let request = try XCTUnwrap(ReviewedAppInterface.interface(for: SpotifyPlayback.bundleID)).request(operation: "playback", arguments: [:])
        do {
            let result = try SpotifyAppleEvents().perform(request, allowsPrompt: false)
            XCTAssertNotNil(result.value(atPointer: "/state"))
            XCTAssertNotNil(result.value(atPointer: "/position"))
            print("SPOTIFY_NATIVE_READ: \(result)")
        } catch PluginHostServiceError.appRead(let reason) {
            throw XCTSkip("Safe native preflight: \(reason.rawValue); user Automation/Spotify state required for values")
        } catch PluginHostServiceError.automationPermissionDenied {
            throw XCTSkip("Safe native preflight: automation_permission_denied; user System Permission required")
        } catch PluginHostServiceError.externalAppMissing {
            throw XCTSkip("Safe native preflight: external_app_missing")
        }
    }
}
