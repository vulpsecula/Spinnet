import AppKit
import Darwin

/// Only one Spinnet runs at a time. Two can start together: System Settings'
/// Quit & Reopen reopens Spinnet while Spinnet reopens itself, and on a first
/// install the two name different copies of the app, such as a translocated
/// one, so LaunchServices starts both. Each then shows a Status Item and
/// takes the Menu Trigger, and one Quit leaves the other running.
///
/// The Spinnet that launched later leaves before it touches saved data, so
/// the one already running keeps what a relaunch left it to restore.
enum HostSingleInstance {
    struct Instance: Equatable {
        let processIdentifier: pid_t
        let launchDate: Date?
    }

    /// The running Spinnet this one should leave in favour of, if any: the
    /// earliest launched, with the lower process identifier breaking a tie,
    /// so two Spinnets starting together keep exactly one.
    static func instance(toDeferTo others: [Instance], from own: Instance) -> Instance? {
        others.filter { precedes($0, own) }.min { precedes($0, $1) }
    }

    private static func precedes(_ lhs: Instance, _ rhs: Instance) -> Bool {
        switch (lhs.launchDate, rhs.launchDate) {
        case let (left?, right?) where left != right: return left < right
        case (nil, _?): return true
        case (_?, nil): return false
        default: return lhs.processIdentifier < rhs.processIdentifier
        }
    }

    /// Hands over to a Spinnet already running and returns true, in which
    /// case this one must exit without starting anything.
    static func deferToRunningInstance() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return false }
        let current = NSRunningApplication.current
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).filter {
            // A Spinnet that just quit can linger in the list; only a live
            // process counts, or a relaunch would leave nothing running.
            $0.processIdentifier != current.processIdentifier && !$0.isTerminated && kill($0.processIdentifier, 0) == 0
        }
        let own = Instance(processIdentifier: current.processIdentifier, launchDate: current.launchDate)
        guard let target = instance(toDeferTo: running.map { Instance(processIdentifier: $0.processIdentifier, launchDate: $0.launchDate) },
                                    from: own),
              let other = running.first(where: { $0.processIdentifier == target.processIdentifier }) else { return false }
        HostLog.lifecycle.notice("Spinnet \(other.processIdentifier, privacy: .public) is already running; this launch exits")
        other.activate()
        return true
    }
}
