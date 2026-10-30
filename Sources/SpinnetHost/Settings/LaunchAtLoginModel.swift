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
    func requestStatus(completion: @escaping (LoginItemStatus) -> Void)
    func register() throws
    func unregister() throws
    func openSystemSettingsLoginItems()
}

extension LoginItemService {
    func requestStatus(completion: @escaping (LoginItemStatus) -> Void) { completion(status) }
}

/// `SMAppService.mainApp`: the login item for this app bundle itself.
final class AppBundleLoginItemService: LoginItemService {
    private let statusQueue = DispatchQueue(label: "com.vulpsecula.Spinnet.login-item-status", qos: .utility)
    private let serviceLock = NSLock()
    var status: LoginItemStatus {
        serviceLock.lock()
        defer { serviceLock.unlock() }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        case .notRegistered: return .notRegistered
        @unknown default: return .notRegistered
        }
    }

    func requestStatus(completion: @escaping (LoginItemStatus) -> Void) {
        statusQueue.async { completion(self.status) }
    }

    func register() throws {
        serviceLock.lock()
        defer { serviceLock.unlock() }
        try SMAppService.mainApp.register()
    }
    func unregister() throws {
        serviceLock.lock()
        defer { serviceLock.unlock() }
        try SMAppService.mainApp.unregister()
    }
    func openSystemSettingsLoginItems() { SMAppService.openSystemSettingsLoginItems() }
}

/// Launch at Login on the General page. The toggle always shows the system's
/// real state, read back after every change, and a refused change is
/// reported rather than shown as done.
final class LaunchAtLoginModel: ObservableObject {
    private let service: LoginItemService
    private lazy var backgroundRefresh = BackgroundStatusRefresh<LoginItemStatus>(
        request: { [service] completion in service.requestStatus(completion: completion) },
        apply: { [weak self] status in
            guard let self, self.status != status else { return }
            self.status = status
        }
    )
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
        case .requiresApproval: return localized("Launch at Login needs your approval in System Settings")
        case .enabled, .notRegistered, .notFound: return nil
        }
    }

    var needsApproval: Bool { status == .requiresApproval }

    func refresh() {
        backgroundRefresh.invalidate()
        status = service.status
    }

    func refreshAsynchronously() { backgroundRefresh.refresh() }

    func setEnabled(_ enabled: Bool) {
        backgroundRefresh.invalidate()
        do {
            if enabled { try service.register() } else { try service.unregister() }
            failure = nil
        } catch {
            failure = enabled
                ? localized("Spinnet could not turn on Launch at Login: \(error.localizedDescription)")
                : localized("Spinnet could not turn off Launch at Login: \(error.localizedDescription)")
        }
        refresh()
    }

    func openLoginItemsSettings() { service.openSystemSettingsLoginItems() }

    var accessibleNames: [String] {
        var names: [String] = []
        if let note { names.append(note) }
        if needsApproval { names.append(localized("Open Login Items Settings")) }
        if let failure { names.append(failure) }
        return names
    }
}
