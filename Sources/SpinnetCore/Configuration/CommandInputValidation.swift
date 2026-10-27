import Foundation

/// One pure input check for Ready-to-Use Presets and Configuration Sheets.
/// Registration, current authority and resource availability are checked again
/// at execution; a value passing this check does not acquire any authority.
enum CommandInputValidation {
    static func problem(with input: JSONValue, for command: CommandDeclaration,
                        in manifest: PluginManifest?) -> String? {
        if command.execution == .host {
            let valid: Bool
            if let adapter = command.hostCommand {
                valid = adapter.isValidInput(input)
            } else if let operation = command.hostServiceID.flatMap(HostServiceCatalogue.operation),
                      operation.isOffered(at: .command) {
                // Deep Link parameters are checked by their declared fields;
                // execution resolves the template rather than a native step.
                valid = operation.id == HostServiceCatalogue.deepLinkOperation
                    || operation.acceptsConfiguredInput(input, for: command)
            } else {
                valid = false
            }
            if !valid { return "Configuration input is invalid for Command \(command.id.rawValue)" }
        }
        if let field = command.configurationField, !field.isValidInput(input) {
            return "\(command.title): \(field.inputRequirement ?? "The value is invalid.")"
        }
        if !(manifest?.acceptsActionInput(input, for: command) ?? command.acceptsConfigurationFieldsInput(input)) {
            return "\(command.title): Fill in every setting with one of its offered values."
        }
        if command.execution == .javascript, (try? JSONEncoder().encode(input)) == nil {
            return "Configuration input is invalid for Command \(command.id.rawValue)"
        }
        return nil
    }
}
