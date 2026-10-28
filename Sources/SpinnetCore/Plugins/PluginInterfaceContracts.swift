import Foundation

/// One member of the current Documented Plugin Interface. Compatibility admits
/// the package; membership never selects a historical mode for that package.
public struct PluginInterfaceMember: Codable, Hashable {
    public enum Kind: String, Codable, Hashable, CaseIterable {
        case hostService = "host_service"
        case viewComponent = "view_component"
        case standardAction = "standard_action"
        case viewEvent = "view_event"
        /// A Command that runs one Host Service directly, by the name its
        /// manifest gives in `host_command`.
        case hostCommand = "host_command"
        /// A Host Service a script's answer asks the Host to perform after
        /// the answer commits, by the name it gives in `perform`.
        case request
        case source
        /// A rule supported by the current interface, such as insertion targeting.
        case behaviour
    }

    public let kind: Kind
    public let name: String

    public init(kind: Kind, name: String) {
        self.kind = kind
        self.name = name
    }

    public static func hostService(_ name: String) -> PluginInterfaceMember { .init(kind: .hostService, name: name) }
    public static func viewComponent(_ name: String) -> PluginInterfaceMember { .init(kind: .viewComponent, name: name) }
    public static func standardAction(_ name: String) -> PluginInterfaceMember { .init(kind: .standardAction, name: name) }
    public static func viewEvent(_ name: String) -> PluginInterfaceMember { .init(kind: .viewEvent, name: name) }
    public static func hostCommand(_ name: String) -> PluginInterfaceMember { .init(kind: .hostCommand, name: name) }
    public static func request(_ name: String) -> PluginInterfaceMember { .init(kind: .request, name: name) }
    public static func source(_ name: String) -> PluginInterfaceMember { .init(kind: .source, name: name) }
    public static func behaviour(_ name: String) -> PluginInterfaceMember { .init(kind: .behaviour, name: name) }
}

/// Current Host interface and version, injectable at the registration seam.
/// Compatibility and Capability authorization are separate checks.
public struct PluginInterfaceContracts: Equatable {
    public let hostVersion: HostVersion
    public let members: Set<PluginInterfaceMember>

    public init(members: Set<PluginInterfaceMember> = Self.currentMembers, hostVersion: HostVersion = .current) {
        self.members = members
        self.hostVersion = hostVersion
    }

    public static let currentMembers: Set<PluginInterfaceMember> = {
        var members = Set(HostServiceCatalogue.members)
        members.formUnion(HostOperationsContract.members)
        members.formUnion(CollectionsContract.members)
        members.formUnion(PagePresentation.members)
        members.formUnion(CurrentAppAddition.members)
        members.formUnion(KeepAwakeAddition.members)
        members.formUnion(ReviewedToolReads.members)
        members.formUnion(ReviewedToolTasksAddition.members)
        members.formUnion(ReviewedServicesAddition.members)
        members.formUnion(SystemMetrics.members)
        members.insert(SpotifyPlayback.sourceMember)
        members.formUnion(PageSizing.members)
        members.formUnion(HostRunSourceAddition.members)
        members.formUnion(AdaptivePageLayout.members)
        members.formUnion(AdaptiveViewportLayout.members)
        members.formUnion(SpotifyControls.members)
        members.formUnion(ExternalAppConnections.members)
        members.formUnion(HomebrewAutoremove.members)
        members.formUnion(LiveActivityDelivery.members)
        members.formUnion(TerminalHomebrew.members)
        members.formUnion(HomebrewCommandOutput.members)
        members.formUnion(HomebrewCatalogRefresh.members)
        members.formUnion(["settings", "form", "detail", "actions"].map(PluginInterfaceMember.viewComponent))
        members.formUnion(["clipboard.write", "open.url", "selection.replace", "host.showPluginSettings"]
            .map(PluginInterfaceMember.standardAction))
        members.formUnion(["field_changed", "submitted", "action_chosen", "setting_changed", "settings_swapped",
                           "section_delivered"].map(PluginInterfaceMember.viewEvent))
        return members
    }()

    public static let host = PluginInterfaceContracts()

    /// Admission is the same for every package, whoever publishes it, and
    /// never grants permission or selects different interface vocabulary.
    public func check(_ manifest: PluginManifest) throws {
        guard manifest.hostCompatibility.contains(hostVersion) else {
            throw UnsupportedPluginHostVersion(requiredBy: manifest, hostVersion: hostVersion)
        }
        if !manifest.externalAppConnections.isEmpty, !members.contains(ExternalAppConnections.member) {
            throw ConfigurationError.invalidManifest("This Host does not provide External App connections")
        }
        try HostServiceCatalogue.checkCommands(of: manifest, under: self)
    }

    public func permits(_ member: PluginInterfaceMember, declaredBy manifest: PluginManifest) -> Bool {
        members.contains(member)
    }

    public func permitting(_ manifest: PluginManifest) -> (PluginInterfaceMember) -> Bool {
        { self.permits($0, declaredBy: manifest) }
    }
}

/// An installed Plugin that could not load. Its package, Menu Items, settings,
/// storage and grants remain available for replacement or explicit removal.
public struct RefusedPlugin: Equatable {
    public let id: PluginID
    /// Its manifest, when it could be read, so an install over it is an
    /// update that carries its access decisions forward.
    public let manifest: PluginManifest?
    /// Why the Host refused it, as the user reads it.
    public let reason: String

    public init(id: PluginID, manifest: PluginManifest?, reason: String) {
        self.id = id
        self.manifest = manifest
        self.reason = reason
    }

    /// Its name, when its manifest could be read.
    public var name: String? { manifest?.name }
}
