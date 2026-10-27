import Foundation
import ServiceManagement

/// The system's state of Spinnet's own login item.
enum LoginItemStatus: Equatable {
    case enabled
    case notRegistered
    /// Registered, but macOS still waits for the user to allow it in
    /// System Settings → General → Login Items.
    case requiresApproval
    /// macOS reports no such login item. Some macOS versions say so for a
    /// bundled app that never registered, so registering is still tried and
    /// any refusal reported.
    case notFound
}

/// The system's login item service for Spinnet's own app bundle.
protocol LoginItemService: AnyObject {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettingsLoginItems()
}

/// `SMAppService.mainApp`: the login item for this app bundle itself.
final class AppBundleLoginItemService: LoginItemService {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        case .notRegistered: return .notRegistered
        @unknown default: return .notRegistered
        }
    }

    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSystemSettingsLoginItems() { SMAppService.openSystemSettingsLoginItems() }
}

/// Launch at Login on the General page. The toggle always shows the system's
/// real state, read back after every change, and a refused change is
/// reported rather than shown as done.
final class LaunchAtLoginModel: ObservableObject {
    private let service: LoginItemService
    @Published private(set) var status: LoginItemStatus
    @Published private(set) var failure: String?

    init(service: LoginItemService) {
        self.service = service
        status = service.status
    }

    /// A login item awaiting approval is registered, so the toggle is on.
    var isOn: Bool { status == .enabled || status == .requiresApproval }
    /// What the page says under the toggle, if anything.
    var note: String? {
        switch status {
        case .requiresApproval: return "Launch at Login needs your approval in System Settings"
        case .enabled, .notRegistered, .notFound: return nil
        }
    }

    var needsApproval: Bool { status == .requiresApproval }

    func refresh() { status = service.status }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled { try service.register() } else { try service.unregister() }
            failure = nil
        } catch {
            failure = "Spinnet could not turn \(enabled ? "on" : "off") Launch at Login: \(error.localizedDescription)"
        }
        refresh()
    }

    func openLoginItemsSettings() { service.openSystemSettingsLoginItems() }

    var accessibleNames: [String] {
        var names: [String] = []
        if let note { names.append(note) }
        if needsApproval { names.append("Open Login Items Settings") }
        if let failure { names.append(failure) }
        return names
    }
}
