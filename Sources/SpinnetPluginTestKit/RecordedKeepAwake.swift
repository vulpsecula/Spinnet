import Foundation
import SpinnetCore

/// Records OS assertion lifetime, not an internal collaborator. A failure
/// of either assertion must leave none held, just as on the actual Mac.
public final class RecordedPowerAssertions: PowerAssertions {
    public var failing: KeepAwakeAssertion?
    public var whileAcquiring: ((KeepAwakeAssertion) -> Void)?
    private var assertions: [UUID: KeepAwakeAssertion] = [:]
    public var held: Set<KeepAwakeAssertion> { Set(assertions.values) }
    public var count: Int { assertions.count }
    public init() {}
    public func acquire(_ assertion: KeepAwakeAssertion, reason: String) throws -> () -> Void {
        whileAcquiring?(assertion)
        guard failing != assertion else { throw PluginHostServiceError.failed("macOS refused the power assertion") }
        let id = UUID(); assertions[id] = assertion
        return { [weak self] in self?.assertions[id] = nil }
    }
}

/// Recorded time and power with the Host's real lifetime rules. Advance
/// time without keeping a script running; give `effects` and `activities`
/// to RecordedHostServices / RecordedHostOperations for real-helper probes.
public final class RecordedKeepAwake {
    public let activities = HostActivities()
    public let power = RecordedPowerAssertions()
    public let apps: RecordedApps
    private var now = Date(timeIntervalSince1970: 1_000)
    private var timers: [UUID: (Date, () -> Void)] = [:]
    public lazy var effects = HostKeepAwake(activities: activities, power: power, apps: apps, targets: apps.targets,
        now: { [unowned self] in self.now }, schedule: { [unowned self] delay, work in
            let id = UUID(); self.timers[id] = (self.now.addingTimeInterval(delay), work)
            return { [weak self] in self?.timers[id] = nil }
        })
    public init(apps: RecordedApps = RecordedApps()) { self.apps = apps }
    public func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
        let due = timers.filter { $0.value.0 <= now }.sorted { $0.value.0 < $1.value.0 }
        for (id, timer) in due { timers[id] = nil; timer.1() }
    }
}
