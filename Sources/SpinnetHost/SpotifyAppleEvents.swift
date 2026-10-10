import AppKit
import Carbon
import SpinnetCore

/// Only Host-reviewed strings reach AppleScript. Sources preflight without
/// prompting and never launch the application. The timeout bounds Apple Events.
struct SpotifyAppleEvents {
    func perform(_ request: AppleEventRequest, allowsPrompt: Bool) throws -> JSONValue {
        guard request.bundleID == SpotifyPlayback.bundleID, request.argument.isEmpty,
              ["playback", "play", "pause", "previous", "next"].contains(request.handler) else {
            throw PluginHostServiceError.externalAppOperationUnsupported("Unsupported Spotify operation")
        }
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: SpotifyPlayback.bundleID) != nil else {
            throw PluginHostServiceError.externalAppMissing("Install Spotify to use this panel")
        }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: SpotifyPlayback.bundleID).isEmpty else {
            throw PluginHostServiceError.appRead(.notRunning)
        }
        let target = NSAppleEventDescriptor(bundleIdentifier: SpotifyPlayback.bundleID)
        let permission = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, allowsPrompt)
        switch permission {
        case noErr: break
        case OSStatus(-1744): throw PluginHostServiceError.appRead(.permissionNeeded)
        case OSStatus(-1743): throw PluginHostServiceError.automationPermissionDenied("Spotify")
        case OSStatus(-600): throw PluginHostServiceError.appRead(.notRunning)
        default: throw PluginHostServiceError.failed("Spotify Automation could not be checked (\(permission))")
        }
        guard let script = NSAppleScript(source: Self.source(request.handler)) else {
            throw PluginHostServiceError.externalAppOperationUnsupported("Spotify's scripting interface is unavailable")
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let number = (error["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue
            if number == -600 { throw PluginHostServiceError.appRead(.notRunning) }
            throw AppleEventSender.error(number: number, message: error["NSAppleScriptErrorMessage"] as? String, for: request)
        }
        guard request.handler == "playback" else { return .null }
        guard result.numberOfItems == 3, let state = result.atIndex(1)?.stringValue,
              let position = result.atIndex(2)?.stringValue.flatMap(Double.init) else {
            throw PluginHostServiceError.failed("Spotify returned an invalid playback answer")
        }
        var track: [String: JSONValue]?
        if let values = result.atIndex(3), values.numberOfItems == 6 {
            var fields: [String: JSONValue] = [:]
            for (index, key) in ["id", "name", "artist", "album", "duration", "artwork_url"].enumerated() {
                if let value = values.atIndex(index + 1)?.stringValue {
                    fields[key] = key == "duration" ? Double(value).map(JSONValue.number) : .string(value)
                }
            }
            track = fields
        }
        return try SpotifyPlayback.project(state: state, position: position, track: track)
    }
    private static func source(_ operation: String) -> String {
        let body: String
        switch operation {
        case "playback": body = """
        set playbackState to player state as text
        set playbackPosition to player position
        set trackValues to {}
        try
            set t to current track
            set trackValues to {id of t, name of t, artist of t, album of t, duration of t, artwork url of t}
        on error number -1728
            set trackValues to {}
        end try
        return {playbackState, playbackPosition, trackValues}
        """
        case "previous": body = "previous track"
        case "next": body = "next track"
        case "play": body = "play"
        default: body = "pause"
        }
        // Recheck inside the script so quitting after preflight cannot relaunch.
        return """
        if not (application id "com.spotify.client" is running) then error "Spotify is not running" number -600
        with timeout of 2 seconds
            tell application id "com.spotify.client"
                \(body)
            end tell
        end timeout
        """
    }
}
