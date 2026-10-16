import Foundation
import SpinnetCore
import SpinnetPluginTestKit

// Fixed historical packages exercise Host mechanics. Current Plugin
// behaviour is tested in the independent SpinnetPlugins repository.

/// The historical Window Position package, registered the way the Host
/// registers a Plugin that ships with the app.
enum WindowPositionFixture {
    static func load() throws -> PluginPackage {
        try legacyPlugin("WindowPosition")
    }
}

/// The historical Translator package, registered the same way.
enum TranslatorFixture {
    static func load() throws -> PluginPackage {
        try legacyPlugin("Translator")
    }
}

private func legacyPlugin(_ name: String) throws -> PluginPackage {
    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fixtures/LegacyBundledPlugins")
    return try PluginUnderTest(packageAt: directory.appendingPathComponent(name + ".spinnetplugin"), origin: .bundled).package
}
