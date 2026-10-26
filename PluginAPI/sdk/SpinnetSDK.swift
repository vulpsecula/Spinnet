// SPDX-License-Identifier: MIT

/// Current SDK sources embedded into the helper; no run-time file lookup.
public enum SpinnetSDK {
    public static let source = String(decoding: PackageResources.view_builders_js, as: UTF8.self)
    public static let currentSource = String(decoding: PackageResources.spinnet_js, as: UTF8.self)
    public static let adaptiveSource = String(decoding: PackageResources.adaptive_layout_js, as: UTF8.self)
    public static let autoremoveSource = String(decoding: PackageResources.autoremove_js, as: UTF8.self)
    public static let commandOutputSource = String(decoding: PackageResources.command_output_js, as: UTF8.self)
}
