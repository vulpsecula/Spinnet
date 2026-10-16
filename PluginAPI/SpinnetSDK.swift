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

    /// Exact opt-in Homebrew autoremove operations.
    public static let homebrewAutoremoveSource = String(decoding: PackageResources.homebrew_autoremove_js, as: UTF8.self)

    /// Exact opt-in adaptive_layout r1 candidate; its separate public source
    /// is evaluated over Level 2 only for a declaring Plugin.
    public static let adaptiveLayoutSource = String(decoding: PackageResources.adaptive_layout_js, as: UTF8.self)

    /// Exact opt-in adaptive_layout r2, including viewport fit and density.
    public static let adaptiveViewportSource = String(decoding: PackageResources.adaptive_layout_r2_js, as: UTF8.self)
}
