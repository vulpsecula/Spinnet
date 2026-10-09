import Foundation

/// Additive Plugin API Level 2 effect and activity controls (#84).
public enum KeepAwakeAddition {
    public static let id = "system.keepAwake"
    public static let listID = "activities.list"
    public static let stopID = "activities.stop"
    public static let members: [PluginInterfaceMember] = [
        .hostCommand(id), .standardAction(id), .request(id), .hostService(listID),
        .standardAction(stopID), .request(stopID)
    ]
}

public struct KeepAwakeRequest: Equatable {
    public enum Mode: Equatable {
        case manual
        case duration(Int)
        case appAlive(String)
    }
    public static let maximumDuration = 86_400
    public let mode: Mode
    public init(mode: Mode = .manual) { self.mode = mode }

    public init(input: JSONValue) throws {
        guard case .object(let members) = input,
              case .string(let mode)? = members["mode"] else {
            throw PluginHostServiceError.invalidInput("system.keepAwake needs an object with mode")
        }
        switch mode {
        case "manual" where Set(members.keys) == ["mode"]: self.mode = .manual
        case "duration" where Set(members.keys) == ["mode", "seconds"]:
            guard case .number(let seconds)? = members["seconds"], seconds.isFinite,
                  seconds >= 1, seconds <= Double(Self.maximumDuration), seconds.rounded() == seconds else {
                throw PluginHostServiceError.invalidInput("system.keepAwake seconds must be an integer 1…86400")
            }
            self.mode = .duration(Int(seconds))
        case "app_alive" where Set(members.keys) == ["mode", "target"]:
            guard case .string(let target)? = members["target"], AppTargets.isWellFormed(target) else {
                throw PluginHostServiceError.invalidInput("system.keepAwake target must be an App Target")
            }
            self.mode = .appAlive(target)
        default: throw PluginHostServiceError.invalidInput("system.keepAwake has unknown mode or input members")
        }
    }

    public var json: JSONValue {
        switch mode {
        case .manual: return .object(["mode": .string("manual")])
        case .duration(let seconds): return .object(["mode": .string("duration"), "seconds": .number(Double(seconds))])
        case .appAlive(let target): return .object(["mode": .string("app_alive"), "target": .string(target)])
        }
    }

    public static func stopID(input: JSONValue) throws -> String {
        guard case .object(let members) = input, members.count == 1,
              case .string(let id)? = members["id"], id.hasPrefix("activity_"), id.count == 41,
              id.dropFirst(9).unicodeScalars.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else {
            throw PluginHostServiceError.invalidInput("activities.stop needs an activity id")
        }
        return id
    }
}

/// Only these two bounded OS assertions are exposed. They prevent idle
/// system and display sleep together, never explicit Sleep or lid closure.
public enum KeepAwakeAssertion: Hashable { case idleSystem, idleDisplay }
public protocol PowerAssertions: AnyObject {
    /// Creates one assertion and returns its release operation. Throws on
    /// failure; the caller releases an earlier assertion if the pair fails.
    func acquire(_ assertion: KeepAwakeAssertion, reason: String) throws -> () -> Void
}

/// Admission captures both package incarnation and effect authority before
/// dispatch; the latter changes on revoke/regrant as well as owner changes.
public struct KeepAwakeAdmission: Hashable {
    let registration: PluginOwnerAdmission
    let effect: EffectOwnerAdmission
}

public struct EffectOwnerAdmission: Hashable {
    let owner: PluginID
    let generation: Int
}

/// Effects owned by the Host, independent of helper and View Session life.
/// Time, power and running App identity are the only system boundaries.
public final class HostKeepAwake {
    public typealias Schedule = (TimeInterval, @escaping () -> Void) -> (() -> Void)
    private let activities: HostActivities
    private let power: PowerAssertions
    private let apps: RunningApps?
    private let targets: AppTargets?
    private let now: () -> Date
    private let schedule: Schedule
    private let lock = NSRecursiveLock()
    private var appBindings: [String: RunningAppIdentity] = [:]
    private var generations: [PluginID: Int] = [:]
    private var isShutdown = false

    public init(activities: HostActivities, power: PowerAssertions, apps: RunningApps? = nil, targets: AppTargets? = nil,
                now: @escaping () -> Date = Date.init, schedule: @escaping Schedule) {
        self.activities = activities; self.power = power; self.apps = apps; self.targets = targets
        self.now = now; self.schedule = schedule
        apps?.observeTerminations { [weak self] in self?.terminated($0) }
    }

    public func ownerAdmission(for owner: PluginID) -> EffectOwnerAdmission? {
        lock.lock(); defer { lock.unlock() }
        guard !isShutdown else { return nil }
        return EffectOwnerAdmission(owner: owner, generation: generations[owner, default: 0])
    }

