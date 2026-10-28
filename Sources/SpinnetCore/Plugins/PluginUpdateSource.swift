import Foundation

/// The GitHub repository a Plugin declares as where newer versions of it are
/// published, written `"update_source": {"github": "owner/repo"}`. It grants
/// no authority: the Host accepts a Plugin Update from it only for the same
/// Plugin identity, after the user applies it.
public struct PluginUpdateSource: Codable, Hashable, Sendable, CustomStringConvertible {
    public let owner: String
    public let repository: String

    /// `owner/repo`, as written in the manifest.
    public var github: String { owner + "/" + repository }
    public var description: String { github }

    public init(github: String) throws {
        let parts = github.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, Self.isOwner(parts[0]), Self.isRepository(parts[1]) else {
            throw ConfigurationError.invalidManifest(
                "update_source.github must name a GitHub repository as owner/repo, not \(github)")
        }
        owner = parts[0]
        repository = parts[1]
    }

    /// Whether `other` names the same repository. GitHub ignores case in both.
    public func isSame(as other: PluginUpdateSource) -> Bool {
        owner.lowercased() == other.owner.lowercased() && repository.lowercased() == other.repository.lowercased()
    }

    private static func isOwner(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first, text.count <= 39, isAlphanumeric(first) else { return false }
        return text.unicodeScalars.allSatisfy { isAlphanumeric($0) || $0 == "-" }
    }

    private static func isRepository(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 100, text != ".", text != ".." else { return false }
        return text.unicodeScalars.allSatisfy { isAlphanumeric($0) || "._-".unicodeScalars.contains($0) }
    }

    fileprivate static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar))
    }

    private enum CodingKeys: String, CodingKey { case github }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.count == 1 else {
            throw ConfigurationError.invalidManifest("update_source declares only github")
        }
        try self.init(github: container.decode(String.self, forKey: .github))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(github, forKey: .github)
    }

    /// The release tag that publishes `version` of `pluginID`.
    public static func releaseTag(for pluginID: PluginID, version: String) -> String {
        "\(pluginID.rawValue)/v\(version)"
    }

    /// The release asset holding the zipped package of `pluginID`.
    public static func assetName(for pluginID: PluginID) -> String {
        "\(pluginID.rawValue).spinnetplugin.zip"
    }

    /// Whether `pluginID` can appear in a release tag and an asset name: ASCII
    /// letters, digits, `.`, `_` and `-`, starting with a letter or digit,
    /// without `..`, a trailing `.` or a trailing `.lock`.
    static func isTagSafe(_ pluginID: PluginID) -> Bool {
        let text = pluginID.rawValue
        guard let first = text.unicodeScalars.first, isAlphanumeric(first), text.last != ".",
              !text.contains(".."), !text.hasSuffix(".lock") else { return false }
        return text.unicodeScalars.allSatisfy { isAlphanumeric($0) || "._-".unicodeScalars.contains($0) }
    }
}

/// A Plugin version a Plugin Update compares: SemVer 2.0.0 without build
/// metadata. A prerelease sorts below its release, by SemVer precedence.
public struct PluginVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: UInt64
    public let minor: UInt64
    public let patch: UInt64
    public let prerelease: [String]
    public let description: String

    public init(_ text: String) throws {
        let invalid = ConfigurationError.invalidManifest(
            "Plugin version \(text) is not a SemVer version M.m.p with an optional -prerelease and no build metadata")
        let core: Substring
        if let dash = text.firstIndex(of: "-") {
            core = text[..<dash]
            let identifiers = text[text.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false)
            guard !identifiers.isEmpty, identifiers.allSatisfy(Self.isPrereleaseIdentifier) else { throw invalid }
            prerelease = identifiers.map(String.init)
        } else {
            core = Substring(text)
            prerelease = []
        }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw invalid }
        func number(_ part: Substring) throws -> UInt64 {
            guard Self.isNumeric(part), part.count == 1 || part.first != "0", let value = UInt64(part) else { throw invalid }
            return value
        }
        major = try number(parts[0])
        minor = try number(parts[1])
        patch = try number(parts[2])
        description = text
    }

    private static func isNumeric(_ part: Substring) -> Bool {
        !part.isEmpty && part.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func isPrereleaseIdentifier(_ part: Substring) -> Bool {
        guard !part.isEmpty, part.unicodeScalars.allSatisfy({ PluginUpdateSource.isAlphanumeric($0) || $0 == "-" }) else {
            return false
        }
        return !isNumeric(part) || part.count == 1 || part.first != "0"
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.major == rhs.major && lhs.minor == rhs.minor && lhs.patch == rhs.patch && lhs.prerelease == rhs.prerelease
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(major); hasher.combine(minor); hasher.combine(patch); hasher.combine(prerelease)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        // A release has precedence over any of its prereleases.
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true), (true, false): return false
        case (false, true): return true
        case (false, false): break
        }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            // Digit-only identifiers have no leading zeros, so the longer is
            // the larger number and equal lengths compare digit by digit,
            // exactly at any size.
            switch (isNumeric(Substring(left)), isNumeric(Substring(right))) {
            case (true, true):
                return left.utf8.count != right.utf8.count ? left.utf8.count < right.utf8.count
                    : left.utf8.lexicographicallyPrecedes(right.utf8)
            case (true, false): return true
            case (false, true): return false
            case (false, false): return left.utf8.lexicographicallyPrecedes(right.utf8)
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}
