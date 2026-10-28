import Foundation

/// A separately granted, fixed catalog update. Package mutations keep their
/// existing gesture and per-Task confirmation requirements at every API Level.
public enum HomebrewCatalogRefresh {
    public static let member = PluginInterfaceMember.behaviour("homebrew_catalog_refresh")
    public static let members = [member]
    public static let operation = "refreshCatalog"

    public static func isRefresh(_ request: RequestedHostOperation?) -> Bool {
        request?.perform == ReviewedToolTasksAddition.id && request?.input.value(atPointer: "/operation") == .string(operation)
    }
    public static func check(_ input: JSONValue, permits: (PluginInterfaceMember) -> Bool) throws {
        guard input.value(atPointer: "/operation") == .string(operation) else { return }
        guard permits(member) else { throw PluginHostServiceError.unavailable("Automatic catalog refresh is not provided by this Host") }
    }
    public static func check(_ input: JSONValue, manifest: PluginManifest) throws {
        try PluginInterfaceContracts.host.check(manifest)
        try check(input, permits: PluginInterfaceContracts.host.permitting(manifest))
    }
    public static func permitsStart(_ event: PluginViewEvent?) -> Bool {
        guard let event else { return true }
        switch event {
        case .called, .pageFieldChanged, .pageSubmitted, .pageActionChosen, .itemAction: return true
        default: return false
        }
    }
}
