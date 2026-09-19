import XCTest
import SpinnetCore
@testable import SpinnetHost

/// A secret typed into a credential field must reach only the credential
/// store, keyed by the reference the field names, and never the Action.
final class CredentialFieldSecretsTests: XCTestCase {
    private let command = CommandDeclaration(
        id: CommandID("remote.run"), title: "Run", execution: .javascript, script: "run.js",
        configurationFields: [
            CommandConfigurationField(kind: .httpsEndpoint, title: "Endpoint", key: "endpoint"),
            CommandConfigurationField(kind: .credential, title: "API Key", key: "credential")
        ]
    )

    func testTypedSecretsAreKeyedByTheReferenceTheActionStores() {
        let input: JSONValue = .object(["endpoint": .string("https://api.example.com"), "credential": .string("primary")])
        let secrets = CredentialFieldSecrets.typed(for: [command], inputs: [command.id: input],
                                                   secrets: ["primary": "s3cr3t", "unused": "other"])
        XCTAssertEqual(secrets, ["primary": "s3cr3t"])
        XCTAssertTrue(command.acceptsConfigurationFieldsInput(input))
        XCTAssertFalse(String(decoding: try! JSONEncoder().encode(input), as: UTF8.self).contains("s3cr3t"))
        // An empty secret keeps the stored one; an unselected Command contributes nothing.
        XCTAssertEqual(CredentialFieldSecrets.typed(for: [command], inputs: [command.id: input], secrets: ["primary": ""]), [:])
        XCTAssertEqual(CredentialFieldSecrets.typed(for: [], inputs: [command.id: input], secrets: ["primary": "s3cr3t"]), [:])
    }
}
