import SwiftUI
import SpinnetCore

/// Secrets typed into `credential` fields. The field's value in the Action is
/// only the credential reference; the secret goes to the Host's credential
/// store on Save and is never part of the Action.
enum CredentialFieldSecrets {
    /// The typed secrets the selected Commands' credential fields name, keyed
    /// by credential reference. An empty entry means "keep the stored secret".
    static func typed(for commands: [CommandDeclaration], inputs: [CommandID: JSONValue],
                      secrets: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for command in commands {
            guard case .object(let members)? = inputs[command.id] else { continue }
            for field in command.configurationFields where field.kind == .credential {
                guard let key = field.key, case .string(let reference)? = members[key],
                      let secret = secrets[reference], !secret.isEmpty else { continue }
                result[reference] = secret
            }
        }
        return result
    }
}

/// Disclosure and explicit consent for configured endpoints on hosts the
/// Plugin did not declare. Save is refused until the user allows them.
struct EndpointConsentBox: View {
    let consent: HTTPSEndpointConsent
    @Binding var allowed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("New network host", systemImage: "network")
                .font(.subheadline.weight(.semibold))
            Text(consent.disclosure)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Allow \(consent.manifest.name) to contact \(consent.newHosts.joined(separator: ", "))", isOn: $allowed)
                .toggleStyle(.checkbox)
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("New network host consent")
    }
}
