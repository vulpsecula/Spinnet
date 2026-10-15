import XCTest
import AppKit
import Carbon
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

extension SpotifyNativeTests {
    func testInstalledSpotifyVolumeReadNeverPromptsOrChangesVolume() throws {
        let request = try XCTUnwrap(ReviewedAppInterface.interface(for: SpotifyPlayback.bundleID)).request(operation: "volume",
            arguments: [:], candidateContracts: [SpotifyControls.declaration])
        do {
            let result = try SpotifyAppleEvents().perform(request, allowsPrompt: false)
            guard case .number(let volume)? = result.value(atPointer: "/volume") else { return XCTFail("Expected Spotify volume") }
            XCTAssertTrue((0...100).contains(volume)); XCTAssertEqual(volume.rounded(), volume)
            print("SPOTIFY_NATIVE_VOLUME_READ: \(result)")
        } catch PluginHostServiceError.appRead(let reason) {
            throw XCTSkip("Safe native preflight: \(reason.rawValue)")
        } catch PluginHostServiceError.automationPermissionDenied {
            throw XCTSkip("Safe native preflight: automation_permission_denied")
        } catch PluginHostServiceError.externalAppMissing {
            throw XCTSkip("Safe native preflight: external_app_missing")
        }
    }
}


extension SpotifyNativeTests {
    func testInstalledSpotifyStateAndNestedTrackIDReadWithNextSuppressed() throws {
        // Permission preflight and real GETs only. This is not a real Next test.
        let interface = try XCTUnwrap(ReviewedAppInterface.interface(for: SpotifyPlayback.bundleID))
        let volume = try interface.request(operation: "volume", arguments: [:], candidateContracts: [SpotifyControls.declaration])
        do { _ = try SpotifyAppleEvents().perform(volume, allowsPrompt: false) }
        catch PluginHostServiceError.appRead(let reason) { throw XCTSkip("Safe native preflight: \(reason.rawValue)") }
        catch PluginHostServiceError.automationPermissionDenied { throw XCTSkip("Safe native preflight: automation_permission_denied") }
        catch PluginHostServiceError.externalAppMissing { throw XCTSkip("Safe native preflight: external_app_missing") }
        let application = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: SpotifyPlayback.bundleID).first)
        var suppressed = 0
        let adapter = SpotifyControlAppleEvents(target: NSAppleEventDescriptor(processIdentifier: application.processIdentifier), send: { event, timeout in
            let eventID = event.attributeDescriptor(forKeyword: AEKeyword(keyEventIDAttr))?.typeCodeValue
            if eventID == 0x4e657874 { suppressed += 1; return .null() }
            XCTAssertEqual(eventID, AEEventID(kAEGetData))
            guard !application.isTerminated else { throw PluginHostServiceError.appRead(.notRunning) }
            return try event.sendEvent(options: [.waitForReply, .neverInteract, .init(rawValue: UInt(kAEDontReconnect))], timeout: timeout)
        })
        let result = try adapter.perform(interface.request(operation: "next_checked", arguments: [:], candidateContracts: [SpotifyControls.declaration]))
        XCTAssertTrue(["stopped", "no_current_track", "unconfirmed", "changed"].map(JSONValue.string).contains(result.value(atPointer: "/outcome") ?? .null))
        XCTAssertLessThanOrEqual(suppressed, 1)
        print("SPOTIFY_NATIVE_READ_ONLY_NEXT_SUPPRESSED: \(result)")
    }
}
