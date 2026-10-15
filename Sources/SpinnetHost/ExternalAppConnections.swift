import AppKit
import Combine
import SpinnetCore

/// One Host-owned connection service. Native inspection runs off the main
/// thread; synchronous availability on the main thread reads only a snapshot.
final class HostExternalAppConnections {
    private struct Key: Hashable {
        let owner: PluginOwnerAdmission
        let pluginID: PluginID
        let bundleID: String
    }
    private struct Snapshot {
        let status: ExternalAppConnectionStatus
        let expires: Date
    }
    private let adapter: ExternalAppConnectionAdapter
    private let work = DispatchQueue(label: "com.vulpsecula.Spinnet.external-app-connections", qos: .userInitiated)
    private let lock = NSLock()
    private var snapshots: [Key: Snapshot] = [:]
    private var inspecting: Set<Key> = []
    private var authorized: Set<Key> = []
    private var epochs: [PluginID: UInt64] = [:]
    var onChange: (() -> Void)?
    private var removeAuthorityObservers: (() -> Void)?

    func observeAuthority(registry: PluginRegistry, grants: PluginCapabilityGrantStore) {
        removeAuthorityObservers?()
        let owner = registry.observeInvalidation { [weak self] id in self?.invalidate(id) }
        let access = grants.observeChanges { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.onChange?() }
        }
        let revoked = grants.observeRevocation { [weak self] id in self?.invalidate(id) }
        removeAuthorityObservers = { [weak registry, weak grants] in
            registry?.removeInvalidationObserver(owner)
            grants?.removeChangeObserver(access)
            grants?.removeRevocationObserver(revoked)
        }
    }

    deinit { removeAuthorityObservers?() }

    init(adapter: ExternalAppConnectionAdapter = ExternalAppConnectionAdapter()) {
        self.adapter = adapter
    }

    func invalidate(_ pluginID: PluginID) {
        lock.lock()
        epochs[pluginID, default: 0] &+= 1
        snapshots = snapshots.filter { $0.key.pluginID != pluginID }
        authorized = authorized.filter { $0.pluginID != pluginID }
        lock.unlock()
    }

    /// A pending setup belongs to the authority lifetime in which it began.
    /// A later grant or identical package replacement cannot revive it, even
    /// after the sheet closes and its native connection attempt has finished.
    func authorityLifetime(for pluginID: PluginID) -> () -> Bool {
        lock.lock(); let epoch = epochs[pluginID, default: 0]; lock.unlock()
        return { [weak self] in
            guard let self else { return false }
            self.lock.lock(); defer { self.lock.unlock() }
            return self.epochs[pluginID, default: 0] == epoch
        }
    }

    func status(_ check: ExternalAppConnectionCheck) -> ExternalAppConnectionStatus {
        let key = Key(owner: check.admission, pluginID: check.package.manifest.id, bundleID: check.declaration.bundleID)
        guard Thread.isMainThread else { return inspect(check, key: key) }
        lock.lock()
        let snapshot = snapshots[key]
        let starts = (snapshot == nil || snapshot!.expires <= Date()) && !inspecting.contains(key)
        if starts { inspecting.insert(key) }
        lock.unlock()
        if starts {
            work.async { [weak self] in
                guard let self else { return }
                _ = self.inspect(check, key: key)
                self.lock.lock(); self.inspecting.remove(key); self.lock.unlock()
                DispatchQueue.main.async { [weak self] in self?.onChange?() }
            }
        }
        // Keep the last observation while refreshing. Returning busy for every
        // expired snapshot would make a Configuration Sheet's Save fail merely
        // because the user spent time entering its inputs. Registry authority is
        // always rechecked; initial placement and execution refresh on the worker.
        return snapshot?.status ?? .busy
    }

    private func inspect(_ check: ExternalAppConnectionCheck, key: Key) -> ExternalAppConnectionStatus {
        lock.lock(); let generation = epochs[key.pluginID, default: 0]; let known = authorized.contains(key); lock.unlock()
        let result = adapter.status(check, previouslyAuthorized: known)
        lock.lock(); defer { lock.unlock() }
        guard generation == epochs[key.pluginID, default: 0] else { return .ownerInvalid }
        if result.isConnected { authorized.insert(key) }
        else { authorized.remove(key) }
        snapshots[key] = Snapshot(status: result, expires: Date().addingTimeInterval(1))
        return result
    }

    func refresh(registry: PluginRegistry, checks: [ExternalAppConnectionCheck], completion: @escaping ([ExternalAppConnectionStatus]) -> Void) {
        work.async {
            let statuses = checks.map { registry.externalAppConnectionStatus(for: $0) }
            DispatchQueue.main.async { completion(statuses) }
        }
    }

    func connect(registry: PluginRegistry, grants: PluginCapabilityGrantStore, check: ExternalAppConnectionCheck,
                 completion: @escaping (ExternalAppConnectionStatus) -> Void) {
        let lifetime = ConnectionAttemptLifetime()
        lock.lock(); let attemptEpoch = epochs[check.package.manifest.id, default: 0]; lock.unlock()
        let ownerObserver = registry.observeInvalidation { id in
            if id == check.package.manifest.id { lifetime.invalidate() }
        }
        let grantObserver = grants.observeRevocation { id in
            if id == check.package.manifest.id { lifetime.invalidate() }
        }
        work.async { [self] in
            let stillAuthorized = {
                lifetime.isValid && registry.externalAppConnectionAuthorization(for: check).isAvailable
            }
            let result = adapter.connect(check, authorized: stillAuthorized)
            DispatchQueue.main.async {
                defer {
                    registry.removeInvalidationObserver(ownerObserver)
                    grants.removeRevocationObserver(grantObserver)
                }
                guard stillAuthorized() else { completion(.ownerInvalid); return }
                // A successful check is kept only for this authority lifetime.
                let key = Key(owner: check.admission, pluginID: check.package.manifest.id, bundleID: check.declaration.bundleID)
                self.lock.lock()
                guard self.epochs[check.package.manifest.id, default: 0] == attemptEpoch else {
                    self.lock.unlock()
                    completion(.ownerInvalid)
                    return
                }
                if result.isConnected { self.authorized.insert(key) }
                else { self.authorized.remove(key) }
                self.snapshots[key] = Snapshot(status: result, expires: Date().addingTimeInterval(1))
                self.lock.unlock()
                completion(result)
                self.onChange?()
            }
        }
    }
}

