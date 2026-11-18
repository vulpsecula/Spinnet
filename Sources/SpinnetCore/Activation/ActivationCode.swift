import CryptoKit
import Foundation

/// A verified Activation Code: proof, signed offline with Spinnet's private
/// key, that its holder bought an Official Build. It activates every Official
/// Build for good and carries no personal data.
public struct ActivationCode: Equatable, Sendable {
    public enum Edition: UInt8, Sendable {
        case lifetime = 1
    }

    /// The purchase's random serial, for support and refunds.
    public let serial: UInt64
    /// The UTC day the code was issued.
    public let issued: Date
    public let edition: Edition
    /// The code in its canonical form, as it is stored and shown.
    public let text: String

    /// The serial in four groups of hexadecimal digits.
    public var displaySerial: String {
        let hex = String(format: "%016llX", serial)
        return stride(from: 0, to: 16, by: 4).map {
            let start = hex.index(hex.startIndex, offsetBy: $0)
            return String(hex[start..<hex.index(start, offsetBy: 4)])
        }.joined(separator: "-")
    }

    static let formatVersion: UInt8 = 1
    /// Format version, serial, issue day and edition.
    static let payloadLength = 1 + 8 + 2 + 1
    static let signatureLength = 64
    /// Issue days count from 2026-01-01 UTC.
    static let epoch = Date(timeIntervalSince1970: 1_767_225_600)

    /// What the signature covers: the payload behind a fixed context, so a
    /// signature made by the same key for anything else never verifies.
    static func signedMessage(_ payload: Data) -> Data {
        Data("Spinnet Activation Code\u{0}".utf8) + payload
    }
}

public enum ActivationCodeError: Error, Equatable, Sendable {
    /// The text is not an Activation Code at all, such as a partial copy.
    case malformed
    /// A code from a newer Spinnet format this build cannot read.
    case unsupportedVersion
    /// Well formed, but not signed by Spinnet, or changed since.
    case signatureMismatch
}

/// Verifies Activation Codes against the public keys an Official Build
/// trusts, offline.
public struct ActivationCodeVerifier: Sendable {
    public let trustedKeys: [Curve25519.Signing.PublicKey]

    public init(trustedKeys: [Curve25519.Signing.PublicKey]) {
        self.trustedKeys = trustedKeys
    }

    /// The keys Spinnet's own Activation Codes are signed with. A key that
    /// is retired for new codes stays here so codes it signed keep working.
    public static let official = ActivationCodeVerifier(trustedKeys: officialPublicKeys.map {
        // A shipped key that does not parse is a build error, caught by tests.
        try! ActivationSigningKey.publicKey(from: $0)
    })

    static let officialPublicKeys: [String] = [
        // Signed by hand with SpinnetActivationSigner.
        "spinnet-activation-public-v1:AslGUy/jvJpKTkJ41x4d0g4M8cnD0vFVLT7wUpHk3z4=", // Not localized: a key
        // Signed by the website after a Paddle purchase (Spinnet-Website).
        "spinnet-activation-public-v1:py4/pusdA+IGLdzyugYryfqbQTsXu7A5qgpxdHaVWmU=" // Not localized: a key
    ]

    public func verify(_ input: String) throws -> ActivationCode {
        guard let bytes = ActivationCodeText.decode(input),
              bytes.count == ActivationCode.payloadLength + ActivationCode.signatureLength else {
            throw ActivationCodeError.malformed
        }
        let payload = bytes.prefix(ActivationCode.payloadLength)
        let signature = bytes.suffix(ActivationCode.signatureLength)
        guard payload[payload.startIndex] == ActivationCode.formatVersion else {
            throw ActivationCodeError.unsupportedVersion
        }
        let message = ActivationCode.signedMessage(Data(payload))
        guard trustedKeys.contains(where: { $0.isValidSignature(signature, for: message) }) else {
            throw ActivationCodeError.signatureMismatch
        }
        let fields = Array(payload)
        let serial = fields[1..<9].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let day = UInt16(fields[9]) << 8 | UInt16(fields[10])
        guard let edition = ActivationCode.Edition(rawValue: fields[11]) else {
            throw ActivationCodeError.unsupportedVersion
        }
        return ActivationCode(
            serial: serial,
            issued: ActivationCode.epoch.addingTimeInterval(TimeInterval(day) * 24 * 60 * 60),
            edition: edition,
            text: ActivationCodeText.format(bytes)
        )
    }
}

