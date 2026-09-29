import Foundation
import XCTest
@testable import SpinnetCore

/// `PluginAPI/schemas/https-request.schema.json` publishes the shape of an
/// `https_request` input, its Credential Uses included, and of its result.
/// The schema states shapes; the Host also checks what a shape cannot say,
/// such as a consented host or a Credential Use's place in the request. So
/// every input the Host accepts must be of the published shape, and every
/// input of the wrong shape must be refused by both.
final class HTTPSRequestSchemaTests: XCTestCase {
    private static let schemaURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("PluginAPI/schemas/https-request.schema.json")

    private func performer(_ transport: HTTPSTransport = RoutedHTTPSTransport()) -> PluginHTTPSRequestPerformer {
        PluginHTTPSRequestPerformer(transport: transport, consentedHosts: ["api.example.com"],
                                    credential: { _ in "secret" })
    }

    private func hostAccepts(_ input: JSONValue) -> Bool {
        do {
            try performer().validate(input)
            return true
        } catch {
            return false
        }
    }

    private static func request(_ members: [String: JSONValue]) -> JSONValue {
        .object(["method": .string("GET"), "url": .string("https://api.example.com/v2/items/KEY")]
            .merging(members) { _, new in new })
    }

    private static func use(_ members: [String: JSONValue]) -> JSONValue {
        request(["credential_uses": .array([.object(["reference": .string("api_key")].merging(members) { _, new in new })])])
    }

