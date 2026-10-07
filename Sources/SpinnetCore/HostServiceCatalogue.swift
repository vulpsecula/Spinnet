import Foundation

/// Where a Plugin names a Host Service in the Plugin API catalogue
/// (Candidate Contract `namespaces`, ADR 0020).
public enum HostServiceEntryPoint: String, CaseIterable, Hashable {
    /// A script calls it inside its invocation: `spinnet.<id>(input)` or
    /// `requestHostService("<id>", input)`.
    case call
    /// A manifest Command runs it directly by naming it in `host_command`;
    /// no helper starts.
    case command
    /// A page or item action performs it on the user's gesture
    /// (`collections`).
    case viewAction = "view_action"
    /// An answer to a gesture requests it, performed after the answer
    /// commits (`host_operations`).
    case request
    /// A member of the answer itself is it: `toast` and `close`.
    case answer
    /// The Host sends it for a view: a Host-Fetched Section's request.
    case source
}

/// How the catalogue offers a Host Service at one entry point.
public enum HostServiceOffering: Hashable {
    /// Offered in its catalogue-ID form by `candidate`, or by Level 2 itself
    /// (`level_2`) for an addition made while Level 2 is open. `level1` says
    /// Plugin API Level 1 already offers it there under a Level 1 name.
    case offered(candidate: String, level1: Bool)
    /// Kept for a later revision or another ticket; naming it there is
    /// refused.
    case reserved
    case notOffered

    public var isOffered: Bool {
        if case .offered = self { return true }
        return false
    }

    /// The Candidate Contract, or `level_2`, that first offered it here.
    public var origin: String? {
        if case .offered(let candidate, _) = self { return candidate }
        return nil
    }
}

/// The System Permission a Host Service needs at every entry point.
/// Automation is asked for by macOS itself when an Apple Event is sent, so
/// the Host does not check it beforehand.
public enum HostServiceSystemPermission: String, Hashable {
    case accessibility
    case screenRecording = "screen_recording"
    case automation

    /// The permission the Host checks before performing the service.
    public var checked: PluginSystemPermission? {
        switch self {
        case .accessibility: return .accessibility
        case .screenRecording: return .screenRecording
        case .automation: return nil
        }
    }
}

/// A category a Host Service fails with, the same at every entry point.
public enum HostServiceFailure: String, Hashable {
    case capabilityDenied = "capability_denied"
    case systemPermissionDenied = "system_permission_denied"
    case automationPermissionDenied = "automation_permission_denied"
    case externalAppMissing = "external_app_missing"
    case externalAppOperationUnsupported = "external_app_operation_unsupported"
    case hostServiceFailed = "host_service_failed"
    case storageLimitExceeded = "storage_limit_exceeded"
    /// `host_operations`' failure for an insertion whose target changed.
    case insertionTargetChanged = "insertion_target_changed"
}

/// One Host Service of the Plugin API catalogue, under its one
/// `namespace.verb` ID: what it needs, how it fails, where it is offered,
/// and the Plugin API Level 1 names it replaces.
public struct HostServiceDefinition: Hashable {
    public let id: String
    /// Kept for a later revision or ticket: offered nowhere yet.
    public let isReserved: Bool
    public let capabilities: [PluginCapability]
    public let systemPermission: HostServiceSystemPermission?
    public let failures: [HostServiceFailure]
    /// The one required string member a bare string stands for, if any.
    public let primaryMember: String?
    /// The members its input object may have; empty when it takes none.
    public let inputMembers: [String]
    /// Only the entry points the catalogue states; any other is not offered.
    public let entryPoints: [HostServiceEntryPoint: HostServiceOffering]
    /// The Capabilities its Command form needs, when they differ from
    /// `capabilities`: a Command's input is what the user configured
    /// (decision N7).
    public let commandCapabilityOverride: [PluginCapability]?
    /// The Level 1 Host Services and Host Commands it replaces.
    public let levelOneHostServices: [PluginHostService]
    public let levelOneHostCommands: [HostCommand]

    /// The area of Spinnet's domain it belongs to.
    public var namespace: String { String(id.prefix { $0 != "." }) }

    public func offering(at entryPoint: HostServiceEntryPoint) -> HostServiceOffering {
        entryPoints[entryPoint] ?? .notOffered
    }

    public func isOffered(at entryPoint: HostServiceEntryPoint) -> Bool { offering(at: entryPoint).isOffered }

    /// The Capabilities a Command naming it needs.
    public var commandCapabilities: [PluginCapability] { commandCapabilityOverride ?? capabilities }
}

