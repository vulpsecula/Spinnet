import SpinnetCore
import Foundation

/// Fixed metadata from macOS Installer, never inferred from a tool exit code.
public enum HomebrewNativeInstallerContinuation: String, Codable {
    case none = "None", recommendRestart = "RecommendRestart"
    case requireRestart = "RequireRestart", requireLogout = "RequireLogout", requireShutdown = "RequireShutdown"
    case manualInstallation = "SpinnetManualInstallation"
    public static func parse(_ output: Data, exitStatus: Int32) throws -> Self {
        guard exitStatus == 0, output.count <= 64 * 1024,
              let text = String(data: output, encoding: .utf8),
              let value = Self(rawValue: text.trimmingCharacters(in: .whitespacesAndNewlines)), value != .manualInstallation else {
            throw PluginHostServiceError.unavailable("The macOS installer restart/logout/shutdown metadata is incomplete or unsupported")
        }
        return value
    }
    public var reason: String? {
        switch self { case .none, .recommendRestart: return nil
        case .requireRestart: return "restart_required"
        case .requireLogout: return "logout_required"
        case .requireShutdown: return "shutdown_required"
        case .manualInstallation: return "manual_installation_required" }
    }
    public var stage: String? {
        switch self { case .none, .recommendRestart: return nil
        case .requireRestart: return "awaiting restart"
        case .requireLogout: return "awaiting logout"
        case .requireShutdown: return "awaiting shutdown"
        case .manualInstallation: return "awaiting manual installation" }
    }
}
