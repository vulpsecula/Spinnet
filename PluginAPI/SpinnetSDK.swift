// SPDX-License-Identifier: MIT

/// The sources of the `spinnet` SDK object, Level 1's `spinnet.js` and Level
/// 2's `spinnet-level-2.js`, compiled into whatever links this module so the
/// helper never looks for a file at run time.
public enum SpinnetSDK {
    /// A script whose value is a function of `requestHostService` and the
    /// invocation's environment that returns the `spinnet` object.
    public static let source = String(decoding: PackageResources.spinnet_js, as: UTF8.self)

    /// `spinnet-level-2.js`: a script whose value is a function of
    /// `requestHostService`, the environment and Level 1's object that
    /// returns the `spinnet` object a Plugin declaring Plugin API Level 2
    /// runs with.
    public static let levelTwoSource = String(decoding: PackageResources.spinnet_level_2_js, as: UTF8.self)
}