/// The Plugin API catalogue this Host provides: Plugin API Level 2's,
/// published in `PluginAPI/catalogue.json`, which Candidate Contract
/// `namespaces` revision 1 (`PluginAPI/candidates/namespaces/r1/`, retired
/// into Level 2) proved. Every operation has one ID, which a Level 2 Plugin
/// uses at every entry point; inside the Host each is routed to the
/// implementation Level 1 already has, so Level 1 names and catalogue IDs
/// reach the same effect. `promoted` is the retired revision's record,
/// whose members Level 2 holds; an offering's candidate names the revision
/// that first offered the ID there.
public enum HostServiceCatalogue {
    public static let candidateName = "namespaces"
    public static let revision = 1

    /// The rule that a declaring Plugin names operations by catalogue ID
    /// only, which also decides that its helper injects the namespaced SDK.
    public static let catalogueIDsOnly = PluginInterfaceMember.behaviour("catalogue_ids_only")

    /// The candidate's own declaration.
    public static var declaration: CandidateContractRevision {
        CandidateContractRevision(name: candidateName, revision: revision)
    }

    /// Candidate Contract `namespaces` r1 as its `candidate.json` published
    /// it: every ID a script may call, every ID a Command may run, and the
    /// rules a Level 2 Plugin gets.
    public static let promoted = CandidateContract(
        name: candidateName, revision: revision, baseLevel: 1,
        members: operations.filter { $0.offering(at: .call).origin == candidateName }.map { .hostService($0.id) }
            + operations.filter { $0.offering(at: .command).origin == candidateName }.map { .hostCommand($0.id) }
            + [catalogueIDsOnly.name, "primary_member_shorthand", "command_fixed_input", "configured_input_authority",
               "operation_failures_at_every_entry_point", "screen_capture_preferences", "namespaced_sdk"]
                .map(PluginInterfaceMember.behaviour),
        tag: "plugin-api-candidate/\(candidateName)/r\(revision)"
    )

    public static func operation(_ id: String) -> HostServiceDefinition? { operations.first { $0.id == id } }

    /// The IDs a Plugin declaring the catalogue names instead of a Level 1
    /// Host Service.
    public static func ids(replacing service: PluginHostService) -> [String] {
        operations.filter { $0.levelOneHostServices.contains(service) }.map(\.id)
    }

    /// The IDs a Plugin declaring the catalogue names instead of a Level 1
    /// Host Command; `clipboard.copy` divides by its input into two.
    public static func ids(replacing command: HostCommand) -> [String] {
        operations.filter { $0.levelOneHostCommands.contains(command) }.map(\.id)
    }

    // MARK: - The operations

    private static let ns = HostServiceOffering.offered(candidate: candidateName, level1: true)
    private static let nsNew = HostServiceOffering.offered(candidate: candidateName, level1: false)
    private static let collections = HostServiceOffering.offered(candidate: "collections", level1: true)
    private static let collectionsNew = HostServiceOffering.offered(candidate: "collections", level1: false)
    private static let operationsNew = HostServiceOffering.offered(candidate: "host_operations", level1: false)
    /// Added to Level 2 itself while it is open.
    private static let levelTwo = HostServiceOffering.offered(candidate: CurrentAppAddition.origin, level1: false)
    private static let calledOnly: [HostServiceEntryPoint: HostServiceOffering] = [
        .call: ns, .command: .notOffered, .viewAction: .notOffered, .request: .notOffered
    ]
    private static let performed: [HostServiceEntryPoint: HostServiceOffering] = [
        .call: ns, .command: ns, .viewAction: collections, .request: operationsNew
    ]
    private static let commandOnly: [HostServiceEntryPoint: HostServiceOffering] = [
        .call: .notOffered, .command: ns, .viewAction: .reserved, .request: .reserved
    ]
    private static let failures: [HostServiceFailure] = [.capabilityDenied, .hostServiceFailed]
    private static let permissionFailures: [HostServiceFailure] = [.capabilityDenied, .systemPermissionDenied, .hostServiceFailed]
    private static let keystrokeFailures: [HostServiceFailure] = [.systemPermissionDenied, .hostServiceFailed]

    private static func define(
        _ id: String, _ entryPoints: [HostServiceEntryPoint: HostServiceOffering],
        capabilities: [PluginCapability] = [], permission: HostServiceSystemPermission? = nil,
        failures: [HostServiceFailure] = [.hostServiceFailed], primary: String? = nil, input: [String] = [],
        commandCapabilities: [PluginCapability]? = nil, services: [PluginHostService] = [], commands: [HostCommand] = []
    ) -> HostServiceDefinition {
        HostServiceDefinition(id: id, isReserved: false, capabilities: capabilities, systemPermission: permission,
                              failures: failures, primaryMember: primary, inputMembers: input,
                              entryPoints: entryPoints, commandCapabilityOverride: commandCapabilities,
                              levelOneHostServices: services, levelOneHostCommands: commands)
    }

