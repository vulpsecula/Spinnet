import Foundation

/// Host-owned interpretation of the supported manifest contract. Scripted
/// Commands can request every declared Host Service; declarative Commands
/// expose only the operations the Host actually executes.
public extension PluginManifest {
    func declares(_ capability: PluginCapability, for commandID: CommandID) -> Bool {
        capabilities.contains(capability) && (scope(for: capability)?.commandIDs.contains(commandID) ?? true)
    }

    func optionalCapabilities(forCommand command: CommandDeclaration) -> [PluginCapability] {
        guard command.execution == .javascript else { return [] }
        return optionalCapabilities.filter { declares($0, for: command.id) }
    }

    func requiredCapabilities(for command: CommandDeclaration, input: JSONValue? = nil) -> [PluginCapability] {
        if command.execution == .javascript {
            return capabilities.filter {
                (scope(for: $0)?.commandIDs.contains(command.id) ?? true)
                    && !optionalCapabilities(forCommand: command).contains($0)
            }
        }
        var required = capabilityScopes.filter { $0.commandIDs.contains(command.id) }.map(\.capability)
        if let capability = command.hostCommand?.requiredCapability, !required.contains(capability) { required.append(capability) }
        if command.hostCommand == .copyText, input == nil || input == .null {
            if !required.contains(.readSelectedText) { required.append(.readSelectedText) }
        }
        return required
    }

    func requiredSystemPermissions(for command: CommandDeclaration, input: JSONValue? = nil) -> [PluginSystemPermission] {
        systemPermissions(for: requiredCapabilities(for: command, input: input), command: command)
    }

    /// System Permissions a Command may need if it asks to use optional
    /// access. This is disclosure only; availability still checks required
    /// access through `requiredSystemPermissions`.
    func declaredSystemPermissions(for command: CommandDeclaration, input: JSONValue? = nil) -> [PluginSystemPermission] {
        systemPermissions(for: requiredCapabilities(for: command, input: input)
            + optionalCapabilities(forCommand: command), command: command)
    }

    func optionalSystemPermissions(for command: CommandDeclaration) -> [PluginSystemPermission] {
        systemPermissions(for: optionalCapabilities(forCommand: command), command: command)
    }

    private func systemPermissions(for capabilities: [PluginCapability], command: CommandDeclaration) -> [PluginSystemPermission] {
        var permissions: [PluginSystemPermission] = []
        if capabilities.contains(.readSelectedText) || capabilities.contains(.positionFocusedWindow)
            || capabilities.contains(.insertIntoFocusedApp)
            || command.hostCommand?.requiredSystemPermission == .accessibility {
            permissions.append(.accessibility)
        }
        if capabilities.contains(.captureScreen) {
            permissions.append(.screenRecording)
        }
        return permissions
    }
}

public enum PluginConsentGroup: String, CaseIterable {
    case reads = "Reads"
    case monitors = "Monitors"
    case contacts = "Contacts"
    case controls = "Controls"
    case changes = "Changes"
    case systemAccess = "System Access"
}

public struct PluginPermissionDisclosure {
    public let manifest: PluginManifest
    public let commands: [CommandDeclaration]
    public let inputs: [CommandID: JSONValue]

    /// Hosts the user added to the contact scope, disclosed with the declared ones.
    public let consentedHTTPSHosts: [String]

    public init(manifest: PluginManifest, commandIDs: Set<CommandID>? = nil, inputs: [CommandID: JSONValue] = [:],
                consentedHTTPSHosts: [String] = []) {
        self.manifest = manifest
        self.inputs = inputs
        self.consentedHTTPSHosts = consentedHTTPSHosts
        commands = manifest.commands.filter { commandIDs?.contains($0.id) ?? true }
    }

    public func details(for group: PluginConsentGroup) -> String {
        let scopes = manifest.capabilityScopes.filter { scope in
            scope.commandIDs.contains { id in commands.contains { $0.id == id } } && scope.capability.consentGroup == group
        }
        var sections = scopes.map { scope in
                let affected = commands.filter { scope.commandIDs.contains($0.id) }.map(\.title).joined(separator: ", ")
                var lines = ["\(scope.capability.title) — Commands: \(affected)"]
                let optionalCommands = commands.filter {
                    manifest.optionalCapabilities(forCommand: $0).contains(scope.capability)
                }
                if !optionalCommands.isEmpty {
                    lines.append(scope.capability.explanation)
                    lines.append("Optional for these Commands: they remain available without this grant; the Host skips the operation that needs it.")
                }
                if !scope.dataTypes.isEmpty { lines.append("Data types: " + scope.dataTypes.joined(separator: ", ")) }
                lines.append(scope.includesExistingHostData ? "Includes existing Host-held data retained before this grant." : "No existing Host-held history access.")
                if !scope.httpsHosts.isEmpty { lines.append("HTTPS hosts: " + scope.httpsHosts.joined(separator: ", ")) }
                if scope.capability == .contactHTTPS, !consentedHTTPSHosts.isEmpty {
                    lines.append("Hosts you added: " + consentedHTTPSHosts.joined(separator: ", "))
                }
                for app in scope.externalApps { lines.append("\(app.bundleID): \(app.operationFamilies.joined(separator: ", "))") }
                if !scope.capability.isSupportedByHostServices { lines.append("Host Service not available in this version; affected Commands remain unavailable.") }
                return lines.joined(separator: "\n")
            }
        if let implicit = implicitDetails(for: group) { sections.append(implicit) }
        return sections.isEmpty ? "None" : sections.joined(separator: "\n\n")
    }

