import SpinnetCore
import Foundation

/// A Stop trigger always starts the caller's bounded grace, whatever caused
/// it. Expiry does not reap the process or release its owning adapter's lane.
struct NativeStopGrace {
    private var deadline: TimeInterval?
    mutating func observe(triggered: Bool, now: TimeInterval, grace: TimeInterval, stop: () -> Void) {
        guard triggered, deadline == nil else { return }
        deadline = now + grace; stop()
    }
    func hasExpired(at now: TimeInterval) -> Bool { deadline.map { now >= $0 } ?? false }
}
