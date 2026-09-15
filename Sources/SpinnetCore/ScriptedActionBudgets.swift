import Foundation

/// Every budget ADR-0007 promises for a scripted Action and its per-Plugin
/// helper, in one place.
///
/// These values are part of the Documented Plugin Interface: a Plugin author
/// reads them as guarantees, so changing one changes a published contract.
/// ADR-0007 remains the prose record of *why* each budget exists; this is the
/// only place that states *what* it is. Documentation cross-references these
/// names instead of repeating the numbers, and `ScriptedActionBudgetsTests`
/// asserts each one against the ADR so a silent edit fails the build.
public enum ScriptedActionBudgets {

    // MARK: Action lifecycle, visible to the user

    /// The Host shows progress with cancellation once an Action has run this
    /// long without finishing.
    public static let progressDelay: TimeInterval = 0.5

    /// Wall-clock deadline for one scripted Action. A helper that has not
    /// produced a terminal frame by then is terminated and reported through
    /// the stable failure path.
    public static let actionDeadline: TimeInterval = 4

    // MARK: Helper lifecycle

    /// How long a helper's Action queue stays empty before the Host requests
    /// a graceful exit.
    public static let helperIdleExit: TimeInterval = 30

    /// Grace period between the shutdown request and forced termination.
    public static let helperGracefulExit: TimeInterval = 0.25

    // MARK: Helper resources

    /// A helper is force-terminated once `consecutiveFootprintSamples`
    /// successive samples land at or above this `phys_footprint`.
    public static let helperPhysFootprintBytes: UInt64 = 64 * 1024 * 1024

    /// Interval between `phys_footprint` samples of a live helper.
    public static let footprintSampleInterval: TimeInterval = 0.1

    /// Samples at or above the limit required before terminating a helper.
    /// One spike is tolerated; two consecutive ones are not.
    public static let consecutiveFootprintSamples = 2

    // MARK: Wire format

    /// Largest accepted JSON message body, excluding its newline frame.
    /// Reached through `PluginRuntimeProtocol.maximumMessageBytes` at the
    /// codec, which is where callers already look for it.
    public static let maximumMessageBytes = 1_048_576

    /// The longest a non-responsive Action can take to reach a user-visible
    /// terminal state: the deadline plus the forced-termination grace period.
    /// ADR-0007 states this as 4.25 seconds.
    public static var terminalStateCeiling: TimeInterval {
        actionDeadline + helperGracefulExit
    }
}