    private static func reserve(_ id: String, at reserved: [HostServiceEntryPoint],
                                source: Bool = false) -> HostServiceDefinition {
        var entryPoints: [HostServiceEntryPoint: HostServiceOffering] = [:]
        for entryPoint in [HostServiceEntryPoint.call, .command, .viewAction, .request] {
            entryPoints[entryPoint] = reserved.contains(entryPoint) ? .reserved : .notOffered
        }
        if source { entryPoints[.source] = .reserved }
        return HostServiceDefinition(id: id, isReserved: true, capabilities: [], systemPermission: nil,
                                     failures: [.hostServiceFailed], primaryMember: nil, inputMembers: [],
                                     entryPoints: entryPoints, commandCapabilityOverride: nil,
                                     levelOneHostServices: [], levelOneHostCommands: [])
    }

    /// Every operation, offered or reserved, in the catalogue's order.
    public static let operations: [HostServiceDefinition] = [
        define("host.toast", [.call: .notOffered, .command: ns, .viewAction: .notOffered, .request: .notOffered, .answer: ns],
               primary: "text", input: ["text"], commands: [.presentFeedback]),
        define("host.closeView", [.call: .notOffered, .command: .notOffered, .viewAction: .notOffered,
                                  .request: .notOffered, .answer: ns]),
        define("host.showPluginSettings", [.call: .notOffered, .command: nsNew, .viewAction: collections,
                                           .request: operationsNew]),
        reserve("host.confirm", at: [.request]),
        reserve("host.launchCommand", at: [.viewAction, .request]),

        define("selection.readText", calledOnly, capabilities: [.readSelectedText], permission: .accessibility,
               failures: permissionFailures, input: ["best_effort"], services: [.readSelectedText]),
        define("selection.replace", [.call: ns, .command: .reserved, .viewAction: collections, .request: operationsNew],
               capabilities: [.insertIntoFocusedApp], permission: .accessibility,
               failures: permissionFailures + [.insertionTargetChanged], primary: "text", input: ["text"],
               services: [.insertText]),
        define("selection.copy", commandOnly, capabilities: [.readSelectedText, .writeClipboard],
               permission: .accessibility, failures: permissionFailures, commands: [.copyText]),
        define("selection.cut", commandOnly, permission: .accessibility, failures: keystrokeFailures,
               commands: [.cutText]),
        define("selection.paste", commandOnly, permission: .accessibility, failures: keystrokeFailures,
               commands: [.pasteText]),
        reserve("selection.readFinderItems", at: [.call]),

        define("keyboard.press", commandOnly, permission: .accessibility, failures: keystrokeFailures,
               input: ["key", "key_code", "modifiers"], commands: [.invokeKeyboardShortcut]),

        define("clipboard.read", calledOnly, capabilities: [.readCurrentClipboard], failures: failures,
               services: [.readCurrentClipboard]),
        define("clipboard.write", performed, capabilities: [.writeClipboard], failures: failures, primary: "text",
               input: ["text"], services: [.writeClipboard], commands: [.copyText]),

        define("clipboardHistory.read", calledOnly, capabilities: [.readClipboardHistory], failures: failures,
               input: ["offset"], services: [.readClipboardHistory]),
        define("clipboardHistory.readContent", calledOnly, capabilities: [.readClipboardHistory], failures: failures,
               input: ["entry_id", "offset", "length"], services: [.readClipboardHistoryContent]),
        define("clipboardHistory.show", [.call: ns, .command: nsNew, .viewAction: collectionsNew, .request: operationsNew],
               capabilities: [.readClipboardHistory], failures: failures, services: [.presentClipboardHistory]),

        define("open.url", performed, capabilities: [.openURL], failures: failures, primary: "url", input: ["url"],
               commandCapabilities: [], services: [.openURL], commands: [.openURL]),
        define("open.path", [.call: ns, .command: ns, .viewAction: collectionsNew, .request: operationsNew],
               capabilities: [.openLocalPath], failures: failures, primary: "path", input: ["path"],
               commandCapabilities: [], services: [.openLocalPath], commands: [.openFile, .openFolder]),
        define("open.application", [.call: nsNew, .command: ns, .viewAction: collectionsNew, .request: operationsNew],
               capabilities: [.openLocalPath], failures: failures, primary: "application", input: ["application"],
               commandCapabilities: [], commands: [.openApplication]),
        reserve("open.reveal", at: [.call, .command, .viewAction, .request]),

        define("apps.perform", [.call: ns, .command: nsNew, .viewAction: collectionsNew, .request: operationsNew],
               capabilities: [.controlExternalApp], permission: .automation,
               failures: [.capabilityDenied, .automationPermissionDenied, .externalAppMissing,
                          .externalAppOperationUnsupported, .hostServiceFailed],
               input: ["bundle_id", "operation", "arguments"], services: [.performAppOperation]),
        define("apps.openDeepLink", [.call: ns, .command: ns, .viewAction: collectionsNew, .request: operationsNew],
               capabilities: [.controlExternalApp], failures: [.capabilityDenied, .externalAppMissing, .hostServiceFailed],
               input: ["template", "parameters"], services: [.openDeepLink], commands: [.openDeepLink]),
        // The App in front and its exit (#83), appended to Level 2.
        define(CurrentAppAddition.frontmostID, [.call: levelTwo, .command: .notOffered, .viewAction: .notOffered,
                                                .request: .notOffered],
               capabilities: [.readFrontmostApp], failures: failures, services: []),
        define(CurrentAppAddition.quitID, [.call: .notOffered, .command: .reserved, .viewAction: levelTwo,
                                           .request: levelTwo],
               capabilities: [.quitFrontmostApp], failures: failures, input: ["target", "force"]),

        define("system.runShortcut", [.call: .reserved, .command: ns, .viewAction: .reserved, .request: .reserved],
               primary: "name", input: ["name", "input"], commands: [.invokeShortcut]),
        define("system.runService", [.call: .reserved, .command: ns, .viewAction: .reserved, .request: .reserved],
               primary: "name", input: ["name", "input"], commands: [.invokeService]),
        reserve("system.keepAwake", at: [.command, .viewAction, .request]),
        reserve("system.metrics", at: [.call], source: true),

        define("window.read", calledOnly, capabilities: [.positionFocusedWindow], permission: .accessibility,
               failures: permissionFailures, services: [.readFocusedWindow]),
        define("window.setFrame", calledOnly, capabilities: [.positionFocusedWindow], permission: .accessibility,
               failures: permissionFailures, input: ["x", "y", "width", "height"], services: [.setFocusedWindowFrame]),
        define("window.toggleFullScreen", [.call: ns, .command: nsNew, .viewAction: .reserved, .request: .reserved],
               capabilities: [.positionFocusedWindow], permission: .accessibility, failures: permissionFailures,
               services: [.toggleFocusedWindowFullScreen]),
        define("window.restore", [.call: ns, .command: nsNew, .viewAction: .reserved, .request: .reserved],
               capabilities: [.positionFocusedWindow], permission: .accessibility, failures: permissionFailures,
               services: [.restoreFocusedWindowFrame]),

        define("screen.capture", [.call: ns, .command: ns, .viewAction: .reserved, .request: .reserved],
               capabilities: [.captureScreen], permission: .screenRecording, failures: permissionFailures,
               primary: "source", input: ["source", "copy_to_clipboard", "save"],
               services: [.captureScreen], commands: [.captureArea, .captureFullScreen, .captureWindow]),

        define("http.request", [.call: ns, .command: .notOffered, .viewAction: .notOffered, .request: .notOffered,
                                .source: ns],
               capabilities: [.contactHTTPS], failures: failures, services: [.httpsRequest]),

        define("text.detectLanguage", calledOnly, primary: "text", input: ["text"], services: [.detectLanguage]),

        define("storage.get", calledOnly, primary: "key", input: ["key"], services: [.getStorageValue]),
        define("storage.set", calledOnly, failures: [.hostServiceFailed, .storageLimitExceeded], input: ["key", "value"],
               services: [.setStorageValue]),
        define("storage.remove", calledOnly, primary: "key", input: ["key"], services: [.removeStorageValue]),
        define("storage.keys", calledOnly, services: [.listStorageKeys]),
        define("storage.clear", calledOnly, services: [.clearStorage]),

        reserve("activities.list", at: [.call]),
        reserve("activities.stop", at: [.viewAction, .request]),
        reserve("tools.read", at: [.call]),
        reserve("tools.startTask", at: [.viewAction, .request])
    ]
}

