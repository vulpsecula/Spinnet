import Foundation

/// The bounds of one `https_request`. They are part of the Documented Plugin
/// Interface, like `ScriptedActionBudgets`.
/// The one definition of an address Spinnet may contact: https, a host, no
/// user name or password, and the default port. The Configuration Sheet and
/// the request broker both ask it, so they cannot disagree.
enum HTTPSDestination {
    /// The lower-cased host of `url` when it is such an address.
    static func host(of url: URL) -> String? {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return nil }
        return host
    }
}

public enum HTTPSRequestBudgets {
    /// Wall-clock budget for the whole request, redirects included. It sits
    /// inside the four-second scripted Action deadline so the script still has
    /// time to use the response.
    public static let timeout: TimeInterval = 3

    /// Largest request body a Plugin may send, in UTF-8 bytes.
    public static let maximumRequestBodyBytes = 128 * 1024

    /// Largest response body returned to a Plugin, in bytes. Even if every
    /// byte needs a six-byte JSON escape, the response still fits one 1 MiB
    /// helper message.
    public static let maximumResponseBodyBytes = 128 * 1024

    /// Redirects the Host follows before failing the request.
    public static let maximumRedirects = 3

    /// Request headers a Plugin may set.
    public static let maximumHeaders = 32

    /// Credential Uses one request may name.
    public static let maximumCredentialUses = 4

    /// Longest Credential Use placement template, HMAC key template, or HMAC
    /// chain step, in characters.
    public static let maximumCredentialTemplateLength = 1024

    /// Steps an HMAC chain may sign before its message.
    public static let maximumHMACChainSteps = 8

    /// Methods a Plugin may use.
    public static let methods: Set<String> = ["GET", "POST"]

    /// Response headers passed back to the Plugin; every other header, such
    /// as `set-cookie`, stays with the Host.
    public static let returnedResponseHeaders = ["content-type", "content-language", "retry-after"]
}

/// One request as the Host hands it to a transport.
public struct HTTPSTransportRequest: Equatable {
    public let method: String
    public let url: URL
    public let headers: [String: String]
    public let body: Data?
    /// Time left for this hop.
    public let timeout: TimeInterval
    /// The transport may stop reading and fail once a body passes this.
    public let maximumResponseBytes: Int

    public init(method: String, url: URL, headers: [String: String], body: Data?,
                timeout: TimeInterval, maximumResponseBytes: Int) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
        self.maximumResponseBytes = maximumResponseBytes
    }
}

public struct HTTPSTransportResponse: Equatable {
    public let status: Int
    /// Header names in lower case.
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }) { first, _ in first }
        self.body = body
    }
}

public enum HTTPSTransportError: Error, Equatable {
    case connectionFailed
    case timedOut
    case responseTooLarge
}

/// The seam between the Host's HTTPS policy and the network. A transport
/// sends exactly one request: it must not follow redirects (the Host decides
/// where a redirect may go), and must not share cookies, a cache, or stored
/// credentials between requests. Tests use a deterministic transport.
public protocol HTTPSTransport {
    func send(_ request: HTTPSTransportRequest) throws -> HTTPSTransportResponse
}

/// Validates one `https_request` input and performs it within the consented
/// hosts. The Plugin's input never carries a secret; it names one in its
/// Credential Uses, and the Host looks it up by reference and applies it to
/// the request itself.
struct PluginHTTPSRequestPerformer {
    let transport: HTTPSTransport
    let consentedHosts: [String]
    let credential: (String) throws -> String?
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    /// A request whose shape, destination, headers, and Credential Uses have
    /// been checked, before any secret is looked up or anything is sent.
    private struct Prepared {
        let request: CredentialUse.Request
        let credentialUses: [CredentialUse]
    }

    func perform(_ input: JSONValue) throws -> JSONValue {
        try send(prepare(input))
    }

    /// Checks everything `perform` checks before it sends, without sending
    /// or reading a secret.
    func validate(_ input: JSONValue) throws {
        _ = try prepare(input)
    }

