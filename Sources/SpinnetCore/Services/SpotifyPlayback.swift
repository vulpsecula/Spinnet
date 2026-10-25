import Foundation

/// The reviewed local Spotify read. No cloud API, devices or arbitrary script.
public enum SpotifyPlayback {
    public static let bundleID = "com.spotify.client"
    public static let readOperation = "playback"
    public static let sourceMember = PluginInterfaceMember.source("apps.perform")
    public static func project(state: String, position: Double, track: [String: JSONValue]?) throws -> JSONValue {
        guard ["playing", "paused", "stopped"].contains(state), position.isFinite, position >= 0 else {
            throw PluginHostServiceError.failed("Spotify returned invalid playback state")
        }
        var output: [String: JSONValue] = ["state": .string(state), "position": .number(min(position, 604800)), "track": .null]
        if let track {
            var bounded: [String: JSONValue] = [:]
            for key in ["id", "name", "artist", "album"] {
                if case .string(let value)? = track[key] {
                    let clean = String(String.UnicodeScalarView(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
                    bounded[key] = .string(String(clean.prefix(512)))
                }
            }
            if case .number(let duration)? = track["duration"], duration.isFinite, duration >= 0 {
                // Spotify's deployed dictionary says seconds, but its desktop
                // implementation returns milliseconds. Public output is seconds.
                bounded["duration"] = .number(min(duration / 1000, 604800))
            }
            if case .string(let address)? = track["artwork_url"], address.utf8.count <= 2048,
               let url = URL(string: address), url.scheme == "https", url.host == "i.scdn.co", url.user == nil, url.password == nil,
               url.port == nil || url.port == 443 {
                bounded["artwork_url"] = .string(address)
            }
            output["track"] = .object(bounded)
        }
        return .object(output)
    }
    public static func validateSource(_ input: JSONValue) throws {
        guard case .object(let fields) = input, fields["bundle_id"] == .string(bundleID), fields["operation"] == .string(readOperation),
              Set(fields.keys).isSubset(of: ["bundle_id", "operation", "arguments"]), fields["arguments"] == nil || fields["arguments"] == .object([:]) else {
            throw PluginHostServiceError.invalidInput("apps.perform sources offer only Spotify playback without arguments")
        }
    }
}

public enum ReviewedAppReadFailure: String, Equatable {
    case notRunning = "external_app_not_running"
    case permissionNeeded = "automation_permission_needed"
    public var message: String {
        switch self {
        case .notRunning: return "Open Spotify, then refresh the playback panel"
        case .permissionNeeded: return "Choose Connect Spotify to allow Automation access"
        }
    }
}