// MARK: - Refusals

/// Why the Host refuses the name a Plugin gives a Host Service. The message
/// names the operation by its ID and, for a Level 1 name, the ID to use
/// instead. A Command's refusal is what the Library shows; a call's ends the
/// invocation with `host_service_failed`.
public enum HostServiceRefusal: Error, Equatable, LocalizedError {
    /// Where the name was given: a script's call, or a manifest Command.
    public enum Use: Equatable {
        case call
        case command(CommandID, plugin: String)
    }

    /// A Plugin declaring the catalogue named a Plugin API Level 1 name.
    case levelOneName(String, replacements: [String], use: Use)
    /// The ID is reserved where it was named.
    case reserved(String, use: Use)
    /// The catalogue does not offer the ID where it was named.
    case notOffered(String, use: Use)
    /// No operation of the catalogue has this ID.
    case notCatalogued(String, use: Use)
    /// The ID belongs to a Candidate Contract the Plugin does not declare.
    case undeclared(String, apiLevel: Int, plugin: String, use: Use)
    /// A Command names an operation it may run, with input it may not give.
    case invalidCommand(CommandID, plugin: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .levelOneName(name, replacements, .call):
            return "\(name) is a Plugin API Level 1 name; a Plugin API Level 2 Plugin calls "
                + replacements.joined(separator: " or ")
        case let .levelOneName(name, replacements, .command(command, plugin)):
            return "Command \(command.rawValue) of \(plugin) names \(name), a Plugin API Level 1 Host Command; a Plugin "
                + "API Level 2 Plugin names it \(replacements.joined(separator: " or "))."
        case let .reserved(id, .call):
            return "\(id) is reserved: no Plugin API Level lets a script call it yet"
        case let .reserved(id, .command(command, plugin)):
            return "Command \(command.rawValue) of \(plugin) names \(id), which is reserved: no Plugin API Level runs "
                + "it as a Command yet."
        case let .notOffered(id, .call):
            let hint = HostServiceCatalogue.operation(id)?.isOffered(at: .command) == true ? "; a Command can run it" : ""
            return "\(id) cannot be called from a script\(hint)"
        case let .notOffered(id, .command(command, plugin)):
            return "Command \(command.rawValue) of \(plugin) names \(id), which cannot run as a Command."
        case let .notCatalogued(name, .call):
            return "\(name) is not a Host Service of the Plugin API catalogue"
        case let .notCatalogued(name, .command(command, plugin)):
            return "Command \(command.rawValue) of \(plugin) names \(name), which is not a Host Service of the Plugin "
                + "API catalogue."
        case let .undeclared(id, level, plugin, .call):
            return "\(id) is not part of Plugin API Level \(level) or a Candidate Contract \(plugin) declares"
        case let .undeclared(id, level, plugin, .command(command, _)):
            return "Command \(command.rawValue) of \(plugin) names \(id), which is not part of Plugin API Level \(level) "
                + "or a Candidate Contract \(plugin) declares."
        case let .invalidCommand(command, plugin, reason):
            return "Command \(command.rawValue) of \(plugin): \(reason)."
        }
    }
}

