import Foundation

/// The released Host version. The public compatibility grammar accepts only
/// three decimal components, without leading zeros, prereleases or build tags.
public struct HostVersion: Codable, Hashable, Comparable, CustomStringConvertible, Sendable {
    public static let currentString = "1.0.0"
    public static let current = try! HostVersion(currentString)

    public let major: UInt64
    public let minor: UInt64
    public let patch: UInt64
    public var rawValue: String { "\(major).\(minor).\(patch)" }
    public var description: String { rawValue }

    public init(_ text: String) throws {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw HostCompatibilityError.invalidVersion(text) }
        func component(_ part: Substring) throws -> UInt64 {
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  part.count == 1 || part.first != "0", let value = UInt64(part) else {
                throw HostCompatibilityError.invalidVersion(text)
            }
            return value
        }
        major = try component(parts[0])
        minor = try component(parts[1])
        patch = try component(parts[2])
    }

    private init(major: UInt64, minor: UInt64, patch: UInt64) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    fileprivate func caretUpperBound() throws -> HostVersion {
        func next(_ value: UInt64) throws -> UInt64 {
            guard value < UInt64.max else { throw HostCompatibilityError.invalidRange("^" + rawValue) }
            return value + 1
        }
        if major > 0 { return try Self(major: next(major), minor: 0, patch: 0) }
        if minor > 0 { return try Self(major: 0, minor: next(minor), patch: 0) }
        return try Self(major: 0, minor: 0, patch: next(patch))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A deliberately small range language: exact M.m.p or caret ^M.m.p.
/// A caret ends before the next nonzero component's incompatible increment:
/// ^1.2.3 < 2.0.0, ^0.2.3 < 0.3.0, and ^0.0.3 < 0.0.4.
/// Whitespace, comparison operators, wildcards, unions and pre/build versions
/// are unsupported and rejected rather than approximated.
public struct HostCompatibility: Codable, Hashable, Sendable {
    public static let current = try! HostCompatibility("^" + HostVersion.currentString)
    public let rawValue: String
    public let minimum: HostVersion
    public let exclusiveMaximum: HostVersion?

    public init(_ range: String) throws {
        let caret = range.hasPrefix("^")
        do {
            minimum = try HostVersion(caret ? String(range.dropFirst()) : range)
            exclusiveMaximum = caret ? try minimum.caretUpperBound() : nil
        } catch {
            throw HostCompatibilityError.invalidRange(range)
        }
        rawValue = range
    }

    public func contains(_ version: HostVersion) -> Bool {
        if let exclusiveMaximum { return version >= minimum && version < exclusiveMaximum }
        return version == minimum
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum HostCompatibilityError: Error, Equatable, LocalizedError {
    case invalidVersion(String)
    case invalidRange(String)

    public var errorDescription: String? {
        switch self {
        case .invalidVersion(let version):
            return "Invalid Spinnet version \(version). Use M.m.p with decimal components and no prerelease or build suffix."
        case .invalidRange(let range):
            return "Unsupported Spinnet compatibility range \(range). Use ^M.m.p or exact M.m.p; components must fit UInt64, without leading zeros, whitespace, prerelease or build suffix."
        }
    }
}

public struct UnsupportedPluginHostVersion: Error, Equatable, LocalizedError {
    public let pluginName: String
    public let requirement: HostCompatibility
    public let hostVersion: HostVersion

    public init(requiredBy manifest: PluginManifest, hostVersion: HostVersion = .current) {
        pluginName = manifest.name
        requirement = manifest.hostCompatibility
        self.hostVersion = hostVersion
    }

    public var errorDescription: String? {
        "\(pluginName) requires Spinnet \(requirement.rawValue), but this Host is \(hostVersion). Install a compatible Plugin revision or a Spinnet version in that range."
    }
}