    private static let post: [String: JSONValue] = [
        "method": .string("POST"), "body": .string(#"{"text":"hi","key":""}"#)
    ]

    func testEveryInputTheHostAcceptsIsOfThePublishedShape() throws {
        let schema = try JSONSchemaSubsetValidator(definition: "https_request.input", inSchemaAt: Self.schemaURL)
        let accepted: [JSONValue] = [
            Self.request([:]),
            Self.request(["url": .string("HTTPS://API.example.com:443/")]),
            Self.request(["headers": .object(["Content-Type": .string("application/json")]), "body": .null]),
            Self.request(["headers": .null, "credential_uses": .null]),
            Self.request(Self.post),
            Self.use(["header": .string("Authorization"), "template": .string("DeepL-Auth-Key {credential}")]),
            Self.use(["query": .string("api_key")]),
            Self.use(["path_segment": .number(2)]),
            Self.request(Self.post.merging(["credential_uses": .array([.object([
                "reference": .string("api_key"), "json_body": .string("/key")
            ])])]) { _, new in new }),
            Self.request(["method": .string("POST"), "body": .string("q=hi"), "credential_uses": .array([.object([
                "reference": .string("api_key"), "form_body": .string("sign"),
                "signature": .object(["algorithm": .string("md5"), "message": .string("app{credential}"),
                                      "encoding": .string("hex_upper")])
            ])])]),
            Self.use(["header": .string("X-Signature"), "template": .string("TC3 {signature}"),
                      "signature": .object(["algorithm": .string("hmac_sha256"), "message": .string("payload"),
                                            "key": .string("TC3{credential}"),
                                            "chain": .array([.string("2026-09-29"), .string("tmt")]),
                                            "encoding": .string("base64")])])
        ]
        for input in accepted {
            XCTAssertTrue(hostAccepts(input), "The Host accepts \(input)")
            XCTAssertEqual(schema.errors(for: input), [], "\(input)")
        }
    }

    func testInputsOfTheWrongShapeAreRefusedByBoth() throws {
        let schema = try JSONSchemaSubsetValidator(definition: "https_request.input", inSchemaAt: Self.schemaURL)
        let signed = { (signature: [String: JSONValue]) in
            Self.use(["header": .string("X-Sign"), "signature": .object(signature)])
        }
        let refused: [(String, JSONValue)] = [
            ("not an object", .string("https://api.example.com/")),
            ("no url", .object(["method": .string("GET")])),
            ("PUT", Self.request(["method": .string("PUT")])),
            ("http", Self.request(["url": .string("http://api.example.com/")])),
            ("unknown member", Self.request(["timeout": .number(5)])),
            ("a GET body", Self.request(["body": .string("x")])),
            ("a body that is not text", Self.request(["method": .string("POST"), "body": .object([:])])),
            ("a header that is not text", Self.request(["headers": .object(["Accept": .number(1)])])),
            ("a header name with a space", Self.request(["headers": .object(["Bad Name": .string("x")])])),
            ("a header value with a newline", Self.request(["headers": .object(["Accept": .string("a\r\nb")])])),
            ("33 headers", Self.request(["headers": .object(Dictionary(uniqueKeysWithValues: (0..<33).map {
                ("X-H\($0)", JSONValue.string("v"))
            }))])),
            ("credential_uses as an object", Self.request(["credential_uses": .object([:])])),
            ("five Credential Uses", Self.request(["credential_uses": .array(Array(repeating: .object([
                "reference": .string("k"), "header": .string("X-K")
            ]), count: 5))])),
            ("a use without a reference", Self.request(["credential_uses": .array([.object(["header": .string("X")])])])),
            ("a reference with a space", Self.request(["credential_uses": .array([.object([
                "reference": .string("api key"), "header": .string("X-K")
            ])])])),
            ("a use without a placement", Self.use([:])),
            ("a use with two placements", Self.use(["header": .string("X-K"), "query": .string("k")])),
            ("an unknown placement", Self.use(["cookie": .string("k")])),
            ("a negative path segment", Self.use(["path_segment": .number(-1)])),
            ("a fractional path segment", Self.use(["path_segment": .number(1.5)])),
            ("a JSON body pointer without a slash", Self.use(["json_body": .string("key")])),
            ("an empty query name", Self.use(["query": .string("")])),
            ("a template that is not text", Self.use(["header": .string("X-K"), "template": .number(1)])),
            ("a template over 1024 characters", Self.use([
                "header": .string("X-K"), "template": .string(String(repeating: "t", count: 1024) + "{credential}")
            ])),
            ("an unknown algorithm", signed(["algorithm": .string("sha512"), "message": .string("{credential}"),
                                            "encoding": .string("hex")])),
            ("an unknown encoding", signed(["algorithm": .string("sha1"), "message": .string("{credential}"),
                                           "encoding": .string("base32")])),
            ("a signature without a message", signed(["algorithm": .string("sha1"), "encoding": .string("hex")])),
            ("a hash with a key", signed(["algorithm": .string("sha256"), "message": .string("{credential}"),
                                         "key": .string("{credential}"), "encoding": .string("hex")])),
            ("a hash with a chain", signed(["algorithm": .string("md5"), "message": .string("{credential}"),
                                           "chain": .array([.string("a")]), "encoding": .string("hex")])),
            ("a chain of nine", signed(["algorithm": .string("hmac_sha1"), "message": .string("m"),
                                       "chain": .array(Array(repeating: .string("a"), count: 9)),
                                       "encoding": .string("hex")])),
            ("an unknown signature member", signed(["algorithm": .string("hmac_sha1"), "message": .string("m"),
                                                   "encoding": .string("hex"), "salt": .string("s")]))
        ]
        for (name, input) in refused {
            XCTAssertFalse(hostAccepts(input), "The Host refuses \(name)")
            XCTAssertFalse(schema.errors(for: input).isEmpty, "The schema refuses \(name)")
        }
    }

    func testTheHostsResultIsOfThePublishedShape() throws {
        let schema = try JSONSchemaSubsetValidator(definition: "https_request.result", inSchemaAt: Self.schemaURL)
        let transport = RoutedHTTPSTransport(["api.example.com": RoutedHTTPSTransport.json(#"{"ok":true}"#, status: 201)])

        let result = try performer(transport).perform(Self.request([:]))

        XCTAssertEqual(schema.errors(for: result), [])
    }

    /// The published limits are the ones the Host enforces.
    func testTheSchemasLimitsAreTheHostsBudgets() throws {
        let schema = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: Self.schemaURL))
        guard case .object(let document) = schema, case .object(let definitions)? = document["$defs"],
              case .object(let input)? = definitions["https_request.input"],
              case .object(let properties)? = input["properties"],
              case .object(let headers)? = properties["headers"],
              case .object(let uses)? = properties["credential_uses"],
              case .object(let signature)? = definitions["signature"],
              case .object(let signatureProperties)? = signature["properties"],
              case .object(let chain)? = signatureProperties["chain"] else {
            return XCTFail("The schema does not describe the request's limits")
        }
        XCTAssertEqual(headers["maxProperties"], .number(Double(HTTPSRequestBudgets.maximumHeaders)))
        XCTAssertEqual(uses["maxItems"], .number(Double(HTTPSRequestBudgets.maximumCredentialUses)))
        XCTAssertEqual(chain["maxItems"], .number(Double(HTTPSRequestBudgets.maximumHMACChainSteps)))
    }
}
