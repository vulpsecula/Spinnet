import Foundation

/// Level 3 operations; earlier Levels retain tools.read and tools.startTask.
public enum HomebrewAutoremove {
    public static let declaration = CandidateContractRevision(name: "homebrew_autoremove", revision: 1)
    public static let member = PluginInterfaceMember.behaviour("homebrew_autoremove")
    public static let contract = CandidateContract(name: declaration.name, revision: declaration.revision,
        baseLevel: 2, members: [member], tag: "plugin-api-candidate/homebrew_autoremove/r1")

    public static func check(_ input: JSONValue, service: String, permits: (PluginInterfaceMember) -> Bool) throws {
        let operation = input.value(atPointer: "/operation")
        let needsCandidate = input.value(atPointer: "/tool") == .string("homebrew") &&
            ((service == ReviewedToolReads.id && operation == .string("previewAutoremove")) ||
             (service == ReviewedToolTasksAddition.id && operation == .string("autoremove")))
        guard !needsCandidate || permits(member) else {
            throw PluginHostServiceError.unavailable("Homebrew autoremove requires Plugin API Level 3")
        }
    }

    public static func check(_ input: JSONValue, service: String, manifest: PluginManifest,
                             contracts: PluginInterfaceContracts = .host) throws {
        do { try contracts.check(manifest, origin: .installed) }
        catch { throw PluginHostServiceError.unavailable(error.localizedDescription) }
        try check(input, service: service, permits: contracts.permitting(manifest))
    }
}
