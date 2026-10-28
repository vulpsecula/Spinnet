import Foundation
import SpinnetCore

// Source compatibility for Plugin repositories written before the Host
// stopped shipping Plugins (#109). The Host no longer has a Plugin Origin:
// every Plugin is installed the same way. These shims live only in the test
// kit, accept the old `origin:` arguments and ignore them.

/// Retired: the Host ships no Plugins, so every Plugin is an installed one.
@available(*, deprecated, message: "The Host ships no Plugins; drop the origin argument.")
public enum PluginOrigin: String, Equatable, Sendable {
    case bundled
    case installed
}

extension PluginUnderTest {
    @available(*, deprecated, message: "The Host ships no Plugins; use init(packageAt:).")
    public init(packageAt url: URL, origin: PluginOrigin) throws {
        try self.init(packageAt: url)
    }

    @available(*, deprecated, message: "The Host ships no Plugins; use init(named:searchingFrom:).")
    public init(named name: String, origin: PluginOrigin, searchingFrom path: String = #filePath) throws {
        try self.init(named: name, searchingFrom: path)
    }
}

extension PluginPackage {
    /// Always `.installed`.
    @available(*, deprecated, message: "The Host ships no Plugins; every Plugin is installed.")
    public var origin: PluginOrigin { .installed }

    @available(*, deprecated, message: "The Host ships no Plugins; use init(rootURL:manifest:).")
    public init(rootURL: URL, manifest: PluginManifest, origin: PluginOrigin) {
        self.init(rootURL: rootURL, manifest: manifest)
    }
}

extension PluginInterfaceContracts {
    @available(*, deprecated, message: "The Host ships no Plugins; use check(_:).")
    public func check(_ manifest: PluginManifest, origin: PluginOrigin) throws {
        try check(manifest)
    }
}
