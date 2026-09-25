import CryptoKit
import Foundation

/// A Plugin-declared way for the Host to put a stored credential into one
/// HTTPS request, or sign the request with it, as the request is sent (ADR
/// 0011). The Plugin names the credential by reference and says where the
/// value goes; the Host looks the secret up, computes the value, and places
/// it. Neither the secret nor anything derived from it is returned to the
/// Plugin.
///
/// The set is fixed. A value is the credential itself, or a signature: a hash
/// over a template holding the credential, or an HMAC keyed with a template
/// holding it, optionally as a chain in which each HMAC keys the next. A
/// value goes into one header, query parameter, path segment, JSON body
/// string, or form body field, through a template that holds it once.
struct CredentialUse: Equatable {
    enum Placement: Equatable {
        case header(String)
        case query(String)
        /// A zero-based index into the URL path's segments.
        case pathSegment(Int)
        /// An RFC 6901 pointer to a string in the JSON body.
        case jsonBody(String)
        case formBody(String)
    }

    struct Signature: Equatable {
        enum Algorithm: String {
            case md5, sha1, sha256
            case hmacSHA1 = "hmac_sha1"
            case hmacSHA256 = "hmac_sha256"

            var isHMAC: Bool { self == .hmacSHA1 || self == .hmacSHA256 }
        }

        enum Encoding: String {
            case hex
            case hexUpper = "hex_upper"
            case base64
        }

        let algorithm: Algorithm
        /// For a hash, a template holding the credential once; for an HMAC,
        /// the text signed last, taken as it is.
        let message: String
        /// For an HMAC, the template the first key is made from.
        let key: String
        /// For an HMAC chain, the texts signed before `message`, each with
        /// the key the one before produced.
        let chain: [String]
        let encoding: Encoding
    }

    /// The placeholder for the credential in a template.
    static let credentialPlaceholder = "{credential}"
    /// The placeholder for a signature in a placement template.
    static let signaturePlaceholder = "{signature}"

    let reference: String
    let signature: Signature?
    let placement: Placement
    /// What is placed, holding `{credential}` or `{signature}` once.
    let template: String

    private static let placementKeys = ["header", "query", "path_segment", "json_body", "form_body"]

    /// Reads one member of `credential_uses`.
    init(_ value: JSONValue) throws {
        guard case .object(let fields) = value,
              Set(fields.keys).isSubset(of: ["reference", "signature", "template"] + Self.placementKeys),
              case .string(let reference)? = fields["reference"], PluginCredentialReference.isValid(reference) else {
            throw Self.invalid("A Credential Use expects a reference, one placement, and optional signature and template")
        }
        self.reference = reference
        signature = try fields["signature"].map(Self.signature)

        let named = Self.placementKeys.filter { fields[$0] != nil }
        guard named.count == 1, let key = named.first, let declared = fields[key] else {
            throw Self.invalid("A Credential Use names exactly one of \(Self.placementKeys.joined(separator: ", "))")
        }
        switch (key, declared) {
        case ("header", .string(let name)):
            guard HTTPSHeaderRules.isToken(name) else { throw Self.invalid("Credential Use header \(name) is not allowed") }
            placement = .header(name)
        case ("query", .string(let name)) where Self.isFieldName(name):
            placement = .query(name)
        case ("form_body", .string(let name)) where Self.isFieldName(name):
            placement = .formBody(name)
        case ("path_segment", .number(let index)) where index >= 0 && index < 64 && index.rounded() == index:
            placement = .pathSegment(Int(index))
        case ("json_body", .string(let pointer)) where pointer.hasPrefix("/") && pointer.count <= 512:
            placement = .jsonBody(pointer)
        default:
            throw Self.invalid("Credential Use \(key) is not a valid placement")
        }

        let placeholder = signature == nil ? Self.credentialPlaceholder : Self.signaturePlaceholder
        var template = placeholder
        if let given = fields["template"] {
            guard case .string(let text) = given else { throw Self.invalid("A Credential Use template must be a string") }
            template = text
        }
        guard template.count <= HTTPSRequestBudgets.maximumCredentialTemplateLength,
              HTTPSHeaderRules.isSafeValue(template), Self.occurrences(of: placeholder, in: template) == 1 else {
            throw Self.invalid("A Credential Use template must hold \(placeholder) exactly once")
        }
        self.template = template
    }

