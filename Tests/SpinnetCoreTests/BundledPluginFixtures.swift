import SpinnetCore
import SpinnetPluginTestKit

// Host tests that need a real Bundled Plugin package as input load it through
// the Plugin test kit. The Plugins' own behaviour is tested in
// BundledPluginTests.

/// The repository's Window Position package, registered the way the Host
/// registers a Plugin that ships with the app.
enum WindowPositionFixture {
    static func load() throws -> PluginPackage {
        try PluginUnderTest(named: "WindowPosition.spinnetplugin", origin: .bundled).package
    }
}

/// The repository's Translator package, registered the same way.
enum TranslatorFixture {
    static func load() throws -> PluginPackage {
        try PluginUnderTest(named: "Translator.spinnetplugin", origin: .bundled).package
    }
}
