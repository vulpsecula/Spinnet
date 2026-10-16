import Foundation

/// Level 3 additions to Spotify's Reviewed App Interface. Stable Level 2
/// retains its original operations and result shapes.
public enum SpotifyControls {
    public static let declaration = CandidateContractRevision(name: "spotify_controls", revision: 1)
    public static let member = PluginInterfaceMember.behaviour("spotify_controls")
    public static let contract = CandidateContract(name: declaration.name, revision: declaration.revision,
        baseLevel: 2, members: [member], tag: "plugin-api-candidate/spotify_controls/r1")
    public static let operationNames: Set<String> = ["play_pause", "volume", "set_volume", "adjust_volume", "next_checked"]

    public static func family(for operation: String) -> String? {
        guard operationNames.contains(operation) else { return nil }
        return operation == "volume" ? "playback_read" : "playback_control"
    }

    /// Validates typed, finite, integral native input without accepting text or
    /// truncating fractions. The result is never AppleScript or shell source.
    public static func integerArgument(operation: String, arguments: [String: JSONValue]) throws -> Int? {
        let key: String
        let range: ClosedRange<Double>
        switch operation {
        case "set_volume": key = "volume"; range = 0...100
        case "adjust_volume": key = "delta"; range = -100...100
        default:
            guard operationNames.contains(operation), arguments.isEmpty else {
                throw PluginHostServiceError.invalidInput("Spotify \(operation) takes no arguments")
            }
            return nil
        }
        guard arguments.count == 1, case .number(let value)? = arguments[key],
              value.isFinite, value.rounded(.towardZero) == value, range.contains(value) else {
            throw PluginHostServiceError.invalidInput("Spotify \(operation) needs integer \(key) from \(Int(range.lowerBound)) to \(Int(range.upperBound))")
        }
        return Int(value)
    }
}
