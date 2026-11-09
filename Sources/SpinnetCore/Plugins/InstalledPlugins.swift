import Foundation

/// The installed Plugins, looked up by Plugin or by an Action configured
/// from one of their Commands: what Menu presentation, the Library and the
/// Configuration Sheet ask about a Plugin, in one place.
///
/// Each lookup reads the registry's packages and Refused Plugins once, so a
/// Menu presented from it describes one state of the Library. Availability
/// and Presets are asked of the registry when they are wanted, since they
/// depend on authority and Plugin Settings that change between reads.
public struct InstalledPlugins {
    private let registry: PluginRegistry
    private let packages: [PluginID: PluginPackage]
    private let refused: [PluginID: RefusedPlugin]
    private let resourceAvailability: ((ActionConfiguration) -> ActionUnavailableReason?)?

    /// `resourceAvailability` is the Host's check of the resources an
    /// Action reaches, applied after its Plugin and Command are known.
    public init(
        registry: PluginRegistry,
        resourceAvailability: ((ActionConfiguration) -> ActionUnavailableReason?)? = nil
    ) {
        self.registry = registry
        (packages, refused) = registry.installed()
        self.resourceAvailability = resourceAvailability
    }

    // MARK: By Plugin

    /// The manifest of a loaded Plugin; nil for a Refused or missing one.
    public func manifest(_ pluginID: PluginID) -> PluginManifest? {
        packages[pluginID]?.manifest
    }

    /// The installed package of a loaded Plugin, which its icon pictures
    /// are read from.
    public func packageRoot(_ pluginID: PluginID) -> URL? {
        packages[pluginID]?.rootURL
    }

    /// The name of the Plugin's Menu Item Preset, which a Menu Item without
    /// an Alias shows.
    public func presetName(_ pluginID: PluginID) -> String? {
        manifest(pluginID)?.name
    }

    public func pluginIcon(_ pluginID: PluginID) -> IconDeclaration? {
        manifest(pluginID)?.icon
    }

    /// Whether the Plugin is installed, loaded or refused.
    public func isInstalled(_ pluginID: PluginID) -> Bool {
        packages[pluginID] != nil || refused[pluginID] != nil
    }

    /// The Refused Plugin with `pluginID`, if a launch refused it.
    public func refusedPlugin(_ pluginID: PluginID) -> RefusedPlugin? {
        refused[pluginID]
    }

    /// Whether no Plugin is installed, loaded or refused.
    public var isEmpty: Bool {
        packages.isEmpty && refused.isEmpty
    }

    /// The loaded Plugins' manifests, by ID.
    public var manifests: [PluginManifest] {
        packages.values.map(\.manifest).sorted { $0.id.rawValue < $1.id.rawValue }
    }

    /// The Refused Plugins, which the Library lists but offers no Preset of.
    public var refusedPlugins: [RefusedPlugin] {
        refused.values.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    /// The Library's Menu Item Presets, by name.
    public var menuItemPresets: [MenuItemPreset] {
        registry.menuItemPresets()
    }

    public func menuItemPreset(_ pluginID: PluginID) -> MenuItemPreset? {
        registry.menuItemPreset(for: pluginID)
    }

    // MARK: By Action

    /// The Command `action` was configured from, as its Plugin declares it
    /// now: a Plugin that later describes or pictures its Commands does so
    /// for existing Actions too.
    public func command(for action: ActionConfiguration) -> CommandDeclaration? {
        manifest(action.pluginID)?.command(action.commandID)
    }

    public func commandIcon(for action: ActionConfiguration) -> IconDeclaration? {
        command(for: action)?.icon
    }

    /// Whether `action` can run now, and why not.
    public func availability(of action: ActionConfiguration) -> ActionAvailability {
        registry.availability(for: action, resourceAvailability: resourceAvailability)
    }
}