// MARK: - Commands

public extension HostServiceCatalogue {
    /// The operation a Command opens a Deep Link Template with, which names
    /// its template in `deep_link_template` as Level 1's `deep_link.open` does.
    static let deepLinkOperation = "apps.openDeepLink"

    /// Why `name` cannot be used at `entryPoint`: reserved there, not
    /// offered there, or not an ID at all.
    static func refusal(for name: String, at entryPoint: HostServiceEntryPoint,
                        use: HostServiceRefusal.Use) -> HostServiceRefusal {
        guard let operation = operation(name) else { return .notCatalogued(name, use: use) }
        return operation.offering(at: entryPoint) == .reserved ? .reserved(name, use: use) : .notOffered(name, use: use)
    }

    /// Holds `manifest`'s scriptless Commands to what it declares, when it
    /// is reviewed, installed or registered and before each run. A Plugin
    /// declaring the catalogue names each Command's Host Service by an ID
    /// offered as a Command, with input that belongs to it (decisions N5 and
    /// N8); a Plugin that does not keeps Level 1's Host Commands.
    static func checkCommands(of manifest: PluginManifest, under contracts: PluginInterfaceContracts) throws {
        let usesIDs = contracts.permits(catalogueIDsOnly, declaredBy: manifest)
        for command in manifest.commands where command.execution == .host {
            let use = HostServiceRefusal.Use.command(command.id, plugin: manifest.name)
            if let levelOne = command.hostCommand {
                guard usesIDs else { continue }
                throw HostServiceRefusal.levelOneName(levelOne.rawValue, replacements: ids(replacing: levelOne), use: use)
            }
            guard let id = command.hostServiceID else { continue }
            guard contracts.permits(.hostCommand(id), declaredBy: manifest) else {
                guard usesIDs else {
                    throw HostServiceRefusal.undeclared(id, apiLevel: manifest.apiLevel, plugin: manifest.name, use: use)
                }
                throw refusal(for: id, at: .command, use: use)
            }
            guard let operation = operation(id), operation.isOffered(at: .command) else {
                throw HostServiceRefusal.notCatalogued(id, use: use)
            }
            try operation.check(command, of: manifest)
        }
    }
}

extension HostServiceDefinition {
    /// The members a Command must fix itself: what it captures, or which
    /// External App operation it sends.
    var membersACommandFixes: [String] {
        switch id {
        case "screen.capture": return ["source"]
        case "apps.perform": return ["bundle_id", "operation"]
        default: return []
        }
    }

    /// The input member configuration fields fill, keyed by their own
    /// names, rather than naming members themselves.
    var memberFilledByFields: String? {
        switch id {
        case "apps.perform": return "arguments"
        case HostServiceCatalogue.deepLinkOperation: return "parameters"
        default: return nil
        }
    }