    private func prepare(_ input: JSONValue) throws -> Prepared {
        guard case .object(let fields) = input,
              Set(fields.keys).isSubset(of: ["method", "url", "headers", "body", "credential", "credential_uses"]) else {
            throw PluginHostServiceError.invalidInput(
                "https_request expects method, url, and optional headers, body, and credential_uses"
            )
        }
        guard case .string(let method) = fields["method"], HTTPSRequestBudgets.methods.contains(method) else {
            throw PluginHostServiceError.invalidInput("https_request method must be GET or POST")
        }
        guard case .string(let urlText) = fields["url"], let url = URL(string: urlText) else {
            throw PluginHostServiceError.invalidInput("https_request expects an absolute https URL")
        }
        try requireConsented(url, isRedirect: false)
        let headers = try parseHeaders(fields["headers"])
        var body: Data?
        switch fields["body"] {
        case nil, .null?:
            body = nil
        case .string(let text)?:
            guard method == "POST" else {
                throw PluginHostServiceError.invalidInput("A GET request has no body")
            }
            guard text.utf8.count <= HTTPSRequestBudgets.maximumRequestBodyBytes else {
                throw PluginHostServiceError.invalidInput("The request body exceeds \(HTTPSRequestBudgets.maximumRequestBodyBytes) bytes")
            }
            body = Data(text.utf8)
        default:
            throw PluginHostServiceError.invalidInput("The request body must be a string")
        }
        let request = CredentialUse.Request(method: method, url: url, headers: headers, body: body)
        let uses = try parseCredentialUses(fields["credential_uses"], legacy: fields["credential"], for: request)
        return Prepared(request: request, credentialUses: uses)
    }

    private func send(_ prepared: Prepared) throws -> JSONValue {
        // The request as the Plugin wrote it, and as it leaves with its
        // Credential Uses applied. Only the original host ever sees the second.
        let plain = prepared.request
        var credentialed = plain
        for use in prepared.credentialUses {
            guard let secret = try credential(use.reference), !secret.isEmpty else {
                throw PluginHostServiceError.failed(
                    "No credential is stored for reference \(use.reference); enter it in the Configuration Sheet"
                )
            }
            try use.apply(use.value(with: secret), to: &credentialed)
        }

        let deadline = now() + HTTPSRequestBudgets.timeout
        let originalHost = plain.url.host?.lowercased()
        var current = credentialed.url
        var currentMethod = plain.method
        var keepsBody = true
        var redirects = 0
        while true {
            // A redirect to another host gets the request without any
            // credential: no placed header, and the body as the Plugin wrote it.
            let isOriginalHost = current.host?.lowercased() == originalHost
            let sent = isOriginalHost ? credentialed.headers : plain.headers
            let body = keepsBody ? (isOriginalHost ? credentialed.body : plain.body) : nil
            let remaining = deadline - now()
            guard remaining > 0 else { throw PluginHostServiceError.failed("The request timed out") }
            let response: HTTPSTransportResponse
            do {
                response = try transport.send(HTTPSTransportRequest(
                    method: currentMethod, url: current, headers: sent, body: body,
                    timeout: remaining, maximumResponseBytes: HTTPSRequestBudgets.maximumResponseBodyBytes
                ))
            } catch HTTPSTransportError.timedOut {
                throw PluginHostServiceError.failed("The request timed out")
            } catch HTTPSTransportError.responseTooLarge {
                throw Self.responseTooLarge
            } catch {
                // Transport errors can quote the request; none of it is passed on.
                throw PluginHostServiceError.failed("The request to \(current.host ?? "the host") failed")
            }
            if [301, 302, 303, 307, 308].contains(response.status), let location = response.headers["location"] {
                redirects += 1
                guard redirects <= HTTPSRequestBudgets.maximumRedirects else {
                    throw PluginHostServiceError.failed("Too many redirects")
                }
                guard let next = URL(string: location, relativeTo: current)?.absoluteURL else {
                    throw PluginHostServiceError.failed("The server sent an invalid redirect")
                }
                try requireConsented(next, isRedirect: true)
                if response.status == 303 || (currentMethod == "POST" && [301, 302].contains(response.status)) {
                    currentMethod = "GET"
                    keepsBody = false
                }
                current = next
                continue
            }
            return try result(for: response)
        }
    }