    private func implicitDetails(for group: PluginConsentGroup) -> String? {
        let names: (PluginCapability) -> String = { capability in
            guard self.manifest.scope(for: capability) == nil else { return "" }
            return self.commands.filter {
                self.manifest.requiredCapabilities(for: $0, input: self.inputs[$0.id]).contains(capability)
                    || self.manifest.optionalCapabilities(forCommand: $0).contains(capability)
            }.map(\.title).joined(separator: ", ")
        }
        let optionalNote: (PluginCapability) -> String = { capability in
            let affected = self.commands.filter {
                self.manifest.optionalCapabilities(forCommand: $0).contains(capability)
            }.map(\.title).joined(separator: ", ")
            return affected.isEmpty ? "" : "\nOptional for Commands: \(affected). They remain available without this grant; requests that need this Capability are denied."
        }
        switch group {
        case .reads:
            guard manifest.capabilities.contains(.readSelectedText), !names(.readSelectedText).isEmpty else { return nil }
            return "Selected text (text only). Commands: \(names(.readSelectedText)). No access to existing Host-held history.\(optionalNote(.readSelectedText))"
        case .changes:
            guard manifest.capabilities.contains(.writeClipboard), !names(.writeClipboard).isEmpty else { return nil }
            return "Replace current clipboard text. Commands: \(names(.writeClipboard)).\(optionalNote(.writeClipboard))"
        case .systemAccess:
            let lines = PluginSystemPermission.allCases.compactMap { permission -> String? in
                let affected = commands.filter {
                    manifest.declaredSystemPermissions(for: $0, input: inputs[$0.id]).contains(permission)
                }.map(\.title)
                guard !affected.isEmpty else { return nil }
                let optional = commands.filter {
                    manifest.optionalSystemPermissions(for: $0).contains(permission)
                }.map(\.title)
                let optionalNote = optional.isEmpty ? "" : " Optional access for \(optional.joined(separator: ", ")) still needs this permission when used."
                return "\(permission.title) — \(affected.joined(separator: ", ")). Granted separately to Spinnet in macOS System Settings.\(optionalNote)"
            }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        case .monitors, .contacts: return nil
        case .controls:
            var affected = commands.compactMap { command -> String? in
                guard let operation = command.hostCommand, operation.captureSource == nil,
                      ![HostCommand.copyText, .presentFeedback].contains(operation) else { return nil }
                return "\(command.title): \(operation.rawValue) (target configured per Menu Item)"
            }
            if manifest.capabilities.contains(.positionFocusedWindow), !names(.positionFocusedWindow).isEmpty {
                affected.append("Move and resize the focused window. Commands: \(names(.positionFocusedWindow)). No other window or app content is read.\(optionalNote(.positionFocusedWindow))")
            }
            if manifest.capabilities.contains(.openURL), !names(.openURL).isEmpty {
                affected.append("Open http and https links in the default browser. Commands: \(names(.openURL)). The website receives the link, including any text in it; the Plugin receives nothing back.\(optionalNote(.openURL))")
            }
            if manifest.capabilities.contains(.openLocalPath), !names(.openLocalPath).isEmpty {
                affected.append("\(PluginCapability.openLocalPath.explanation) Commands: \(names(.openLocalPath)).\(optionalNote(.openLocalPath))")
            }
            if manifest.capabilities.contains(.captureScreen), !names(.captureScreen).isEmpty {
                affected.append("Start a screenshot that Spinnet takes, then copies or saves to a folder you chose. Commands: \(names(.captureScreen)). The Plugin never receives the image.\(optionalNote(.captureScreen))")
            }
            return affected.isEmpty ? nil : affected.joined(separator: "\n")
        }
    }
}

public extension PluginCapability {
    var consentGroup: PluginConsentGroup {
        switch self {
        case .readSelectedText, .readCurrentClipboard, .readClipboardHistory: return .reads
        case .writeClipboard: return .changes
        case .monitorClipboard: return .monitors
        case .contactHTTPS: return .contacts
        case .controlExternalApp, .positionFocusedWindow: return .controls
        case .openURL, .openLocalPath: return .controls
        case .captureScreen: return .controls
        case .insertIntoFocusedApp: return .changes
        }
    }
}
