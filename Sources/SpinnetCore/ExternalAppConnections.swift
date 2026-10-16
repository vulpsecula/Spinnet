import Foundation

/// Declarative prerequisites. This grants no authority and adds no executable Plugin hook.
public struct ExternalAppConnectionDeclaration: Codable, Equatable {
    public let bundleID: String
    public let commandIDs: [CommandID]

    public init(bundleID: String, commandIDs: [CommandID]) {
        self.bundleID = bundleID
        self.commandIDs = commandIDs
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: JSONValue].self)
        guard Set(raw.keys) == ["bundle_id", "command_ids"] else {
            throw ConfigurationError.invalidManifest("External App connections accept only bundle_id and command_ids")
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try container.decode(String.self, forKey: .bundleID)
        commandIDs = try container.decode([CommandID].self, forKey: .commandIDs)
    }

    private enum CodingKeys: String, CodingKey {
        case bundleID = "bundle_id"
        case commandIDs = "command_ids"
    }
}

public enum ExternalAppConnections {
    public static let declaration = CandidateContractRevision(name: "external_app_connections", revision: 1)
    public static let member = PluginInterfaceMember.behaviour("external_app_connections")
    public static let contract = CandidateContract(name: declaration.name, revision: declaration.revision,
        baseLevel: 2, members: [member], tag: "plugin-api-candidate/external_app_connections/r1")

    static func validate(_ manifest: PluginManifest) throws {
        guard !manifest.externalAppConnections.isEmpty else { return }
        guard manifest.apiLevel >= 3 || (manifest.apiLevel >= 2 && manifest.candidateContracts.contains(where: { $0.name == declaration.name })) else {
            throw ConfigurationError.invalidManifest("external_app_connections requires Plugin API Level 3")
        }
        let connections = manifest.externalAppConnections
        guard connections.count <= 8, Set(connections.map(\.bundleID)).count == connections.count else {
            throw ConfigurationError.invalidManifest("Declare at most eight unique External App connections")
        }
        for connection in connections {
            guard !connection.commandIDs.isEmpty,
                  Set(connection.commandIDs).count == connection.commandIDs.count,
                  connection.commandIDs.allSatisfy({ id in manifest.commands.contains { $0.id == id } }),
                  let interface = ReviewedAppInterface.interface(for: connection.bundleID),
                  interface.minimumAPILevel <= manifest.apiLevel,
                  let checkName = interface.connectionCheckOperation,
                  let check = interface.operations.first(where: { $0.name == checkName }), check.parameters.isEmpty,
                  let scope = manifest.scope(for: .controlExternalApp),
                  connection.commandIDs.allSatisfy(scope.commandIDs.contains),
                  let app = scope.externalApps.first(where: { $0.bundleID == connection.bundleID }),
                  app.operationFamilies.contains(check.family) else {
                throw ConfigurationError.invalidManifest("An External App connection needs declared Commands and a scoped, reviewed read-only check")
            }
        }
    }
}

public enum ExternalAppConnectionStatus: Equatable, Hashable {
    case ready
    case notInstalled
    /// Automation is authorized but the target App is stopped. Configuration remains connected.
    case notRunning
    /// The App is stopped and macOS cannot preflight its Automation permission.
    case notRunningUnchecked
    case permissionNeeded
    case permissionDenied
    case busy
    case failed(String)
    case capabilityDenied
    case ownerInvalid

    public var isConnected: Bool { self == .ready || self == .notRunning }
}

/// A snapshot of one enabled registration, not a grant. Revalidate before
/// native dispatch and before consuming an asynchronous result.
public struct ExternalAppConnectionCheck {
    public let package: PluginPackage
    public let admission: PluginOwnerAdmission
    public let declaration: ExternalAppConnectionDeclaration
    public let interface: ReviewedAppInterface
    public let operation: ReviewedAppInterface.Operation
}