    /// Today's single-header `credential`: `{reference, header?, format?}`,
    /// a header placement by another name.
    init(legacy value: JSONValue) throws {
        guard case .object(let fields) = value,
              Set(fields.keys).isSubset(of: ["reference", "header", "format"]),
              case .string(let reference) = fields["reference"], PluginCredentialReference.isValid(reference) else {
            throw Self.invalid("credential expects a reference, and optional header and format")
        }
        var translated: [String: JSONValue] = ["reference": .string(reference), "header": .string("Authorization")]
        if let header = fields["header"] {
            guard case .string = header else { throw Self.invalid("credential header must be a string") }
            translated["header"] = header
        }
        if let format = fields["format"] {
            guard case .string = format else { throw Self.invalid("credential format must be a string") }
            translated["template"] = format
        }
        try self.init(.object(translated))
    }

    /// The text to place: the template filled with the credential, or with
    /// the signature made with it.
    func value(with secret: String) -> String {
        guard let signature else {
            return template.replacingOccurrences(of: Self.credentialPlaceholder, with: secret)
        }
        return template.replacingOccurrences(of: Self.signaturePlaceholder, with: signature.value(with: secret))
    }

    /// The parts of a request a Credential Use writes to.
    struct Request: Equatable {
        let method: String
        var url: URL
        var headers: [String: String]
        var body: Data?
    }

    /// Puts `value` where this use says. Placing an empty value checks that
    /// the place exists and is free, which the Host does for every use before
    /// any secret is read or anything is sent.
    func apply(_ value: String, to request: inout Request) throws {
        switch placement {
        case .header(let name):
            let lowered = name.lowercased()
            guard !request.headers.keys.contains(where: { $0.lowercased() == lowered }),
                  lowered == "authorization" || !HTTPSHeaderRules.isReserved(lowered) else {
                throw Self.invalid("Credential Use header \(name) is not allowed or is already set")
            }
            guard HTTPSHeaderRules.isSafeValue(value) else {
                throw Self.invalid("The value placed in header \(name) is not a valid header value")
            }
            request.headers[name] = value
        case .query(let name):
            guard var components = URLComponents(url: request.url, resolvingAgainstBaseURL: false),
                  !Self.names(in: components.percentEncodedQuery).contains(name) else {
                throw Self.invalid("Credential Use query parameter \(name) is already in the URL")
            }
            let pair = Self.percentEncoded(name) + "=" + Self.percentEncoded(value)
            components.percentEncodedQuery = components.percentEncodedQuery.map { $0 + "&" + pair } ?? pair
            guard let url = components.url else { throw Self.invalid("The URL cannot hold the Credential Use") }
            request.url = url
        case .formBody(let name):
            let fields = request.body.map { String(decoding: $0, as: UTF8.self) } ?? ""
            guard request.method == "POST", !Self.names(in: fields).contains(name) else {
                throw Self.invalid("Credential Use form field \(name) needs a POST body without that field")
            }
            let pair = Self.percentEncoded(name) + "=" + Self.percentEncoded(value)
            try setBody(Data((fields.isEmpty ? pair : fields + "&" + pair).utf8), of: &request)
        case .pathSegment(let index):
            // The path keeps its leading empty segment, so segment n is n + 1.
            guard var components = URLComponents(url: request.url, resolvingAgainstBaseURL: false) else {
                throw Self.invalid("The URL cannot hold the Credential Use")
            }
            var segments = components.percentEncodedPath.components(separatedBy: "/")
            guard index + 1 < segments.count else {
                throw Self.invalid("The URL path has no segment \(index) for the Credential Use")
            }
            segments[index + 1] = Self.percentEncoded(value)
            components.percentEncodedPath = segments.joined(separator: "/")
            guard let url = components.url else { throw Self.invalid("The URL cannot hold the Credential Use") }
            request.url = url
        case .jsonBody(let pointer):
            // The value is spliced into the Plugin's own text, so everything
            // else in the body, which a signature may cover, leaves unchanged.
            guard let body = request.body, let range = JSONTextLocator.stringRange(at: pointer, in: [UInt8](body)) else {
                throw Self.invalid("Credential Use json_body \(pointer) names no string in the request's JSON body")
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            var spliced = [UInt8](body)
            spliced.replaceSubrange(range, with: try encoder.encode(value))
            try setBody(Data(spliced), of: &request)
        }
    }

    private func setBody(_ body: Data, of request: inout Request) throws {
        guard body.count <= HTTPSRequestBudgets.maximumRequestBodyBytes else {
            throw Self.invalid("The request body exceeds \(HTTPSRequestBudgets.maximumRequestBodyBytes) bytes")
        }
        request.body = body
    }

    /// A query parameter or form field name: 1–64 characters, none of them
    /// a control character.
    private static func isFieldName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// The decoded names in `name=value&…` text.
    private static func names(in pairs: String?) -> Set<String> {
        guard let pairs, !pairs.isEmpty else { return [] }
        return Set(pairs.split(separator: "&").map { pair in
            let name = String(pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0])
            return name.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? name
        })
    }