    public func isCurrent(_ admission: EffectOwnerAdmission) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !isShutdown && generations[admission.owner, default: 0] == admission.generation
    }

    @discardableResult
    public func start(_ request: KeepAwakeRequest, owner: PluginID, pluginName: String,
                      admittedOwner: EffectOwnerAdmission? = nil,
                      authorize: () throws -> Void = {}) throws -> HostActivity {
        lock.lock()
        let generation = generations[owner, default: 0]
        let stopped = isShutdown
        lock.unlock()
        guard !stopped else { throw PluginHostServiceError.unavailable("The Host is exiting") }
        guard admittedOwner == nil || (admittedOwner?.owner == owner && admittedOwner?.generation == generation) else {
            throw PluginHostServiceError.unavailable("The accepted effect owner is no longer current")
        }
        // Read authority only after capturing the owner generation, outside
        // our lock: registry invalidation observers run under its own lock.
        // Any change while we acquire OS resources then invalidates this
        // generation, so late work cannot resurrect a stopped effect.
        try authorize()
        let bound: RunningAppIdentity?
        switch request.mode {
        case .appAlive(let target):
            guard let app = targets?.app(for: target, of: owner), apps?.facts(of: app) != nil else {
                throw PluginHostServiceError.unavailable("The App Target no longer names a running App")
            }
            bound = app
        case .duration(let seconds):
            guard (1...KeepAwakeRequest.maximumDuration).contains(seconds) else {
                throw PluginHostServiceError.invalidInput("system.keepAwake seconds must be an integer 1…86400")
            }
            bound = nil
        case .manual: bound = nil
        }
        let system = try power.acquire(.idleSystem, reason: "Spinnet Keep Awake")
        let display: () -> Void
        do { display = try power.acquire(.idleDisplay, reason: "Spinnet Keep Awake") }
        catch { system(); throw error }
        lock.lock()
        defer { lock.unlock() }
        guard !isShutdown, generations[owner, default: 0] == generation,
              bound == nil || apps?.facts(of: bound!) != nil else {
            display(); system()
            throw PluginHostServiceError.unavailable("The effect owner or bound App changed")
        }
        let expiry: Date?
        let status: String
        switch request.mode {
        case .manual: expiry = nil; status = "Until stopped"
        case .duration(let seconds): expiry = now().addingTimeInterval(Double(seconds)); status = "For \(seconds) seconds"
        case .appAlive: expiry = nil; status = "While \(bound!.name.prefix(256)) is running"
        }
        let cancellation = EffectTimer()
        let activity: HostActivity
        do {
            activity = try activities.register(owner: owner, pluginName: pluginName, kind: "keep_awake", status: status,
                                              expiresAt: expiry) { [weak self] in
                cancellation.cancel(); display(); system()
                guard let self else { return }
                self.lock.lock(); self.appBindings[cancellation.activityID] = nil; self.lock.unlock()
            }
        } catch { display(); system(); throw error }
        cancellation.activityID = activity.id
        guard activities.list(for: owner).contains(where: { $0.id == activity.id }) else { return activity }
        if let bound { appBindings[activity.id] = bound }
        if case .duration(let seconds) = request.mode {
            cancellation.install(schedule(Double(seconds)) { [weak activities] in activities?.stop(activity.id, for: owner) })
        }
        return activity
    }

    public func invalidate(_ owner: PluginID) {
        lock.lock(); defer { lock.unlock() }
        generations[owner, default: 0] += 1
        activities.list(for: owner).filter { $0.kind == "keep_awake" }.forEach { activities.stop($0.id, for: owner) }
    }

    public func shutdown() {
        lock.lock(); defer { lock.unlock() }
        isShutdown = true
        activities.list().filter { $0.kind == "keep_awake" }.forEach { activities.stop($0.id) }
    }

    private func terminated(_ app: RunningAppIdentity) {
        lock.lock(); defer { lock.unlock() }
        appBindings.filter { $0.value.isSameApp(as: app) }.keys.forEach { activities.stop($0) }
    }

    deinit { shutdown() }
}

/// A timer can fire or be stopped before its cancellation token arrives.
private final class EffectTimer {
    var activityID = ""
    private let lock = NSLock()
    private var cancelled = false
    private var stop: (() -> Void)?
    func install(_ stop: @escaping () -> Void) {
        lock.lock()
        if cancelled { lock.unlock(); stop() } else { self.stop = stop; lock.unlock() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let stop = self.stop; self.stop = nil; lock.unlock()
        stop?()
    }
}
