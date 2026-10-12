import Foundation
import Security
import CryptoKit
import Darwin

/// Publisher evidence independent of Homebrew/Ruby process output. Only this
/// verifier can construct a catalog; Root uses its own held/copied envelope.
public struct HomebrewSignedCaskCatalog {
    public struct Configuration: Codable, Equatable {
        public let languages: [String]
        public let home: URL
        public let prefix: URL
        public let appDirectory: URL
        public init(languages: [String], home: URL, prefix: URL, appDirectory: URL) throws {
            let boundedLanguages = languages.count <= 128 && languages.allSatisfy { $0.utf8.count <= 64 }
            guard boundedLanguages, [home, prefix, appDirectory].allSatisfy(Self.validURL) else { throw PluginHostServiceError.tool(.planChanged) }
            self.languages = languages; self.home = home; self.prefix = prefix; self.appDirectory = appDirectory
        }
        private static func validURL(_ value: URL) -> Bool {
            guard value.isFileURL, value.path.hasPrefix("/"), value.path.utf8.count <= 2048 else { return false }
            guard value.host == nil || value.host == "localhost" else { return false }
            guard value.user == nil, value.password == nil, value.port == nil, value.query == nil, value.fragment == nil else { return false }
            return !value.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }
        private enum CodingKeys: String, CodingKey { case languages, home, prefix, appDirectory }
        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(languages: values.decode([String].self, forKey: .languages), home: values.decode(URL.self, forKey: .home), prefix: values.decode(URL.self, forKey: .prefix), appDirectory: values.decode(URL.self, forKey: .appDirectory))
        }
    }
    public let envelopeSHA256: String
    public let gitHead: String
    private let casks: [String: Any]
    public static let maximumEnvelopeBytes = 32 * 1024 * 1024
    // Public Homebrew homebrew-1 key, PEM SHA256
    // ef2d2c9e0219d485df9f07fff7b037feadc36c93085be9ffefb1390f31a3de1d.
    // PKCS#1 RSA DER extracted from the pinned public SubjectPublicKeyInfo.
    private static let keyDER = "MIICCgKCAgEAyKoOYzp1rhwXISRi61BYXBEr2PalSK8lEVOL2USy7mpy0OubOlFyujawyQcBcCn+uPOJ/WaK+POhNWcLLoiKL2m8GViaQm7SMwdLKUXFgKSPHcG/1m6Vu+TNBKTfQqT60PjEYIrn5NW9ZrM0cUhKREmsbeAMBevdSaW9UwY9iIhprrgovvT8SzKhF8ZOIZKXfJX4VNk0y/7VJYNuGGqH3npxV7OKd4yTGRGqFcC9kJ84me3thiu0yqlOjASmfWIwIwcfp4j6BEM2LuqKd7yXh51/O+MTthkuxV36moDKfdgdOFsvlCFkziaYLScCX9lOlmZHtOfJTAOXxTmM7qGrwTGK0vhvTi8k9dBmH/dccredQBtPOfM/FEdeyakGLoTcDguiBS/4El3I2KtF6B2hOGoBumR915/cI4drr5yPMduZ7gjs7ZEZnVkeVzic24TfUHpnOYzrhucNJtHMBDj96d1Gk82AhtuF9KlusLmCb6qXCWQSp/A4RZpN37E/p9q8rLp/7B/zp8X2TVvecPNyBdMagdktdEqK7WPlYMcUp56JaOph8vqYoU+oGyCpWoLvcXFb75o4eefuu6Rs5SyMc9JCCJ0DDFPjCRFnGPkvsKxFCzMFqH1jpWH0RQIrgmNVM5PO84iRH9YJsSPQzpMjKvK/ZH4YgR9wNkBNagFo7lsCAwEAAQ=="
    public struct Evidence {
        public let envelope: Data
        public let catalog: HomebrewSignedCaskCatalog
        fileprivate init(envelope: Data, catalog: HomebrewSignedCaskCatalog) { self.envelope = envelope; self.catalog = catalog }
    }
    public static func read(_ source: URL, deadline: Date = Date().addingTimeInterval(15)) throws -> HomebrewSignedCaskCatalog { try load(source, deadline: deadline).catalog }
    public static func load(_ source: URL, deadline: Date = Date().addingTimeInterval(15)) throws -> Evidence {
        let fd = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw PluginHostServiceError.unavailable("Verified Homebrew native metadata is unavailable") }; defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size > 0,
              before.st_size <= maximumEnvelopeBytes else { throw PluginHostServiceError.tool(.outputTooLarge) }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw PluginHostServiceError.tool(.failed) }; if count == 0 { break }
            guard bytes.count + count <= maximumEnvelopeBytes else { throw PluginHostServiceError.tool(.outputTooLarge) }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, bytes.count == before.st_size, before.st_size == after.st_size,
              before.st_ino == after.st_ino, before.st_dev == after.st_dev,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw PluginHostServiceError.tool(.planChanged) }
        let catalog = try verify(bytes)
        guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
        return Evidence(envelope: bytes, catalog: catalog)
    }
    public static func verify(_ envelope: Data) throws -> HomebrewSignedCaskCatalog {
        guard !envelope.isEmpty, envelope.count <= maximumEnvelopeBytes else { throw PluginHostServiceError.tool(.outputTooLarge) }
        guard let wrapper = (try? JSONSerialization.jsonObject(with: envelope)) as? [String: Any],
              let payload = wrapper["payload"] as? String, payload.utf8.count <= maximumEnvelopeBytes,
              let signatures = wrapper["signatures"] as? [[String: Any]], signatures.count <= 8,
              let selected = signatures.first(where: { ($0["header"] as? [String: Any])?["kid"] as? String == "homebrew-1" }),
              let protected = selected["protected"] as? String, protected.utf8.count <= 4096,
              let signature = selected["signature"] as? String, signature.utf8.count <= 1024,
              let headerData = decode64(protected), let signatureData = decode64(signature),
              let header = (try? JSONSerialization.jsonObject(with: headerData)) as? [String: Any], header["alg"] as? String == "PS512",
              let b64 = header["b64"] as? NSNumber, CFGetTypeID(b64) == CFBooleanGetTypeID(), b64.boolValue == false,
              let der = Data(base64Encoded: keyDER) else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic, kSecAttrKeySizeInBits: 4096]
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error),
              SecKeyVerifySignature(key, .rsaSignatureMessagePSSSHA512, Data((protected + "." + payload).utf8) as CFData, signatureData as CFData, &error) else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
        guard let object = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
              let casks = object["casks"] as? [String: Any], let head = object["cask_tap_git_head"] as? String, head.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
        return HomebrewSignedCaskCatalog(envelopeSHA256: digest(envelope), gitHead: head, casks: casks)
    }
    public func project(_ token: String, configuration: Configuration) throws -> [String: JSONValue] {
        guard !token.contains("/"), HomebrewReadInput.validPackageName(token), let sourceRecord = casks[token] as? [String: Any],
              configuration.languages.count <= 128 else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
        let bytes = try JSONSerialization.data(withJSONObject: sourceRecord, options: [.sortedKeys, .withoutEscapingSlashes])
        guard bytes.count <= 1024 * 1024, case .object(let raw) = try JSONDecoder().decode(JSONValue.self, from: bytes) else { throw PluginHostServiceError.tool(.outputTooLarge) }
        guard case .object(var record) = try Self.symbols(.object(raw)) else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
        let variations: [[String: JSONValue]]
        if case .array(let values)? = record["language_variations"] { variations = values.compactMap { if case .object(let object) = $0 { return object }; return nil } } else { variations = [] }
        var chosen: [String: JSONValue]?
        for language in configuration.languages {
            guard let requested = LocaleParts(language) else { continue }
            for exact in [true, false] {
                chosen = variations.first { variation in
                    guard case .array(let groups)? = variation["languages"] else { return false }
                    return groups.contains { value in
                        guard case .string(let name) = value, let candidate = LocaleParts(name) else { return false }
                        return exact ? requested == candidate : requested.includes(candidate)
                    }
                }
                if chosen != nil { break }
            }
            if chosen != nil { break }
        }
        if chosen == nil { chosen = variations.first { $0["default"] == .bool(true) } }
        if case .object(let overrides)? = chosen?["overrides"] { record.merge(overrides) { _, newest in newest } }
        guard case .string(let version)? = record["version"], case .string(let sha)? = record["sha256"],
              case .array(let urls)? = record["url_args"], case .string(let url)? = urls.first,
              HomebrewPrivilegePlan.validDigest(sha) || sha == "no_check" else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
        var artifacts: [JSONValue] = []
        if case .array(let tuples)? = record["raw_artifacts"] {
            guard tuples.count <= 128 else { throw PluginHostServiceError.tool(.outputTooLarge) }
            for value in tuples {
                guard case .array(let tuple) = value, case .string(let name)? = tuple.first, tuple.count <= 4 else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
                var args: [JSONValue] = [], sawArgs = false, sawKwargs = false, sawBlock = false
                for field in tuple.dropFirst() {
                    switch field {
                    case .array(let list): guard !sawArgs, !sawKwargs, !sawBlock else { throw PluginHostServiceError.tool(.sourceNotAllowed) }; args = list; sawArgs = true
                    case .object(let object): guard !sawKwargs, !sawBlock else { throw PluginHostServiceError.tool(.sourceNotAllowed) }; args.append(.object(object)); sawKwargs = true
                    case .string("empty_block"): guard !sawBlock else { throw PluginHostServiceError.tool(.sourceNotAllowed) }; args.append(.object([name: .null])); sawBlock = true
                    default: throw PluginHostServiceError.tool(.sourceNotAllowed)
                    }
                }
                artifacts.append(.object([name: Self.placeholders(.array(args), configuration)]))
            }
        }
        var result: [String: JSONValue] = ["name": .string("homebrew/cask/" + token), "version": .string(version), "url": Self.placeholders(.string(url), configuration), "sha256": .string(sha), "artifacts": .array(artifacts), "language": chosen?["value"] ?? .null]
        result["source"] = .object(["kind": .string("verified-api-jws"), "sha256": .string(envelopeSHA256), "git_head": .string(gitHead), "tap": .string("homebrew/cask"), "ruby_source_path": raw["ruby_source_path"] ?? .null, "ruby_source_checksum": raw["ruby_source_checksum"] ?? .null, "record_sha256": .string(try Self.canonicalDigest(.object(raw)))])
        return result
    }
    /// Compare security-bearing fields against the signature-derived projection,
    /// never a Ruby-provided provenance tag or locally hashed JSON alone.
    public func validate(_ metadata: [String: JSONValue], token: String, configuration: Configuration) throws {
        let expected = try project(token, configuration: configuration)
        for field in ["name", "version", "url", "sha256", "artifacts", "language"] {
            guard let actual = metadata[field], let selected = expected[field], try Self.canonicalDigest(actual) == Self.canonicalDigest(selected) else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
        }
        guard case .object(let actual)? = metadata["source"], case .object(let source)? = expected["source"] else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
        for field in ["kind", "sha256", "git_head", "tap", "ruby_source_path", "ruby_source_checksum"] {
            guard let value = actual[field], let selected = source[field], try Self.canonicalDigest(value) == Self.canonicalDigest(selected) else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
        }
    }
    public func projectionDigest(_ token: String, configuration: Configuration) throws -> String { try Self.canonicalDigest(.object(project(token, configuration: configuration))) }
    private static func symbols(_ value: JSONValue) throws -> JSONValue {
        switch value {
        case .object(let object):
            var normalized: [String: JSONValue] = [:]
            for (key, value) in object {
                let name = key.hasPrefix(":") ? String(key.dropFirst()) : key
                guard normalized[name] == nil else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
                normalized[name] = try symbols(value)
            }
            return .object(normalized)
        case .array(let list): return .array(try list.map(symbols))
        case .string(let text) where text.hasPrefix(":"): return .string(String(text.dropFirst()))
        default: return value
        }
    }
    private static func placeholders(_ value: JSONValue, _ configuration: Configuration) -> JSONValue {
        switch value {
        case .object(let object): return .object(object.mapValues { placeholders($0, configuration) })
        case .array(let list): return .array(list.map { placeholders($0, configuration) })
        case .string(let text): return .string(text.replacingOccurrences(of: "/$HOME", with: configuration.home.path).replacingOccurrences(of: "$HOMEBREW_PREFIX", with: configuration.prefix.path).replacingOccurrences(of: "$HOMEBREW_CELLAR", with: configuration.prefix.appendingPathComponent("Cellar").path).replacingOccurrences(of: "$APPDIR", with: configuration.appDirectory.path))
        default: return value
        }
    }
    private static func digest(_ value: Data) -> String { SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined() }
    private static func canonicalDigest(_ value: JSONValue) throws -> String { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return digest(try encoder.encode(value)) }
    private static func decode64(_ value: String) -> Data? {
        guard value.range(of: "^[A-Za-z0-9_-]+={0,2}$", options: .regularExpression) != nil else { return nil }
        let unpadded = String(value.prefix { $0 != "=" })
        guard unpadded.count % 4 != 1 else { return nil }
        let encoded = unpadded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let bytes = Data(base64Encoded: encoded + String(repeating: "=", count: (4 - encoded.count % 4) % 4)),
              bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").prefix { $0 != "=" } == unpadded else { return nil }
        return bytes
    }
    private struct LocaleParts: Equatable {
        let language: String?, script: String?, region: String?
        init?(_ value: String) {
            guard let regex = try? NSRegularExpression(pattern: "^(?:([a-z]{2,3})(?:-|$))?(?:([A-Z][a-z]{3})(?:-|$))?([A-Z]{2}|[0-9]{3})?$"),
                  let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)), !value.isEmpty, !value.hasSuffix("-") else { return nil }
            func field(_ index: Int) -> String? { guard let range = Range(match.range(at: index), in: value) else { return nil }; return String(value[range]) }
            language = field(1); script = field(2); region = field(3)
        }
        func includes(_ other: LocaleParts) -> Bool { (other.language == nil || language == other.language) && (other.script == nil || script == other.script) && (other.region == nil || region == other.region) }
    }
}