    /// RFC 3986 unreserved characters; everything else is encoded, so a
    /// placed value stays inside its one parameter, field, or segment.
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func percentEncoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// `{algorithm, message, encoding}` for a hash, and for an HMAC also an
    /// optional `key` template and `chain`.
    private static func signature(_ value: JSONValue) throws -> Signature {
        guard case .object(let fields) = value,
              Set(fields.keys).isSubset(of: ["algorithm", "message", "key", "chain", "encoding"]),
              case .string(let algorithmName)? = fields["algorithm"],
              let algorithm = Signature.Algorithm(rawValue: algorithmName),
              case .string(let encodingName)? = fields["encoding"],
              let encoding = Signature.Encoding(rawValue: encodingName),
              case .string(let message)? = fields["message"],
              message.utf8.count <= HTTPSRequestBudgets.maximumRequestBodyBytes else {
            throw invalid(
                "A signature expects an algorithm (md5, sha1, sha256, hmac_sha1, hmac_sha256), a message, "
                    + "and an encoding (hex, hex_upper, base64)"
            )
        }
        if algorithm.isHMAC {
            // An HMAC is keyed with the credential, or with a template holding
            // it; the message is the Plugin's own and is signed as it is.
            var key = credentialPlaceholder
            if let given = fields["key"] {
                guard case .string(let text) = given else { throw invalid("An HMAC key must be a string") }
                key = text
            }
            guard key.count <= HTTPSRequestBudgets.maximumCredentialTemplateLength,
                  occurrences(of: credentialPlaceholder, in: key) == 1 else {
                throw invalid("An HMAC key must hold \(credentialPlaceholder) exactly once")
            }
            var chain: [String] = []
            if let given = fields["chain"] {
                guard let steps = given.strings, steps.count <= HTTPSRequestBudgets.maximumHMACChainSteps,
                      steps.allSatisfy({ $0.count <= HTTPSRequestBudgets.maximumCredentialTemplateLength }) else {
                    throw invalid("An HMAC chain is at most \(HTTPSRequestBudgets.maximumHMACChainSteps) strings")
                }
                chain = steps
            }
            return Signature(algorithm: algorithm, message: message, key: key, chain: chain, encoding: encoding)
        }
        // A hash is over a concatenation that includes the credential.
        guard fields["key"] == nil, fields["chain"] == nil,
              occurrences(of: credentialPlaceholder, in: message) == 1 else {
            throw invalid("A hash signature's message must hold \(credentialPlaceholder) exactly once, with no key or chain")
        }
        return Signature(algorithm: algorithm, message: message, key: "", chain: [], encoding: encoding)
    }

    private static func occurrences(of placeholder: String, in text: String) -> Int {
        text.components(separatedBy: placeholder).count - 1
    }

    private static func invalid(_ message: String) -> PluginHostServiceError {
        .invalidInput(message)
    }
}

extension CredentialUse.Signature {
    func value(with secret: String) -> String {
        func filled(_ template: String) -> Data {
            Data(template.replacingOccurrences(of: CredentialUse.credentialPlaceholder, with: secret).utf8)
        }
        switch algorithm {
        case .md5: return encode(Data(Insecure.MD5.hash(data: filled(message))))
        case .sha1: return encode(Data(Insecure.SHA1.hash(data: filled(message))))
        case .sha256: return encode(Data(SHA256.hash(data: filled(message))))
        case .hmacSHA1: return encode(hmacChain(Insecure.SHA1.self, key: filled(key)))
        case .hmacSHA256: return encode(hmacChain(SHA256.self, key: filled(key)))
        }
    }

    /// Signs each step of the chain with the key before it, the first key
    /// being the filled key template, and then the message with the last.
    private func hmacChain<Hash: HashFunction>(_ hash: Hash.Type, key: Data) -> Data {
        var key = SymmetricKey(data: key)
        for step in chain {
            key = SymmetricKey(data: Data(HMAC<Hash>.authenticationCode(for: Data(step.utf8), using: key)))
        }
        return Data(HMAC<Hash>.authenticationCode(for: Data(message.utf8), using: key))
    }

    private func encode(_ digest: Data) -> String {
        switch encoding {
        case .hex: return digest.map { String(format: "%02x", $0) }.joined()
        case .hexUpper: return digest.map { String(format: "%02X", $0) }.joined()
        case .base64: return digest.base64EncodedString()
        }
    }
}