private final class ConnectionAttemptLifetime {
    private let lock = NSLock()
    private var valid = true
    var isValid: Bool { lock.lock(); defer { lock.unlock() }; return valid }
    func invalidate() { lock.lock(); valid = false; lock.unlock() }
}

/// A sheet's live connection state. Closing retires UI completions; neither a
/// successful read nor cancellation executes or replays a Plugin Command.
final class ExternalAppConnectionsModel: ObservableObject {
    struct Row: Identifiable {
        let check: ExternalAppConnectionCheck
        var status: ExternalAppConnectionStatus
        var id: String { check.declaration.bundleID }
    }
    @Published private(set) var rows: [Row]
    let pluginID: PluginID
    var placementCommandIDs: Set<CommandID>?
    private var grantObserver: UUID?
    private let registry: PluginRegistry
    private let grants: PluginCapabilityGrantStore
    private let service: HostExternalAppConnections
    private let authorityIsCurrent: () -> Bool
    private var generation: UInt64 = 0
    private var closed = false
    private var connecting = false
    var onConnected: (() -> Void)?

    init(pluginID: PluginID, registry: PluginRegistry, grants: PluginCapabilityGrantStore, service: HostExternalAppConnections) {
        self.pluginID = pluginID
        self.registry = registry; self.grants = grants; self.service = service
        authorityIsCurrent = service.authorityLifetime(for: pluginID)
        rows = registry.externalAppConnectionChecks(for: pluginID).map { Row(check: $0, status: .busy) }
        grantObserver = grants.observeChanges { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.refresh() }
        }
    }
    deinit { if let grantObserver { grants.removeChangeObserver(grantObserver) } }
    var isConnected: Bool {
        let required = rows.filter { row in
            placementCommandIDs.map { !Set(row.check.declaration.commandIDs).isDisjoint(with: $0) } ?? true
        }
        return authorityIsCurrent() && !required.isEmpty && required.allSatisfy {
            $0.status.isConnected && registry.externalAppConnectionAuthorization(for: $0.check).isAvailable
        }
    }

    func refresh(completion: ((Bool) -> Void)? = nil) {
        guard !closed else { completion?(false); return }
        guard !connecting else { return }
        generation &+= 1
        let revision = generation
        let checks = rows.map(\.check)
        service.refresh(registry: registry, checks: checks) { [weak self] statuses in
            guard let self, !self.closed, self.generation == revision else { return }
            self.rows = zip(checks, statuses).map { check, status in
                let authorization = self.registry.externalAppConnectionAuthorization(for: check)
                return Row(check: check, status: authorization.isAvailable ? status
                    : (authorization.reason == .capabilityDenied ? .capabilityDenied : .ownerInvalid))
            }
            completion?(self.isConnected)
        }
    }

    func connect(_ bundleID: String) {
        guard !closed, !connecting, let index = rows.firstIndex(where: { $0.id == bundleID }), rows[index].status != .busy else { return }
        generation &+= 1
        let revision = generation
        let check = rows[index].check
        connecting = true
        rows[index].status = .busy
        service.connect(registry: registry, grants: grants, check: check) { [weak self] status in
            guard let self, !self.closed, self.generation == revision,
                  let index = self.rows.firstIndex(where: { $0.id == bundleID }) else { return }
            self.connecting = false
            self.rows[index].status = status
            if self.isConnected { self.onConnected?() }
        }
    }

    func close() { closed = true; generation &+= 1; onConnected = nil }
}