    /// A Command fixes some members of the input in `input` and configures
    /// the rest, never one member both ways; a single configuration field
    /// supplies the primary member, or the whole input of an operation with
    /// none. It needs the Capabilities the operation needs as a Command.
    func check(_ command: CommandDeclaration, of manifest: PluginManifest) throws {
        func invalid(_ reason: String) -> HostServiceRefusal {
            .invalidCommand(command.id, plugin: manifest.name, reason: reason)
        }
        var fixed: [String: JSONValue] = [:]
        switch command.fixedInput {
        case nil: break
        case .object(let members)?: fixed = members
        default: throw invalid("\(id)'s input is an object of its members")
        }
        if let unknown = fixed.keys.sorted().first(where: { !inputMembers.contains($0) }) {
            throw invalid("\(id) takes no input member \(unknown)")
        }
        if id == HostServiceCatalogue.deepLinkOperation, fixed["template"] != nil {
            throw invalid("\(id) names its template in deep_link_template")
        }
        if command.configurationField != nil {
            if let primary = primaryMember {
                if fixed[primary] != nil { throw invalid("\(id)'s \(primary) is both fixed and configured") }
            } else if inputMembers.isEmpty {
                throw invalid("\(id) takes no input to configure")
            } else if !fixed.isEmpty {
                throw invalid("\(id)'s input is both fixed and configured")
            }
        }
        for key in command.configurationFields.compactMap(\.key) {
            if let filled = memberFilledByFields {
                if fixed[filled] != nil { throw invalid("\(id)'s \(filled) is both fixed and configured") }
                continue
            }
            guard inputMembers.contains(key) else { throw invalid("\(id) takes no input member \(key)") }
            if fixed[key] != nil { throw invalid("\(id)'s \(key) is both fixed and configured") }
        }
        if let missing = membersACommandFixes.first(where: { fixed[$0] == nil }) {
            throw invalid("\(id) needs \(missing) in the Command's input")
        }
        if id == "screen.capture", case .string(let source)? = fixed["source"], ScreenCaptureSource(rawValue: source) == nil {
            throw invalid("\(id) captures an area, fullscreen or a window, not \(source)")
        }
        if let capability = commandCapabilities.first(where: { !manifest.capabilities.contains($0) }) {
            throw invalid("\(id) needs Capability \(capability.rawValue)")
        }
    }
}

// MARK: - Calls

public extension PluginInterfaceContracts {
    /// The Host Service request a script's call makes, as the Host performs
    /// it, or why the Plugin may not make it. A Plugin declaring the
    /// catalogue calls by ID only (decision N5): a Level 1 name, a reserved
    /// ID or one not offered to a script is refused as a Host Service
    /// failure naming the ID. Any other Plugin calls Level 1's names, and a
    /// name it does not know is a broken message, as it always was.
    func resolve(_ call: PluginRuntimeHostServiceCall,
                 declaredBy manifest: PluginManifest) throws -> Result<PluginRuntimeHostServiceRequest, PluginHostServiceError> {
        func refuse(_ refusal: HostServiceRefusal) -> Result<PluginRuntimeHostServiceRequest, PluginHostServiceError> {
            .failure(.unavailable(refusal.localizedDescription))
        }
        guard permits(HostServiceCatalogue.catalogueIDsOnly, declaredBy: manifest) else {
            guard let service = PluginHostService(rawValue: call.name) else {
                throw PluginRuntimeError.protocolViolation("Host Service request is malformed")
            }
            guard permits(.hostService(service.rawValue), declaredBy: manifest) else {
                return refuse(.undeclared(service.rawValue, apiLevel: manifest.apiLevel, plugin: manifest.name, use: .call))
            }
            return .success(PluginRuntimeHostServiceRequest(invocationID: call.invocationID, actionID: call.actionID,
                                                            requestID: call.requestID, service: service, input: call.input))
        }
        if let levelOne = PluginHostService(rawValue: call.name), levelOne.isLevelOne {
            return refuse(.levelOneName(call.name, replacements: HostServiceCatalogue.ids(replacing: levelOne), use: .call))
        }
        guard permits(.hostService(call.name), declaredBy: manifest),
              let operation = HostServiceCatalogue.operation(call.name), operation.isOffered(at: .call) else {
            return refuse(HostServiceCatalogue.refusal(for: call.name, at: .call, use: .call))
        }
        do {
            let (service, input) = try operation.callImplementation(of: call.input)
            return .success(PluginRuntimeHostServiceRequest(invocationID: call.invocationID, actionID: call.actionID,
                                                            requestID: call.requestID, service: service, input: input,
                                                            operation: operation.id))
        } catch let error as PluginHostServiceError {
            return .failure(error)
        }
    }
}

public extension PluginRuntimeHostServiceRequest {
    /// Performs the request, so that invalid input is reported in the words
    /// of the ID the Plugin called rather than of the Level 1 Host Service
    /// that performs it.
    func namingItsOperation<T>(_ perform: () throws -> T) throws -> T {
        do {
            return try perform()
        } catch PluginHostServiceError.invalidInput(let message) where operation != nil {
            throw PluginHostServiceError.invalidInput(message.replacingOccurrences(of: service.rawValue, with: operation!))
        }
    }
}

