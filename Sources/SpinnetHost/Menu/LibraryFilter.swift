import SpinnetCore

/// One Library filter by Plugin Tag: every Preset, or those declaring one
/// vocabulary tag. A Preset declaring none is listed under All only.
enum LibraryFilter: Hashable {
    case all
    case tag(PluginTag)

    func includes(_ preset: MenuItemPreset) -> Bool {
        switch self {
        case .all: return true
        case .tag(let tag): return preset.tags.contains(tag)
        }
    }

    /// The English title, which is also its catalog key.
    var englishTitle: String {
        switch self {
        case .all: return "All" // Not localized: the catalog key `title` looks up
        case .tag(let tag): return tag.title
        }
    }

    /// The title the Library shows, in the interface language.
    var title: String { localized(key: englishTitle) }
}
