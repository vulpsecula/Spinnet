// SPDX-License-Identifier: MIT

/// The sources of the `spinnet` SDK object, Level 1's `spinnet.js`, Level
/// 2's `spinnet-level-2.js` and the SDK of each Candidate Contract revision
/// the candidate Host provided, compiled into whatever links this module so
/// the helper never looks for a file at run time.
public enum SpinnetSDK {
    /// A script whose value is a function of `requestHostService` and the
    /// invocation's environment that returns the `spinnet` object.
    public static let source = String(decoding: PackageResources.spinnet_js, as: UTF8.self)

    /// `spinnet-level-2.js`: a script whose value is a function of
    /// `requestHostService`, the environment and Level 1's object that
    /// returns the `spinnet` object a Plugin declaring Plugin API Level 2
    /// runs with.
    public static let levelTwoSource = String(decoding: PackageResources.spinnet_level_2_js, as: UTF8.self)

    // The candidates' SDKs below are retired with their revisions: the Host
    // refuses a Plugin declaring one, so only a test running a Plugin
    // against the candidate Host, to check promotion, reaches them.

    /// `candidates/namespaces/r1/namespaces.js`: a script whose value is a
    /// function of `requestHostService`, the environment and Level 1's
    /// object that returns the `spinnet` object a Plugin declaring
    /// Candidate Contract `namespaces` r1 runs with.
    public static let namespacesSource = String(decoding: PackageResources.namespaces_js, as: UTF8.self)

    /// `candidates/host_operations/r1/host_operations.js`: a script whose
    /// value is a function of `requestHostService`, the environment and the
    /// namespaced object that returns the `spinnet` object a Plugin
    /// declaring Candidate Contract `host_operations` r1 runs with.
    public static let hostOperationsSource = String(decoding: PackageResources.host_operations_js, as: UTF8.self)

    /// `candidates/collections/r1/collections.js`: a script whose value is a
    /// function of `requestHostService`, the environment and the object
    /// `host_operations.js` built that returns the `spinnet` object a Plugin
    /// declaring Candidate Contract `collections` r1 or r2 runs with:
    /// revision 2 adds no builder.
    public static let collectionsSource = String(decoding: PackageResources.collections_js, as: UTF8.self)

    /// `candidates/collections/r3/collections-r3.js`: the same for a Plugin
    /// declaring `collections` r3, whose builders add windows, toggles,
    /// marks and `notify`.
    public static let collectionsRevisionThreeSource = String(decoding: PackageResources.collections_r3_js, as: UTF8.self)
}