extension HostServiceDefinition {
    /// The Level 1 Host Service that performs a call of this operation, and
    /// the input as that service takes it. A bare string or an object of the
    /// primary member alone are the same call (`primary_member_shorthand`);
    /// `screen.capture` with only a source follows the user's screenshot
    /// preferences (decision N9), which its Host Service performs for a
    /// request naming the operation.
    func callImplementation(of input: JSONValue) throws -> (PluginHostService, JSONValue) {
        let service: PluginHostService
        switch id {
        case "open.application":
            // Launching an application by path is already what
            // `open_local_path` grants (design 6.3).
            service = .openLocalPath
        case CurrentAppAddition.frontmostID:
            service = .identifyFrontmostApp
        default:
            guard levelOneHostServices.count == 1 else {
                throw PluginHostServiceError.unavailable("\(id) has no implementation for a call")
            }
            service = levelOneHostServices[0]
        }
        guard let primary = primaryMember else { return (service, input) }
        let value: JSONValue
        if case .string = input {
            value = input
        } else if case .object(let members) = input, members.count == 1, let member = members[primary],
                  case .string = member {
            value = member
        } else if id == "screen.capture" {
            // Level 1's options, which the Host Service reads as it always has.
            return (service, input)
        } else {
            throw PluginHostServiceError.invalidInput("\(id) expects \(primary) as a string, or an object of \(primary) alone")
        }
        return (service, id == "screen.capture" ? .object([primary: value]) : value)
    }
}

// MARK: - Running a Command

/// Performs what a scriptless Command naming a catalogue ID needs besides a
/// Host Service: a Level 1 Host Command's effect with the input the
/// catalogue gives it, a toast near the pointer, and the Plugin's settings.
/// The Host's executor checks the Command's current authority itself, as it
/// does for a Level 1 Host Command.
public protocol CatalogueCommandExecutor: HostCommandExecutor {
    /// Performs `command`'s effect with `input` for `action`, whose Command
    /// names a catalogue ID that Level 1 performs as `command`.
    func perform(_ command: HostCommand, input: JSONValue, for action: ActionConfiguration,
                 in package: PluginPackage) throws -> JSONValue
    /// `host.toast`: a short message near the pointer (decision N2).
    func showToast(_ text: String, for action: ActionConfiguration) throws
    /// `host.showPluginSettings`: the Plugin's own Plugin Settings sheet.
    func showPluginSettings(for action: ActionConfiguration) throws
}

/// What running one catalogue Command comes to, with the input as the
/// implementation takes it.
enum HostServiceCommandStep: Equatable {
    case hostCommand(HostCommand, JSONValue)
    case hostService(PluginHostService, JSONValue)
    case toast(String)
    case pluginSettings
}

extension HostServiceDefinition {
    /// The operation's input for an Action of `command`: the Command's fixed
    /// members, then the configured ones. A single configuration field gives
    /// the primary member, or the whole input of an operation without one;
    /// configuration fields give the members they are keyed by, or for
    /// `apps.perform` its `arguments`.
    func commandInput(for command: CommandDeclaration, actionInput: JSONValue) -> JSONValue {
        var members: [String: JSONValue] = [:]
        if case .object(let fixed)? = command.fixedInput { members = fixed }
        if !command.configurationFields.isEmpty {
            let keys = Set(command.configurationFields.compactMap(\.key))
            let configured: [String: JSONValue]
            if case .object(let values) = actionInput { configured = values.filter { keys.contains($0.key) } } else { configured = [:] }
            if let filled = memberFilledByFields {
                members[filled] = .object(configured)
            } else {
                members.merge(configured) { _, new in new }
            }
        } else if actionInput != .null {
            if let primary = primaryMember {
                if case .object(let values) = actionInput, let value = values[primary] {
                    members[primary] = value
                } else {
                    members[primary] = actionInput
                }
            } else if case .object(let values) = actionInput {
                members.merge(values) { _, new in new }
            } else {
                return actionInput
            }
        }
        guard !members.isEmpty else { return .null }
        if let primary = primaryMember, members.count == 1, let value = members[primary], id != "screen.capture" {
            return value
        }
        return .object(members)
    }

