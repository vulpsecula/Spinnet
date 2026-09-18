import Foundation

/// Host-owned interpretation of the supported manifest contract. Scripted
/// Commands can request every declared Host Service; declarative Commands
/// expose only the operations the Host actually executes.
public extension PluginManifest {
    func declares(_ capability: PluginCapability, for commandID: CommandID) -> Bool {
        capabilities.contains(capability) && (scope(for: capability)?.commandIDs.contains(commandID) ?? true)
    }
    func requiredCapabilities(for command: CommandDeclaration, input: JSONValue? = nil) -> [PluginCapability] {
        if command.execution == .javascript {
            return capabilities.filter { scope(for: $0)?.commandIDs.contains(command.id) ?? true }
        }
        var required = capabilityScopes.filter { $0.commandIDs.contains(command.id) }.map(\.capability)
        if let capability = command.hostCommand?.requiredCapability, !required.contains(capability) { required.append(capability) }
        if command.hostCommand == .copyText, input == nil || input == .null {
            if !required.contains(.readSelectedText) { required.append(.readSelectedText) }
        }
        return required
    }

    func requiredSystemPermissions(for command: CommandDeclaration, input: JSONValue? = nil) -> [PluginSystemPermission] {
        let capabilities = requiredCapabilities(for: command, input: input)
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
            }.map(\.title).joined(separator: ", ")
        }
        switch group {
        case .reads:
            guard manifest.capabilities.contains(.readSelectedText), !names(.readSelectedText).isEmpty else { return nil }
            return "Selected text (text only). Commands: \(names(.readSelectedText)). No access to existing Host-held history."
        case .changes:
            guard manifest.capabilities.contains(.writeClipboard), !names(.writeClipboard).isEmpty else { return nil }
            return "Replace current clipboard text. Commands: \(names(.writeClipboard))."
        case .systemAccess:
            let lines = PluginSystemPermission.allCases.compactMap { permission -> String? in
                let affected = commands.filter {
                    manifest.requiredSystemPermissions(for: $0, input: inputs[$0.id]).contains(permission)
                }.map(\.title)
                return affected.isEmpty ? nil : "\(permission.title) — \(affected.joined(separator: ", ")). Granted separately to Spinnet in macOS System Settings."
            }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        case .monitors, .contacts: return nil
        case .controls:
            var affected = commands.compactMap { command -> String? in
                guard let operation = command.hostCommand,
                      ![HostCommand.copyText, .presentFeedback].contains(operation) else { return nil }
                return "\(command.title): \(operation.rawValue) (target configured per Menu Item)"
            }
            if manifest.capabilities.contains(.positionFocusedWindow), !names(.positionFocusedWindow).isEmpty {
                affected.append("Move and resize the focused window. Commands: \(names(.positionFocusedWindow)). No other window or app content is read.")
            }
            if manifest.capabilities.contains(.openURL), !names(.openURL).isEmpty {
                affected.append("Open http and https links in the default browser. Commands: \(names(.openURL)). The website receives the link, including any text in it; the Plugin receives nothing back.")
            }
            if manifest.capabilities.contains(.captureScreen), !names(.captureScreen).isEmpty {
                affected.append("Start a screenshot that Spinnet takes, copies, or saves to the folder you choose. Commands: \(names(.captureScreen)). The Plugin never receives the image.")
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
        case .openURL: return .controls
        case .captureScreen: return .controls
        case .insertIntoFocusedApp: return .changes
        }
    }
}
