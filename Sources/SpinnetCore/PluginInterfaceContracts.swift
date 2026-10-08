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
        /// A Command that runs one Host Service directly, by the name its
        /// manifest gives in `host_command`.
        case hostCommand = "host_command"
        /// A Host Service a script's answer asks the Host to perform after
        /// the answer commits, by the name it gives in `perform`.
        case request
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
    public static func hostCommand(_ name: String) -> PluginInterfaceMember { .init(kind: .hostCommand, name: name) }
    public static func request(_ name: String) -> PluginInterfaceMember { .init(kind: .request, name: name) }
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

    /// The record of a revision the Host no longer provides, which is all
    /// it needs to refuse a Plugin declaring it.
    public static func retired(_ declaration: CandidateContractRevision, promotedToLevel level: Int?) -> CandidateContract {
        CandidateContract(name: declaration.name, revision: declaration.revision, baseLevel: 1, members: [],
                          tag: "plugin-api-candidate/\(declaration.name)/r\(declaration.revision)",
                          status: .retired(promotedToLevel: level))
    }

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
        PluginHostService.levelOne.map { .hostService($0.rawValue) }
            + HostCommand.allCases.map { .hostCommand($0.rawValue) }
            + ["settings", "form", "detail", "actions"].map(PluginInterfaceMember.viewComponent)
            + ["copy_text", "open_url", "insert_text", "open_plugin_settings"].map(PluginInterfaceMember.standardAction)
            + ["field_changed", "submitted", "action_chosen", "setting_changed", "settings_swapped",
               "section_delivered"].map(PluginInterfaceMember.viewEvent)
    )

    /// What Plugin API Level 2 adds (#79): the members of Candidate
    /// Contracts `namespaces` r1, `host_operations` r2 and `collections` r3,
    /// promoted together, and what has been appended to Level 2 since while
    /// it is open, each addition in its own term below.
    public static let levelTwoMembers: Set<PluginInterfaceMember> = Set(
        HostServiceCatalogue.promoted.members + HostOperationsContract.promoted.members
            + CollectionsContract.promoted.members
            + levelTwoAdditions
    )

    /// The members appended to Level 2 after its promotion, while it is open.
    public static let levelTwoAdditions: [PluginInterfaceMember] =
        // Styles, columns, icons, images and progress (#81).
        PagePresentation.members
            // The App in front and its exit (#83).
            + CurrentAppAddition.members
            // Resizable pages and adaptive Grid columns (#80).
            + PageSizing.members

    /// Every Candidate Contract revision this Host provided before Level 2,
    /// all retired into it.
    public static let retiredIntoLevelTwo: [CandidateContractRevision] = [
        HostServiceCatalogue.declaration,
        CandidateContractRevision(name: HostOperationsContract.name, revision: 1), HostOperationsContract.declaration,
        CandidateContractRevision(name: CollectionsContract.name, revision: 1),
        CandidateContractRevision(name: CollectionsContract.name, revision: 2), CollectionsContract.declaration
    ]

    /// This Host: Plugin API Levels 1 and 2, and no Candidate Contract. A
    /// Plugin still declaring a revision Level 2 retired is refused with the
    /// Level to declare instead. A Level added later is keyed at its own
    /// number.
    public static let host = PluginInterfaceContracts(
        levels: [1: levelOneMembers, 2: levelTwoMembers],
        candidates: retiredIntoLevelTwo.map { CandidateContract.retired($0, promotedToLevel: 2) }
    )

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
                if let other = candidates.filter({ $0.name == declaration.name && $0.status == .supported })
                    .max(by: { $0.revision < $1.revision }) {
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
        try HostServiceCatalogue.checkCommands(of: manifest, under: self)
    }

    /// Whether `manifest` may use `member`: one of the stable Levels it
    /// declares, or a candidate it declares, offers it. `check` has already
    /// accepted the manifest.
    ///
    /// Host Service requests are held to it at run time, scriptless
    /// Commands whenever the manifest is checked, and answers and views as
    /// they are read: `host_operations` adds the `operation` answer member,
    /// the `shows_insertion_target` view member and the
    /// `operation_finished` View Event, which only the Host sends.
    public func permits(_ member: PluginInterfaceMember, declaredBy manifest: PluginManifest) -> Bool {
        levels.contains { $0.key <= manifest.apiLevel && $0.value.contains(member) }
            || manifest.candidateContracts.contains { supported($0)?.members.contains(member) == true }
    }

    /// The Host after promoting candidate `name` to stable Level `level`,
    /// the next one; see `promoting(_:toLevel:)` for several at once.
    public func promoting(_ name: String, toLevel level: Int) throws -> PluginInterfaceContracts {
        try promoting([name], toLevel: level)
    }

    /// The Host after promoting candidates `names` together to stable Level
    /// `level`, the next one: the members of the latest provided revision of
    /// each become that Level, earlier Levels stay as they are, and every
    /// revision of them the Host provides is retired with the Level it
    /// became, so a Plugin still declaring one is told what to install
    /// instead. A candidate whose latest revision requires another the Host
    /// still provides is promoted only together with it.
    public func promoting(_ names: [String], toLevel level: Int) throws -> PluginInterfaceContracts {
        var latest: [CandidateContract] = []
        for name in names {
            guard let revision = candidates.filter({ $0.name == name && $0.status == .supported })
                .max(by: { $0.revision < $1.revision }) else {
                throw CandidateContractPromotionError.notProvided(candidate: name)
            }
            latest.append(revision)
        }
        guard level == highestStableLevel + 1 else {
            throw CandidateContractPromotionError.notTheNextLevel(level, next: highestStableLevel + 1)
        }
        for contract in latest {
            if let needed = contract.requires.first(where: { required in
                !names.contains(required.name) && supported(required) != nil
            }) {
                throw CandidateContractPromotionError.requiresUnpromoted(candidate: contract.name, needs: needed.name)
            }
        }
        var levels = levels
        levels[level] = Set(latest.flatMap(\.members))
        let candidates = candidates.map { candidate in
            guard names.contains(candidate.name), candidate.status == .supported else { return candidate }
            return CandidateContract(
                name: candidate.name, revision: candidate.revision, baseLevel: candidate.baseLevel,
                requires: candidate.requires, conflicts: candidate.conflicts, members: candidate.members,
                tag: candidate.tag, status: .retired(promotedToLevel: level)
            )
        }
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
    /// The latest revision of `candidate` requires `needs`, which the Host
    /// still provides as a candidate and which is not promoted with it.
    case requiresUnpromoted(candidate: String, needs: String)

    public var errorDescription: String? {
        switch self {
        case .notProvided(let candidate):
            return "No provided Candidate Contract is named \(candidate)"
        case let .notTheNextLevel(level, next):
            return "Promotion assigns the next stable Level, \(next), not Level \(level)"
        case let .requiresUnpromoted(candidate, needs):
            return "\(candidate) requires the \(needs) Candidate Contract, which must be promoted with it"
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
