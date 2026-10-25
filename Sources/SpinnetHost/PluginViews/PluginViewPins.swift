import Foundation
import SpinnetCore

/// The Host's memory of each Plugin's Pin (ADR 0016): whether the user left
/// its view pinned, and, separately, where the pinned panel last was.
/// Unpinning forgets only the preference, so pinning again later starts
/// from the remembered geometry. It is a Host preference, not Plugin
/// Storage, and outlives the Host process; nothing reopens from it at
/// launch, it applies only when the Plugin's view next opens. Updating the
/// Plugin keeps it; removing the Plugin forgets it (#73).
final class PluginViewPins {
    private struct Entry: Codable {
        var isPinned = false
        var geometry: PluginPanelGeometry?
    }

    static let defaultsKey = "pluginViewPins"
    private let defaults: UserDefaults?
    private var entries: [String: Entry]

    /// `defaults` nil keeps the memory in this process only.
    init(defaults: UserDefaults?) {
        self.defaults = defaults
        entries = defaults?.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    func isPinned(_ pluginID: PluginID) -> Bool { entries[pluginID.rawValue]?.isPinned ?? false }

    func geometry(for pluginID: PluginID) -> PluginPanelGeometry? { entries[pluginID.rawValue]?.geometry }

    func setPinned(_ isPinned: Bool, for pluginID: PluginID) {
        entries[pluginID.rawValue, default: Entry()].isPinned = isPinned
        save()
    }

    func setGeometry(_ geometry: PluginPanelGeometry, for pluginID: PluginID) {
        guard entries[pluginID.rawValue]?.geometry != geometry else { return }
        entries[pluginID.rawValue, default: Entry()].geometry = geometry
        save()
    }

    /// Remembers where a pinned window is now. A window whose size is not
    /// the user's (a page that cannot be resized, or a Level 1 view) keeps
    /// a size the user chose earlier: only its top-left is taken, so the
    /// user's size comes back with the next resizable page (#80).
    func remember(_ geometry: PluginPanelGeometry, for pluginID: PluginID) {
        guard !geometry.isUserSized, let kept = self.geometry(for: pluginID), kept.isUserSized else {
            return setGeometry(geometry, for: pluginID)
        }
        let size = kept.frame.size
        setGeometry(PluginPanelGeometry(frame: NSRect(x: geometry.frame.minX, y: geometry.frame.maxY - size.height,
                                                      width: size.width, height: size.height),
                                        isUserSized: true), for: pluginID)
    }

    /// Forgets `pluginID`'s Pin and geometry, as when the Plugin is removed.
    func forget(_ pluginID: PluginID) {
        guard entries.removeValue(forKey: pluginID.rawValue) != nil else { return }
        save()
    }

    private func save() {
        guard let defaults, let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
