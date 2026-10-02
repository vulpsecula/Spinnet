import Foundation

/// One revision of a Candidate Contract as a manifest declares it, in
/// `candidate_contracts`: the exact revision the Plugin was written against.
public struct CandidateContractRevision: Codable, Hashable {
    public let name: String
    public let revision: Int

    public init(name: String, revision: Int) {
        self.name = name
        self.revision = revision
    }

    /// A lowercase identifier: a letter, then letters, digits or `_`, at most
    /// 64 characters, so a name reads the same in a tag and a path.
    static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, ("a"..."z").contains(first), name.count <= 64 else { return false }
        return name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
    }
}

/// Something a Plugin reaches through the Documented Plugin Interface, owned
/// by the stable Level or Candidate Contract that offers it. A Plugin may use
/// a member only through a Level it declares or a candidate it declares.
public struct PluginInterfaceMember: Codable, Hashable {
    public enum Kind: String, Codable, Hashable, CaseIterable {
        case hostService = "host_service"
        case viewComponent = "view_component"
        case standardAction = "standard_action"
        case viewEvent = "view_event"
        /// A rule the Host applies, such as how an insertion picks its target,
        /// that a Plugin gets only by declaring the contract defining it.
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
    public static func behaviour(_ name: String) -> PluginInterfaceMember { .init(kind: .behaviour, name: name) }
}

/// A provisional revision of the Documented Plugin Interface (ADR 0013): the
/// members it adds on top of a stable Level, the other candidates it needs or
/// excludes, and the tag its published material is pinned at. Its
/// `candidate.json` under `PluginAPI/candidates/<name>/r<revision>/` is this
/// value as JSON.
public struct CandidateContract: Codable, Equatable {
    public enum Status: Equatable {
        /// The Host provides this revision to Plugins that declare it.
        case supported
        /// The Host no longer provides it; a promoted one names the stable
        /// Level its members became.
        case retired(promotedToLevel: Int?)
    }

    public let name: String
    public let revision: Int
    /// The stable Level it adds to; a declaring Plugin must declare at least
    /// this Level.
    public let baseLevel: Int
    /// Candidate revisions a Plugin must declare alongside this one.
    public let requires: [CandidateContractRevision]
    /// Candidates a Plugin may not declare alongside this one.
    public let conflicts: [String]
    public let members: [PluginInterfaceMember]
    /// The git tag pinning this revision's published material, such as
    /// `plugin-api-candidate/<name>/r<revision>`.
    public let tag: String
    public let status: Status

    public init(name: String, revision: Int, baseLevel: Int, requires: [CandidateContractRevision] = [],
                conflicts: [String] = [], members: [PluginInterfaceMember], tag: String, status: Status = .supported) {
        self.name = name
        self.revision = revision
        self.baseLevel = baseLevel
        self.requires = requires
        self.conflicts = conflicts
        self.members = members
        self.tag = tag
        self.status = status
    }

    public var declaration: CandidateContractRevision { CandidateContractRevision(name: name, revision: revision) }

    private enum CodingKeys: String, CodingKey {
        case name, revision, requires, conflicts, members, tag, status
        case baseLevel = "base_level"
        case promotedToLevel = "promoted_to_level"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        revision = try container.decode(Int.self, forKey: .revision)
        baseLevel = try container.decode(Int.self, forKey: .baseLevel)
        requires = try container.decode([CandidateContractRevision].self, forKey: .requires)
        conflicts = try container.decode([String].self, forKey: .conflicts)
        members = try container.decode([PluginInterfaceMember].self, forKey: .members)
        tag = try container.decode(String.self, forKey: .tag)
        switch try container.decode(String.self, forKey: .status) {
        case "supported": status = .supported
        case "retired": status = .retired(promotedToLevel: try container.decodeIfPresent(Int.self, forKey: .promotedToLevel))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .status, in: container,
                                                   debugDescription: "Unknown candidate status \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(revision, forKey: .revision)
        try container.encode(baseLevel, forKey: .baseLevel)
        try container.encode(requires, forKey: .requires)
        try container.encode(conflicts, forKey: .conflicts)
        try container.encode(members, forKey: .members)
        try container.encode(tag, forKey: .tag)
        switch status {
        case .supported:
            try container.encode("supported", forKey: .status)
        case .retired(let level):
            try container.encode("retired", forKey: .status)
            try container.encodeIfPresent(level, forKey: .promotedToLevel)
        }
    }
}

/// Why a Host will not run a Plugin's declared Candidate Contracts. The
/// message is what the Library shows for a refused install or a Refused
/// Plugin, and what that Plugin's unavailable Menu Items show.
///
/// Each case's `plugin` is the Plugin's display name, its manifest `name`,
/// since only the user reads it; `declared` is the revision the Plugin
/// declares that the Host refuses.
public enum CandidateContractRefusal: Error, Equatable, LocalizedError {
    case notProvided(plugin: String, declared: CandidateContractRevision)
    case revisionMismatch(plugin: String, declared: CandidateContractRevision, provided: Int)
    case retired(plugin: String, declared: CandidateContractRevision, promotedToLevel: Int?)
    case needsLevel(plugin: String, declared: CandidateContractRevision, baseLevel: Int, declaredLevel: Int)
    case missingDependency(plugin: String, declared: CandidateContractRevision, needs: CandidateContractRevision)
    /// The Plugin declares `candidate` and `conflictingCandidate`, one of
    /// which excludes the other.
    case conflict(plugin: String, candidate: String, conflictingCandidate: String)
    /// A Bundled Plugin declares `candidate`; it may use stable Levels only.
    case bundled(plugin: String, candidate: String)

