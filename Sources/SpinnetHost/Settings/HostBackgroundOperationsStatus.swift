import Dispatch
import ServiceManagement
import SpinnetCore
import SpinnetReviewedTools

/// Host-owned background authorization, independent of any Plugin grant.
enum HostBackgroundOperationsStatus: Equatable {
    case notEnabled, approvalRequired, enabled, unavailable

    private static let statusQueue = DispatchQueue(label: "com.vulpsecula.Spinnet.background-operations-status", qos: .utility)

    /// ServiceManagement may wait for a system service. Keep that wait off the
    /// App activation callback; the refresh coordinator owns publication on main.
    static func requestCurrent(_ completion: @escaping (Self) -> Void) {
        statusQueue.async { completion(current()) }
    }

    static func current() -> Self {
        switch SMAppService.daemon(plistName: HomebrewSystemAuthorization.helperIdentifier + ".plist").status {
        case .notRegistered, .notFound: return .notEnabled
        case .requiresApproval: return .approvalRequired
        case .enabled: return .enabled
        @unknown default: return .unavailable
        }
    }
}
