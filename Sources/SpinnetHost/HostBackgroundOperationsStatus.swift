import ServiceManagement
import SpinnetCore

/// Host-owned background authorization, independent of any Plugin grant.
enum HostBackgroundOperationsStatus: Equatable {
    case notEnabled, approvalRequired, enabled, unavailable

    static func current() -> Self {
        switch SMAppService.daemon(plistName: HomebrewSystemAuthorization.helperIdentifier + ".plist").status {
        case .notRegistered, .notFound: return .notEnabled
        case .requiresApproval: return .approvalRequired
        case .enabled: return .enabled
        @unknown default: return .unavailable
        }
    }
}
