import XCTest
@testable import SpinnetCore

/// A request names a stored credential in a Credential Use, and the Host
/// places it, or a signature made with it, as the request is sent (ADR 0011).
/// Everything here goes through the `https_request` Host Service with a
/// transport that records what would have left the machine.
final class CredentialUseTests: XCTestCase {
    private final class RecordingTransport: HTTPSTransport {
        var responses: [HTTPSTransportResponse] = []
        private(set) var requests: [HTTPSTransportRequest] = []

        func send(_ request: HTTPSTransportRequest) throws -> HTTPSTransportResponse {
            requests.append(request)
            guard !responses.isEmpty else {
                return HTTPSTransportResponse(status: 200, headers: ["content-type": "application/json"], body: Data("{}".utf8))
            }
            return responses.removeFirst()
        }
    }

    /// Keeps secrets in memory and counts how often one is read.
    private final class CountingCredentialStore: PluginCredentialStore {
        private let stored = InMemoryPluginCredentialStore()
        private(set) var reads = 0

        func secret(for pluginID: PluginID, reference: String) throws -> String? {
            reads += 1
            return try stored.secret(for: pluginID, reference: reference)
        }

        func setSecret(_ secret: String, for pluginID: PluginID, reference: String) throws {
            try stored.setSecret(secret, for: pluginID, reference: reference)
        }

        func removeSecret(for pluginID: PluginID, reference: String) throws {
            try stored.removeSecret(for: pluginID, reference: reference)
        }
    }

    private static let hosts = ["api.example.com", "cdn.example.com", "fanyi-api.baidu.com", "openapi.youdao.com",
                                "cvm.tencentcloudapi.com"]

    private var manifest: PluginManifest!
    private var package: PluginPackage!
    private var grants: PluginCapabilityGrantStore!
    private var credentials: CountingCredentialStore!
    private var transport: RecordingTransport!

    override func setUpWithError() throws {
        let hostList = Self.hosts.map { "\"\($0)\"" }.joined(separator: ", ")
        manifest = try PluginManifestLoader.decode(Data("""
        {
          "protocol_version": "1.0", "id": "com.example.signed", "name": "Signed Example", "version": "1.0.0",
          "capabilities": ["contact_https"],
          "capability_scopes": [{
            "capability": "contact_https", "command_ids": ["fetch"], "data_types": [],
            "includes_existing_host_data": false, "https_hosts": [\(hostList)], "external_apps": []
          }],
          "preset": {"readiness": "ready_to_use", "is_configurable": false, "default_primary_command_id": "fetch"},
          "commands": [{"id": "fetch", "title": "Fetch", "execution": "javascript", "is_configurable": false,
                        "script": "fetch.js"}]
        }
        """.utf8))
        package = PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/signed"), manifest: manifest)
        grants = PluginCapabilityGrantStore()
        grants.setDecision(.granted, for: manifest.id, pluginVersion: manifest.version,
                           capability: .contactHTTPS, scope: manifest.scope(for: .contactHTTPS))
        credentials = CountingCredentialStore()
        transport = RecordingTransport()
    }

    @discardableResult
    private func send(_ input: JSONValue) throws -> JSONValue {
        let broker = CapabilityCheckedHostServiceBroker(
            grantStore: grants, systemPermissionCheck: { _ in true },
            selectedTextProvider: { _ in "" }, clipboardWriter: { _ in },
            httpsTransport: transport, credentialStore: credentials
        )
        let command = try XCTUnwrap(manifest.commands.first)
        let action = try ActionConfiguration(id: ActionID("fetch"), pluginID: manifest.id, command: command, input: .null)
        let request = PluginRuntimeHostServiceRequest(invocationID: "invocation", actionID: action.id,
                                                      service: .httpsRequest, input: input)
        return try broker.execute(request: request, for: package, action: action)
    }

    /// Reads a JSON literal written the way a script would write it.
    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    private func store(_ secret: String, as reference: String) throws {
        try credentials.setSecret(secret, for: manifest.id, reference: reference)
    }