/// Signs Activation Codes. Only the signing tool holds a private key; the
/// Host never does.
public struct ActivationCodeSigner {
    public enum SigningError: Error, Equatable {
        case issueDayOutOfRange
    }

    private let privateKey: Curve25519.Signing.PrivateKey

    public init(privateKey: Curve25519.Signing.PrivateKey) {
        self.privateKey = privateKey
    }

    public func sign(serial: UInt64, issued: Date, edition: ActivationCode.Edition) throws -> String {
        let days = (issued.timeIntervalSince(ActivationCode.epoch) / (24 * 60 * 60)).rounded(.down)
        guard days >= 0, days <= Double(UInt16.max) else { throw SigningError.issueDayOutOfRange }
        let day = UInt16(days)
        var payload = Data([ActivationCode.formatVersion])
        payload += withUnsafeBytes(of: serial.bigEndian) { Data($0) }
        payload += withUnsafeBytes(of: day.bigEndian) { Data($0) }
        payload.append(edition.rawValue)
        let signature = try privateKey.signature(for: ActivationCode.signedMessage(payload))
        return ActivationCodeText.format(payload + signature)
    }
}

/// How signing keys are written in files and in source: a labelled base64
/// string of the raw key.
public enum ActivationSigningKey {
    public enum KeyError: Error, Equatable {
        case unreadable
    }

    private static let privatePrefix = "spinnet-activation-private-v1:"
    private static let publicPrefix = "spinnet-activation-public-v1:"

    public static func text(for key: Curve25519.Signing.PrivateKey) -> String {
        privatePrefix + key.rawRepresentation.base64EncodedString()
    }

    public static func text(for key: Curve25519.Signing.PublicKey) -> String {
        publicPrefix + key.rawRepresentation.base64EncodedString()
    }

    public static func privateKey(from text: String) throws -> Curve25519.Signing.PrivateKey {
        do { return try Curve25519.Signing.PrivateKey(rawRepresentation: raw(text, prefix: privatePrefix)) }
        catch { throw KeyError.unreadable }
    }

    public static func publicKey(from text: String) throws -> Curve25519.Signing.PublicKey {
        do { return try Curve25519.Signing.PublicKey(rawRepresentation: raw(text, prefix: publicPrefix)) }
        catch { throw KeyError.unreadable }
    }

    private static func raw(_ text: String, prefix: String) throws -> Data {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix), let data = Data(base64Encoded: String(trimmed.dropFirst(prefix.count))) else {
            throw KeyError.unreadable
        }
        return data
    }
}

/// The text form of an Activation Code: `SPN1-`, then Crockford base32 in
/// dash-separated groups, so it survives email, copying and typing.
enum ActivationCodeText {
    static let prefix = "SPN1"
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let groupLength = 6

    static func format(_ bytes: Data) -> String {
        var characters: [Character] = []
        var buffer = 0
        var bits = 0
        for byte in bytes {
            buffer = buffer << 8 | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                characters.append(alphabet[(buffer >> bits) & 31])
            }
            buffer &= (1 << bits) - 1
        }
        if bits > 0 { characters.append(alphabet[(buffer << (5 - bits)) & 31]) }
        let groups = stride(from: 0, to: characters.count, by: groupLength).map {
            String(characters[$0..<min($0 + groupLength, characters.count)])
        }
        return ([prefix] + groups).joined(separator: "-")
    }

    /// The bytes of typed or pasted text, ignoring case, spaces, dashes and
    /// line breaks, and reading I and L as 1 and O as 0. Nil when it is not
    /// a code's canonical bytes.
    static func decode(_ input: String) -> Data? {
        var text = input.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard text.hasPrefix(prefix) else { return nil }
        text.removeFirst(prefix.count)
        var bytes = Data()
        var buffer = 0
        var bits = 0
        for character in text {
            let normalized: Character
            switch character {
            case "I", "L": normalized = "1"
            case "O": normalized = "0"
            default: normalized = character
            }
            guard let value = alphabet.firstIndex(of: normalized) else { return nil }
            buffer = buffer << 5 | value
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((buffer >> bits) & 0xFF))
            }
            buffer &= (1 << bits) - 1
        }
        // Leftover bits are padding: there must be fewer than five, all zero,
        // so each code has exactly one text.
        guard bits < 5, buffer == 0, !bytes.isEmpty else { return nil }
        return bytes
    }
}

extension Calendar {
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
}