/// Finds a value in JSON text by RFC 6901 pointer without decoding the text,
/// so the bytes around it can be kept exactly as they were.
enum JSONTextLocator {
    /// The byte range of the string, quotes included, that `pointer` names
    /// in `text`, or nil when the text is not JSON or names no string there.
    static func stringRange(at pointer: String, in text: [UInt8]) -> Range<Int>? {
        guard (try? JSONSerialization.jsonObject(with: Data(text), options: [.fragmentsAllowed])) != nil,
              pointer.hasPrefix("/") else { return nil }
        let tokens = pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map {
            $0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
        }
        var scanner = Scanner(text: text)
        guard let range = scanner.locate(tokens[...]), text[range.lowerBound] == UInt8(ascii: "\"") else { return nil }
        return range
    }

    /// Walks text already known to be valid JSON.
    private struct Scanner {
        let text: [UInt8]
        var index = 0

        mutating func locate(_ tokens: ArraySlice<String>) -> Range<Int>? {
            skipWhitespace()
            guard let token = tokens.first else {
                let start = index
                skipValue()
                return start..<index
            }
            guard index < text.count else { return nil }
            switch text[index] {
            case UInt8(ascii: "{"):
                index += 1
                while true {
                    skipWhitespace()
                    guard index < text.count, text[index] == UInt8(ascii: "\"") else { return nil }
                    let key = string()
                    skipWhitespace()
                    index += 1 // the colon
                    if key == token { return locate(tokens.dropFirst()) }
                    skipValue()
                    skipWhitespace()
                    guard index < text.count, text[index] == UInt8(ascii: ",") else { return nil }
                    index += 1
                }
            case UInt8(ascii: "["):
                guard let wanted = Int(token), String(wanted) == token else { return nil }
                index += 1
                var position = 0
                while true {
                    skipWhitespace()
                    guard index < text.count, text[index] != UInt8(ascii: "]") else { return nil }
                    if position == wanted { return locate(tokens.dropFirst()) }
                    skipValue()
                    skipWhitespace()
                    guard index < text.count, text[index] == UInt8(ascii: ",") else { return nil }
                    index += 1
                    position += 1
                }
            default:
                return nil
            }
        }

        private mutating func skipWhitespace() {
            while index < text.count, [0x20, 0x09, 0x0A, 0x0D].contains(text[index]) { index += 1 }
        }

        /// Reads the string starting at `index` and returns it decoded.
        private mutating func string() -> String? {
            let start = index
            index += 1
            while index < text.count, text[index] != UInt8(ascii: "\"") {
                index += text[index] == UInt8(ascii: "\\") ? 2 : 1
            }
            index += 1
            let literal = Data(text[start..<min(index, text.count)])
            return try? JSONDecoder().decode([String].self, from: Data("[".utf8) + literal + Data("]".utf8)).first
        }

        private mutating func skipValue() {
            skipWhitespace()
            guard index < text.count else { return }
            switch text[index] {
            case UInt8(ascii: "\""):
                _ = string()
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                // Strings are skipped whole, so a bracket inside one never counts.
                var depth = 0
                repeat {
                    switch text[index] {
                    case UInt8(ascii: "\""):
                        _ = string()
                        continue
                    case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
                    case UInt8(ascii: "}"), UInt8(ascii: "]"): depth -= 1
                    default: break
                    }
                    index += 1
                } while depth > 0 && index < text.count
            default:
                while index < text.count, ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), 0x20, 0x09, 0x0A, 0x0D]
                    .contains(text[index]) { index += 1 }
            }
        }
    }
}

/// What a header name and value may be, shared by a Plugin's own headers and
/// Credential Use header placements.
enum HTTPSHeaderRules {
    /// Headers that carry identity, framing, or routing belong to the Host.
    private static let reserved: Set<String> = [
        "authorization", "proxy-authorization", "cookie", "cookie2", "set-cookie", "host",
        "content-length", "connection", "transfer-encoding", "te", "trailer", "upgrade",
        "expect", "keep-alive", "via", "forwarded"
    ]

    /// Whether a lower-cased header name belongs to the Host.
    static func isReserved(_ lowered: String) -> Bool {
        reserved.contains(lowered) || lowered.hasPrefix("proxy-") || lowered.hasPrefix("sec-")
    }

    static func isToken(_ name: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return !name.isEmpty && name.count <= 64 && name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    static func isSafeValue(_ value: String) -> Bool {
        value.count <= 4096 && !value.unicodeScalars.contains { $0 == "\r" || $0 == "\n" || $0 == "\0" }
    }
}