    public var errorDescription: String? {
        switch self {
        case let .notProvided(plugin, declared):
            return "\(plugin) needs revision \(declared.revision) of the \(declared.name) Candidate Contract, "
                + "which this version of Spinnet does not provide."
        case let .revisionMismatch(plugin, declared, provided):
            return "\(plugin) needs revision \(declared.revision) of the \(declared.name) Candidate Contract, "
                + "but this version of Spinnet provides revision \(provided). Candidate revisions must match exactly."
        case let .retired(plugin, declared, level?):
            return "\(plugin) declares revision \(declared.revision) of the \(declared.name) Candidate Contract, "
                + "which became Plugin API Level \(level). Install a revision of the Plugin that declares "
                + "Level \(level) instead."
        case let .retired(plugin, declared, nil):
            return "\(plugin) declares revision \(declared.revision) of the \(declared.name) Candidate Contract, "
                + "which this version of Spinnet no longer provides."
        case let .needsLevel(plugin, declared, baseLevel, declaredLevel):
            return "Revision \(declared.revision) of the \(declared.name) Candidate Contract builds on Plugin API "
                + "Level \(baseLevel), but \(plugin) declares Level \(declaredLevel)."
        case let .missingDependency(plugin, declared, needs):
            return "Revision \(declared.revision) of the \(declared.name) Candidate Contract needs revision "
                + "\(needs.revision) of the \(needs.name) Candidate Contract, which \(plugin) does not declare."
        case let .conflict(plugin, first, second):
            return "\(plugin) declares the \(first) and \(second) Candidate Contracts, which cannot be used together."
        case let .bundled(plugin, name):
            return "\(plugin) ships with Spinnet, so it may use only stable Plugin API Levels, not the \(name) "
                + "Candidate Contract."
        }
    }
}

/// What a Host offers through the Documented Plugin Interface: the members
/// of each stable Plugin API Level, and the Candidate Contract revisions it
/// provides or has retired. Installation, review, registration at launch and
/// every scripted run check a Plugin against them.
public struct PluginInterfaceContracts: Equatable {
    /// The members each stable Level adds, from Level 1 up without gaps.
    public let levels: [Int: Set<PluginInterfaceMember>]
    /// Every candidate revision this Host knows of, provided or retired.
    public let candidates: [CandidateContract]

    public init(levels: [Int: Set<PluginInterfaceMember>], candidates: [CandidateContract] = []) {
        self.levels = levels
        self.candidates = candidates
    }

    /// The highest stable Level, which `spinnet.environment.apiLevel` reports.
    public var highestStableLevel: Int { levels.keys.max() ?? 0 }

    /// What Plugin API Level 1 offers, as `PluginAPI/README.md` catalogues it.
    public static let levelOneMembers: Set<PluginInterfaceMember> = Set(
        PluginHostService.allCases.map { .hostService($0.rawValue) }
            + ["settings", "form", "detail", "actions"].map(PluginInterfaceMember.viewComponent)
            + ["copy_text", "open_url", "insert_text", "open_plugin_settings"].map(PluginInterfaceMember.standardAction)
            + ["field_changed", "submitted", "action_chosen", "setting_changed", "settings_swapped",
               "section_delivered"].map(PluginInterfaceMember.viewEvent)
    )

    /// This Host: Level 1, and no Candidate Contract yet. A Level added
    /// later is keyed at its own number beside Level 1.
    public static let host = PluginInterfaceContracts(levels: [1: levelOneMembers])

    private func supported(_ declaration: CandidateContractRevision) -> CandidateContract? {
        candidates.first { $0.declaration == declaration && $0.status == .supported }
    }