    /// The implementation Level 1 already has for this operation's Command
    /// form, given its `input`. `isDirectory` says whether a path names an
    /// existing folder, so `open.path` opens whichever exists.
    func commandStep(input: JSONValue, isDirectory: (String) -> Bool) throws -> HostServiceCommandStep {
        func primaryText() throws -> String {
            switch input {
            case .string(let text): return text
            case .object(let members):
                if let primary = primaryMember, case .string(let text)? = members[primary] { return text }
            default: break
            }
            throw PluginHostServiceError.invalidInput("\(id) expects \(primaryMember ?? "its input") as text")
        }
        switch id {
        case "host.toast": return .toast(try primaryText())
        case "host.showPluginSettings": return .pluginSettings
        case "selection.copy": return .hostCommand(.copyText, .null)
        case "selection.cut": return .hostCommand(.cutText, .null)
        case "selection.paste": return .hostCommand(.pasteText, .null)
        case "keyboard.press": return .hostCommand(.invokeKeyboardShortcut, input)
        case "clipboard.write": return .hostCommand(.copyText, .string(try primaryText()))
        case "clipboardHistory.show": return .hostService(.presentClipboardHistory, .null)
        case "open.url": return .hostCommand(.openURL, .string(try primaryText()))
        case "open.path":
            let path = try primaryText()
            return .hostCommand(isDirectory(path) ? .openFolder : .openFile, .string(path))
        case "open.application": return .hostCommand(.openApplication, .string(try primaryText()))
        case "apps.perform": return .hostService(.performAppOperation, input)
        case "system.runShortcut": return .hostCommand(.invokeShortcut, input)
        case "system.runService": return .hostCommand(.invokeService, input)
        case "window.toggleFullScreen": return .hostService(.toggleFocusedWindowFullScreen, .null)
        case "window.restore": return .hostService(.restoreFocusedWindowFrame, .null)
        case "screen.capture":
            // Only a source: the user's screenshot preferences decide, as
            // they do for Level 1's three capture Commands (decision N9).
            if case .object(let members) = input, members.count == 1, case .string(let raw)? = members["source"],
               let source = ScreenCaptureSource(rawValue: raw) {
                switch source {
                case .area: return .hostCommand(.captureArea, .null)
                case .fullScreen: return .hostCommand(.captureFullScreen, .null)
                case .window: return .hostCommand(.captureWindow, .null)
                }
            }
            return .hostService(.captureScreen, input)
        default:
            throw PluginHostServiceError.unavailable("\(id) cannot run as a Command")
        }
    }
}

extension HostActionRunner {
    /// Runs a Command naming catalogue ID `action.hostServiceID`: no helper
    /// starts; the operation's input is assembled from the Command and the
    /// Action, and performed by the Host Service or Host Command Level 1
    /// performs it with. A failure is the operation's category, the same as
    /// a call's (design 6.5).
    func invokeCatalogueCommand(_ action: ActionConfiguration, in package: PluginPackage,
                                executor: HostCommandExecutor, broker: PluginHostServiceBroker?) -> ActionOutcome {
        do {
            guard let id = action.hostServiceID, let operation = HostServiceCatalogue.operation(id),
                  operation.isOffered(at: .command),
                  let command = package.manifest.commands.first(where: { $0.id == action.commandID }) else {
                throw PluginHostServiceError.unavailable("\(action.hostServiceID ?? action.commandID.rawValue) cannot run as a Command")
            }
            let result: JSONValue
            let step: HostServiceCommandStep
            if id == HostServiceCatalogue.deepLinkOperation {
                step = .hostService(.openDeepLink, try package.manifest.deepLinkRequest(for: action).input)
            } else {
                step = try operation.commandStep(input: operation.commandInput(for: command, actionInput: action.input),
                                                 isDirectory: Self.isExistingFolder)
            }
            switch step {
            case .hostService(let service, let input):
                guard let broker else { throw PluginHostServiceError.unavailable("No Host Service broker is configured") }
                let request = PluginRuntimeHostServiceRequest(invocationID: UUID().uuidString, actionID: action.id,
                                                              service: service, input: input, operation: id)
                result = try request.namingItsOperation { try broker.execute(request: request, for: package, action: action) }
            case .hostCommand(let hostCommand, let input):
                result = try catalogueExecutor(executor).perform(hostCommand, input: input, for: action, in: package)
            case .toast(let text):
                try catalogueExecutor(executor).showToast(text, for: action)
                result = .null
            case .pluginSettings:
                try catalogueExecutor(executor).showPluginSettings(for: action)
                result = .null
            }
            return ActionOutcome(actionID: action.id, pluginID: action.pluginID, title: action.title,
                                 terminal: .succeeded(result))
        } catch {
            let category: ActionFailureCategory
            switch error {
            case HostCommandExecutionError.capabilityDenied, PluginHostServiceError.capabilityDenied:
                category = .capabilityDenied
            case HostCommandExecutionError.systemPermissionDenied, PluginHostServiceError.systemPermissionDenied:
                category = .systemPermissionDenied
            case let error as PluginHostServiceError:
                category = error.actionFailureCategory
            default:
                category = .hostServiceFailed
            }
            return ActionOutcome(actionID: action.id, pluginID: action.pluginID, title: action.title,
                                 terminal: .failed(ActionFailure(pluginID: action.pluginID, actionID: action.id,
                                                                 category: category, message: error.localizedDescription)))
        }
    }

    private func catalogueExecutor(_ executor: HostCommandExecutor) throws -> CatalogueCommandExecutor {
        guard let executor = executor as? CatalogueCommandExecutor else {
            throw PluginHostServiceError.unavailable("This Host cannot run catalogue Commands")
        }
        return executor
    }

    private static func isExistingFolder(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