    private static let responseTooLarge = PluginHostServiceError.failed(
        "The response exceeds \(HTTPSRequestBudgets.maximumResponseBodyBytes) bytes"
    )

    private func result(for response: HTTPSTransportResponse) throws -> JSONValue {
        guard response.body.count <= HTTPSRequestBudgets.maximumResponseBodyBytes else {
            throw Self.responseTooLarge
        }
        guard let text = String(data: response.body, encoding: .utf8) else {
            throw PluginHostServiceError.failed("The response is not UTF-8 text")
        }
        var headers: [String: JSONValue] = [:]
        for name in HTTPSRequestBudgets.returnedResponseHeaders {
            if let value = response.headers[name] { headers[name] = .string(value) }
        }
        return .object([
            "status": .number(Double(response.status)),
            "headers": .object(headers),
            "body": .string(text)
        ])
    }

    private func requireConsented(_ url: URL, isRedirect: Bool) throws {
        guard let host = HTTPSDestination.host(of: url) else {
            if isRedirect { throw PluginHostServiceError.failed("The server redirected away from https") }
            throw PluginHostServiceError.invalidInput("https_request expects an absolute https URL without credentials or a port")
        }
        guard consentedHosts.contains(host) else {
            if isRedirect { throw PluginHostServiceError.failed("The server redirected to \(host), which is outside the consented hosts") }
            throw PluginHostServiceError.capabilityDenied(.contactHTTPS)
        }
    }

    private func parseHeaders(_ value: JSONValue?) throws -> [String: String] {
        guard let value, value != .null else { return [:] }
        guard case .object(let fields) = value, fields.count <= HTTPSRequestBudgets.maximumHeaders else {
            throw PluginHostServiceError.invalidInput("Headers must be an object of at most \(HTTPSRequestBudgets.maximumHeaders) strings")
        }
        var headers: [String: String] = [:]
        var seen = Set<String>()
        for (name, value) in fields {
            let lowered = name.lowercased()
            guard HTTPSHeaderRules.isToken(name), seen.insert(lowered).inserted, !HTTPSHeaderRules.isReserved(lowered),
                  case .string(let text) = value, HTTPSHeaderRules.isSafeValue(text) else {
                throw PluginHostServiceError.invalidInput("Header \(name) is not allowed; credentials are added by the Host")
            }
            headers[name] = text
        }
        return headers
    }

    /// `credential_uses`, plus the single-header `credential` that came
    /// before them, each checked against the request it applies to.
    private func parseCredentialUses(_ value: JSONValue?, legacy: JSONValue?,
                                     for request: CredentialUse.Request) throws -> [CredentialUse] {
        var uses: [CredentialUse] = []
        if let legacy, legacy != .null { uses.append(try CredentialUse(legacy: legacy)) }
        if let value, value != .null {
            guard case .array(let declared) = value else {
                throw PluginHostServiceError.invalidInput("credential_uses must be an array of Credential Uses")
            }
            uses += try declared.map { try CredentialUse($0) }
        }
        guard uses.count <= HTTPSRequestBudgets.maximumCredentialUses else {
            throw PluginHostServiceError.invalidInput(
                "A request names at most \(HTTPSRequestBudgets.maximumCredentialUses) Credential Uses"
            )
        }
        // Each use is placed, with no value yet, on top of the ones before
        // it, so two cannot claim the same header, parameter, or field.
        var placed = request
        for use in uses {
            try use.apply("", to: &placed)
        }
        return uses
    }
}
