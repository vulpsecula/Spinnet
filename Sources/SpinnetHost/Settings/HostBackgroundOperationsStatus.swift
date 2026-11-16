import Dispatch
import SpinnetCore
import SpinnetReviewedTools

/// Host-owned background authorization, independent of any Plugin grant.
enum HostBackgroundOperationsStatus: Equatable {
    case notEnabled, approvalRequired, enabled, unavailable

    private static let statusQueue = DispatchQueue(label: "com.vulpsecula.Spinnet.background-operations-status", qos: .utility)

    /// The Login Items status query may wait for a system service. Keep that wait off the
    /// App activation callback; the refresh coordinator owns publication on main.
    static func requestCurrent(_ completion: @escaping (Self) -> Void) {
        statusQueue.async { completion(current()) }
    }

    static func current() -> Self {
        switch HomebrewHelperInstallation.status() {
        case .notInstalled: return .notEnabled
        case .approvalRequired: return .approvalRequired
        case .installed: return .enabled
        }
    }
}
