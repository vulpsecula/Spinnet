// SPDX-License-Identifier: MIT

/// The source of the `spinnet` SDK object, `spinnet.js`, compiled into
/// whatever links this module so the helper never looks for a file at run
/// time.
public enum SpinnetSDK {
    /// A script whose value is a function of `requestHostService` and the
    /// invocation's environment that returns the `spinnet` object.
    public static let source = String(decoding: PackageResources.spinnet_js, as: UTF8.self)
}
