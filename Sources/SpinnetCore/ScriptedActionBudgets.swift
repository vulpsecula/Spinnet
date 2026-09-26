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

    // MARK: View Sessions

    // ADR-0010's initial limits. W13 (#60) measures View Sessions and then
    // confirms or changes them, here and in the ADR together.

    /// Largest state, as UTF-8 JSON, a script may keep in the Host between
    /// View Events.
    public static let viewStateBytes = 64 * 1024

    /// Largest Plugin View description, as UTF-8 JSON.
    public static let viewDescriptionBytes = 256 * 1024

    /// Wall-clock deadline for one View Event's invocation: the Action
    /// deadline, since each event is an ordinary bounded invocation.
    public static var viewEventDeadline: TimeInterval { actionDeadline }

    /// How long field changes must pause before the latest is delivered.
    public static let fieldChangeDebounce: TimeInterval = 0.1

    /// The longest a non-responsive Action can take to reach a user-visible
    /// terminal state: the deadline plus the forced-termination grace period.
    /// ADR-0007 states this as 4.25 seconds.
    public static var terminalStateCeiling: TimeInterval {
        actionDeadline + helperGracefulExit
    }
}