    // MARK: Placement

    func testAHeaderPlacementFillsItsTemplateWithTheCredential() throws {
        try store("s3cr3t-key", as: "primary")
        let result = try send(json("""
        {"method": "GET", "url": "https://api.example.com/v1/me",
         "credential_uses": [{"reference": "primary", "header": "Authorization", "template": "Bearer {credential}"}]}
        """))
        XCTAssertEqual(transport.requests.first?.headers, ["Authorization": "Bearer s3cr3t-key"])
        XCTAssertFalse(String(describing: result).contains("s3cr3t-key"), "The secret reached the Plugin")
    }

    func testAPathSegmentPlacementReplacesThatSegment() throws {
        try store("key/with space", as: "primary")
        try send(json("""
        {"method": "GET", "url": "https://api.example.com/v6/KEY/latest/USD?full=1",
         "credential_uses": [{"reference": "primary", "path_segment": 1}]}
        """))
        XCTAssertEqual(transport.requests.first?.url.absoluteString,
                       "https://api.example.com/v6/key%2Fwith%20space/latest/USD?full=1",
                       "The credential stays inside its one segment")
    }

    /// HMAC-SHA1 is RFC 2202's test case 2 (key "Jefe"), in base64.
    func testAJSONBodyPlacementReplacesOnlyTheStringItsPointerNames() throws {
        try store("Jefe", as: "primary")
        try send(json(#"""
        {"method": "POST", "url": "https://api.example.com/v1/sign",
         "body": "{\"text\": \"{credential}\", \"auth\": {\"signature\": \"\"},  \"n\": 1.50}",
         "credential_uses": [{"reference": "primary", "json_body": "/auth/signature",
                              "signature": {"algorithm": "hmac_sha1", "message": "what do ya want for nothing?",
                                            "encoding": "base64"}}]}
        """#))
        XCTAssertEqual(transport.requests.first.flatMap { $0.body }.map { String(decoding: $0, as: UTF8.self) },
                       #"{"text": "{credential}", "auth": {"signature": "7/zfauXrL6LSdBbV8YTfnCWafHk="},  "n": 1.50}"#,
                       "Every other byte of the Plugin's body, and its own text, is left alone")
    }

    /// SHA-1 of "abc" is FIPS 180's first example, and HMAC-SHA256 with key
    /// "Jefe" is RFC 4231's test case 2.
    func testHashesAndHMACsEncodeAsAsked() throws {
        try store("abc", as: "short")
        try store("Jefe", as: "jefe")
        try send(json("""
        {"method": "GET", "url": "https://api.example.com/v1/data",
         "credential_uses": [
           {"reference": "short", "query": "digest",
            "signature": {"algorithm": "sha1", "message": "{credential}", "encoding": "hex_upper"}},
           {"reference": "jefe", "header": "X-Signature",
            "signature": {"algorithm": "hmac_sha256", "message": "what do ya want for nothing?", "encoding": "hex"}}]}
        """))
        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(sent.url.absoluteString, "https://api.example.com/v1/data?digest=A9993E364706816ABA3E25717850C26C9CD0D89D")
        XCTAssertEqual(sent.headers, ["X-Signature": "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"])
    }

    // MARK: Refusals

    /// Anything outside the fixed set, or a use that does not fit its
    /// request, is refused while the request is checked: no secret is read
    /// and nothing leaves the machine.
    func testAnUnsupportedShapeIsRefusedBeforeAnythingIsSent() throws {
        try store("s3cr3t-key", as: "primary")
        let request = #""method": "POST", "url": "https://api.example.com/v1/x/y?a=1", "body": "{\"n\": 1, \"s\": \"\"}""#
        let hash = #""algorithm": "sha256", "encoding": "hex""#
        let refused = [
            #"{"reference": "primary", "cookie": "session"}"#,
            #"{"reference": "primary"}"#,
            #"{"reference": "primary", "header": "X-Key", "query": "key"}"#,
            #"{"reference": "../primary", "header": "X-Key"}"#,
            #"{"reference": "primary", "header": "Cookie"}"#,
            #"{"reference": "primary", "header": "Sec-Fetch-Mode"}"#,
            #"{"reference": "primary", "header": "X-Key", "template": "no placeholder"}"#,
            #"{"reference": "primary", "header": "X-Key", "template": "{signature}"}"#,
            #"{"reference": "primary", "header": "X-Key", "template": "{credential}{credential}"}"#,
            #"{"reference": "primary", "query": "a"}"#,
            #"{"reference": "primary", "path_segment": 3}"#,
            #"{"reference": "primary", "path_segment": 0.5}"#,
            #"{"reference": "primary", "json_body": "/n"}"#,
            #"{"reference": "primary", "json_body": "/missing"}"#,
            #"{"reference": "primary", "json_body": "s"}"#,
            #"{"reference": "primary", "form_body": "s", "signature": {"algorithm": "sha512", "message": "{credential}", "encoding": "hex"}}"#,
            #"{"reference": "primary", "form_body": "s", "signature": {"algorithm": "md5", "message": "{credential}", "encoding": "base32"}}"#,
            #"{"reference": "primary", "form_body": "s", "signature": {\#(hash), "message": "no credential"}}"#,
            #"{"reference": "primary", "form_body": "s", "signature": {\#(hash), "message": "{credential}{credential}"}}"#,
            #"{"reference": "primary", "form_body": "s", "signature": {\#(hash), "message": "{credential}", "chain": ["a"]}}"#,
            #"{"reference": "primary", "form_body": "s", "signature": {"algorithm": "hmac_sha256", "message": "m", "key": "fixed", "encoding": "hex"}}"#,
            #"{"reference": "primary", "form_body": "s", "signature": {"algorithm": "hmac_sha256", "message": "m", "chain": "a", "encoding": "hex"}}"#,
            #"{"reference": "primary", "form_body": "s", "signature": {"algorithm": "hmac_sha256", "message": "m"}}"#
        ]
        for use in refused {
            XCTAssertThrowsError(try send(json("{\(request), \"credential_uses\": [\(use)]}")), use) { error in
                guard case .invalidInput? = error as? PluginHostServiceError else { return XCTFail("\(use): \(error)") }
            }
        }
        let wholeRequests = [
            #"{"method": "GET", "url": "https://api.example.com/", "credential_uses": [{"reference": "primary", "form_body": "key"}]}"#,
            #"{"method": "GET", "url": "https://api.example.com/", "credential_uses": {"reference": "primary", "header": "X-Key"}}"#,
            #"{"method": "GET", "url": "https://api.example.com/", "credential_uses": [{"reference": "primary", "json_body": "/a"}]}"#,
            #"{"method": "GET", "url": "https://api.example.com/", "headers": {"X-Key": "mine"}, "credential_uses": [{"reference": "primary", "header": "x-key"}]}"#,
            #"{"method": "GET", "url": "https://api.example.com/", "credential_uses": [{"reference": "primary", "query": "k"}, {"reference": "primary", "query": "k"}]}"#,
            "{\"method\": \"GET\", \"url\": \"https://api.example.com/\", \"credential_uses\": ["
                + (1...5).map { #"{"reference": "primary", "query": "k\#($0)"}"# }.joined(separator: ", ") + "]}"
        ]
        for input in wholeRequests {
            XCTAssertThrowsError(try send(json(input)), input) { error in
                guard case .invalidInput? = error as? PluginHostServiceError else { return XCTFail("\(input): \(error)") }
            }
        }
        XCTAssertEqual(transport.requests, [], "Nothing may be sent for a refused Credential Use")
        XCTAssertEqual(credentials.reads, 0, "No secret is read for a refused Credential Use")
    }

    // MARK: Redirects

    /// A 307 keeps the method and body. To the same host they keep their
    /// credentials; to another consented host they go as the Plugin wrote
    /// them, with no placed header, field, or signature.
    func testARedirectToAnotherHostDropsTheCredential() throws {
        try store("s3cr3t-key", as: "primary")
        let input = try json("""
        {"method": "POST", "url": "https://api.example.com/v1/upload", "body": "a=1",
         "credential_uses": [
           {"reference": "primary", "header": "X-Api-Key"},
           {"reference": "primary", "form_body": "key"},
           {"reference": "primary", "form_body": "sign",
            "signature": {"algorithm": "sha256", "message": "a=1{credential}", "encoding": "hex"}}]}
        """)
        transport.responses = [
            HTTPSTransportResponse(status: 307, headers: ["location": "/v1/upload-here"], body: Data()),
            HTTPSTransportResponse(status: 307, headers: ["location": "https://cdn.example.com/v1/upload"], body: Data())
        ]
        try send(input)

        XCTAssertEqual(transport.requests.map(\.url.absoluteString), [
            "https://api.example.com/v1/upload", "https://api.example.com/v1/upload-here", "https://cdn.example.com/v1/upload"
        ])
        for sameHost in transport.requests.prefix(2) {
            XCTAssertEqual(sameHost.headers, ["X-Api-Key": "s3cr3t-key"])
            XCTAssertTrue(String(decoding: sameHost.body ?? Data(), as: UTF8.self).hasPrefix("a=1&key=s3cr3t-key&sign="))
        }
        let elsewhere = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(elsewhere.headers, [:], "No credential header reaches another host")
        XCTAssertEqual(elsewhere.body, Data("a=1".utf8), "The body goes as the Plugin wrote it")
    }

    // MARK: Worked examples from the services' own documentation

    /// Baidu Translate's general text API, "接入举例" in
    /// https://fanyi-api.baidu.com/doc/21: appid 2015063000000001, q apple,
    /// salt 1435660288 and key 12345678 sign as
    /// MD5("2015063000000001apple143566028812345678") =
    /// f89f9594663708c1605f3d736d01d2d4, sent last in the query.
    func testBaiduMD5SignatureMatchesItsWorkedExample() throws {
        try store("12345678", as: "baidu")
        try send(json("""
        {"method": "GET",
         "url": "https://fanyi-api.baidu.com/api/trans/vip/translate?q=apple&from=en&to=zh&appid=2015063000000001&salt=1435660288",
         "credential_uses": [{"reference": "baidu", "query": "sign",
                              "signature": {"algorithm": "md5", "message": "2015063000000001apple1435660288{credential}",
                                            "encoding": "hex"}}]}
        """))
        XCTAssertEqual(transport.requests.first?.url.absoluteString,
                       "https://fanyi-api.baidu.com/api/trans/vip/translate?q=apple&from=en&to=zh"
                           + "&appid=2015063000000001&salt=1435660288&sign=f89f9594663708c1605f3d736d01d2d4")
    }

    /// Youdao's text translation API v3,
    /// https://ai.youdao.com/DOCSIRMA/html/trans/api/wbfy/index.html:
    /// sign = sha256(appKey + input + salt + curtime + appSecret), where input
    /// is q when q has at most 20 characters, and otherwise its first 10, its
    /// length and its last 10. The worked example of input is Youdao's own
    /// (https://ai.youdao.com/DOCSIRMA/html/ocr/api/ztsbhgs/index.html):
    /// "Welcome to youdao AICloud." has 26 characters, so input is
    /// "Welcome to26o AICloud.". Youdao publishes no digest, so the expected
    /// sign was computed with `shasum -a 256` over the concatenation.
    func testYoudaoV3SHA256SignatureOverTheTruncatedInput() throws {
        try store("ydAppSecret0001", as: "youdao")
        let fields = "q=Welcome%20to%20youdao%20AICloud.&from=en&to=zh-CHS&appKey=ydAppKey0001"
            + "&salt=5f0e7a3c-1b2d-4e8f-9a6b-3c4d5e6f7a8b&signType=v3&curtime=1695628800"
        try send(.object([
            "method": .string("POST"), "url": .string("https://openapi.youdao.com/api"),
            "headers": .object(["Content-Type": .string("application/x-www-form-urlencoded")]),
            "body": .string(fields),
            "credential_uses": .array([.object([
                "reference": .string("youdao"), "form_body": .string("sign"),
                "signature": .object([
                    "algorithm": .string("sha256"), "encoding": .string("hex"),
                    "message": .string("ydAppKey0001" + "Welcome to26o AICloud." + "5f0e7a3c-1b2d-4e8f-9a6b-3c4d5e6f7a8b"
                                       + "1695628800" + "{credential}")
                ])
            ])])
        ]))
        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(sent.body.map { String(decoding: $0, as: UTF8.self) },
                       fields + "&sign=cea0c74e5c0d45cfb717e55c38ff5cd68dfc9ae5240facb8a43e373c3dfcb174")
        XCTAssertEqual(sent.headers, ["Content-Type": "application/x-www-form-urlencoded"])
    }

    /// Tencent Cloud's signature v3, TC3-HMAC-SHA256, with the worked example
    /// in https://cloud.tencent.com/document/api/213/30654: SecretKey is
    /// literally 32 asterisks (the published SecretDate,
    /// da98fb70dcf6b112dc21038d1eeeb3a95c74b4dcb12c1131f864f6066bd02be0,
    /// is HMAC-SHA256("TC3" + that key, "2019-02-25")), and the chain
    /// "TC3" + SecretKey → 2019-02-25 → cvm → tc3_request → StringToSign signs
    /// as 10b1a37a7301a02ca19a647ad722d5e43b4b3cff309d421d85b46093f6ab6c4f.
    /// The Plugin builds the canonical request and StringToSign, which hold no
    /// secret; the Host runs the chain and fills in the Authorization header.
    func testTencentTC3HMACChainMatchesItsWorkedExample() throws {
        try store(String(repeating: "*", count: 32), as: "tencent")
        let secretID = "AKID" + String(repeating: "*", count: 32)
        let stringToSign = "TC3-HMAC-SHA256\n1551113065\n2019-02-25/cvm/tc3_request\n"
            + "7019a55be8395899b900fb5564e4200d984910f34794a27cb3fb7d10ff6a1e84"
        let payload = #"{"Limit": 1, "Filters": [{"Values": ["未命名"], "Name": "instance-name"}]}"#
        try send(.object([
            "method": .string("POST"), "url": .string("https://cvm.tencentcloudapi.com/"),
            "headers": .object([
                "Content-Type": .string("application/json; charset=utf-8"),
                "X-TC-Action": .string("DescribeInstances"), "X-TC-Timestamp": .string("1551113065"),
                "X-TC-Version": .string("2017-03-12"), "X-TC-Region": .string("ap-guangzhou")
            ]),
            "body": .string(payload),
            "credential_uses": .array([.object([
                "reference": .string("tencent"), "header": .string("Authorization"),
                "template": .string("TC3-HMAC-SHA256 Credential=\(secretID)/2019-02-25/cvm/tc3_request, "
                                    + "SignedHeaders=content-type;host;x-tc-action, Signature={signature}"),
                "signature": .object([
                    "algorithm": .string("hmac_sha256"), "key": .string("TC3{credential}"),
                    "chain": .array([.string("2019-02-25"), .string("cvm"), .string("tc3_request")]),
                    "message": .string(stringToSign), "encoding": .string("hex")
                ])
            ])])
        ]))
        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(sent.headers["Authorization"],
                       "TC3-HMAC-SHA256 Credential=\(secretID)/2019-02-25/cvm/tc3_request, "
                           + "SignedHeaders=content-type;host;x-tc-action, "
                           + "Signature=10b1a37a7301a02ca19a647ad722d5e43b4b3cff309d421d85b46093f6ab6c4f")
        XCTAssertEqual(sent.body, Data(payload.utf8), "The signed payload leaves exactly as the Plugin hashed it")
    }
}
