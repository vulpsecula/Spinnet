/// A Host evaluation of the environment a Plugin's Commands need.
public struct PluginPrerequisite: Equatable, Sendable {
    public enum Kind: Equatable, Hashable, Sendable {
        case externalApp(bundleID: String, displayName: String)
        case systemPermission(PluginSystemPermission)
        case hostComponent(HostComponent)
    }

    public enum HostComponent: Equatable, Hashable, Sendable {
        case backgroundOperations
    }

    public let kind: Kind
    public let commandIDs: [CommandID]
    public let isSatisfied: Bool

    /// The repair to offer when this prerequisite is unmet.
    public var reason: ActionUnavailableReason {
        switch kind {
        case .externalApp(_, let name): return .externalAppMissing(name)
        case .systemPermission(.accessibility): return .systemPermissionDenied
        case .systemPermission(.screenRecording): return .screenRecordingDenied
        case .hostComponent(.backgroundOperations): return .backgroundOperationsRequired
        }
    }
}