    /// Throws why this Host cannot run `manifest` from `origin`: a stable
    /// Level it does not support, or a declared candidate it does not provide
    /// at exactly that revision, without what it needs, or beside one it
    /// excludes. A Bundled Plugin may declare no candidate.
    public func check(_ manifest: PluginManifest, origin: PluginOrigin) throws {
        guard manifest.apiLevel <= highestStableLevel else {
            throw UnsupportedPluginAPILevel(requiredBy: manifest, supportedLevel: highestStableLevel)
        }
        let plugin = manifest.name
        let declared = manifest.candidateContracts
        if let first = declared.first, origin == .bundled { throw CandidateContractRefusal.bundled(plugin: plugin, candidate: first.name) }
        for declaration in declared {
            if let known = candidates.first(where: { $0.declaration == declaration }),
               case .retired(let level) = known.status {
                throw CandidateContractRefusal.retired(plugin: plugin, declared: declaration, promotedToLevel: level)
            }
            guard let contract = supported(declaration) else {
                if let other = candidates.first(where: { $0.name == declaration.name && $0.status == .supported }) {
                    throw CandidateContractRefusal.revisionMismatch(plugin: plugin, declared: declaration,
                                                                    provided: other.revision)
                }
                throw CandidateContractRefusal.notProvided(plugin: plugin, declared: declaration)
            }
            guard contract.baseLevel <= manifest.apiLevel else {
                throw CandidateContractRefusal.needsLevel(plugin: plugin, declared: declaration, baseLevel: contract.baseLevel,
                                                          declaredLevel: manifest.apiLevel)
            }
            if let missing = contract.requires.first(where: { !declared.contains($0) }) {
                throw CandidateContractRefusal.missingDependency(plugin: plugin, declared: declaration, needs: missing)
            }
            if let other = declared.first(where: { other in
                other.name != declaration.name && (contract.conflicts.contains(other.name)
                    || supported(other)?.conflicts.contains(declaration.name) == true)
            }) {
                throw CandidateContractRefusal.conflict(plugin: plugin, candidate: declaration.name,
                                                        conflictingCandidate: other.name)
            }
        }
    }

    /// Whether `manifest` may use `member`: one of the stable Levels it
    /// declares, or a candidate it declares, offers it. `check` has already
    /// accepted the manifest.
    ///
    /// Only Host Service requests are held to it at run time. Every View
    /// Component, Standard Action and View Event is a Level 1 member, so
    /// checking them would refuse nothing yet; wire it into view parsing when
    /// a candidate first adds one.
    public func permits(_ member: PluginInterfaceMember, declaredBy manifest: PluginManifest) -> Bool {
        levels.contains { $0.key <= manifest.apiLevel && $0.value.contains(member) }
            || manifest.candidateContracts.contains { supported($0)?.members.contains(member) == true }
    }

    /// The Host after promoting the provided revision of candidate `name` to
    /// stable Level `level`, the next one: its members become that Level,
    /// earlier Levels stay as they are, and the revision is retired with the
    /// Level it became, so a Plugin still declaring it is told what to
    /// install instead.
    public func promoting(_ name: String, toLevel level: Int) throws -> PluginInterfaceContracts {
        guard let index = candidates.firstIndex(where: { $0.name == name && $0.status == .supported }) else {
            throw CandidateContractPromotionError.notProvided(candidate: name)
        }
        guard level == highestStableLevel + 1 else {
            throw CandidateContractPromotionError.notTheNextLevel(level, next: highestStableLevel + 1)
        }
        let candidate = candidates[index]
        var levels = levels
        levels[level] = Set(candidate.members)
        var candidates = candidates
        candidates[index] = CandidateContract(
            name: candidate.name, revision: candidate.revision, baseLevel: candidate.baseLevel,
            requires: candidate.requires, conflicts: candidate.conflicts, members: candidate.members,
            tag: candidate.tag, status: .retired(promotedToLevel: level)
        )
        return PluginInterfaceContracts(levels: levels, candidates: candidates)
    }
}

/// Why promotion tooling cannot promote a candidate. It concerns the Host's
/// own contracts, never a Plugin, so no user sees it.
public enum CandidateContractPromotionError: Error, Equatable, LocalizedError {
    /// The Host provides no revision of `candidate` to promote.
    case notProvided(candidate: String)
    /// Promotion assigns only the stable Level after the highest one.
    case notTheNextLevel(Int, next: Int)

    public var errorDescription: String? {
        switch self {
        case .notProvided(let candidate):
            return "No provided Candidate Contract is named \(candidate)"
        case let .notTheNextLevel(level, next):
            return "Promotion assigns the next stable Level, \(next), not Level \(level)"
        }
    }
}

/// A Refused Plugin: an installed Plugin this Host did not load at launch,
/// because its package is broken or it declares a Plugin API Level or
/// Candidate Contract revision the Host does not provide. It stays the
/// user's rather than being removed: the Library lists it with the reason
/// and can remove it, and its Menu Items, settings, storage and access
/// decisions stay for a Host that can run it.
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
