import Foundation

/// Typed unused-dependency previews and confirmed removal Tasks.
public enum HomebrewAutoremove {
    public static let member = PluginInterfaceMember.behaviour("homebrew_autoremove")
    public static let members = [member]

    public static func check(_ input: JSONValue, service: String, permits: (PluginInterfaceMember) -> Bool) throws {
        let operation = input.value(atPointer: "/operation")
        let needsFeature = input.value(atPointer: "/tool") == .string("homebrew") &&
            ((service == ReviewedToolReads.id && operation == .string("previewAutoremove")) ||
             (service == ReviewedToolTasksAddition.id && operation == .string("autoremove")))
        guard !needsFeature || permits(member) else {
            throw PluginHostServiceError.unavailable("Homebrew autoremove is not provided by this Host")
        }
    }

    public static func check(_ input: JSONValue, service: String, manifest: PluginManifest,
                             contracts: PluginInterfaceContracts = .host) throws {
        do { try contracts.check(manifest) }
        catch { throw PluginHostServiceError.unavailable(error.localizedDescription) }
        try check(input, service: service, permits: contracts.permitting(manifest))
    }
}
