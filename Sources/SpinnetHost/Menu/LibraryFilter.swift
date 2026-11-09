import SpinnetCore

/// One Library filter by Plugin Tag: every Preset, those declaring one
/// vocabulary tag, or those declaring none.
enum LibraryFilter: Hashable {
    case all
    case tag(PluginTag)
    case other

    func includes(_ preset: MenuItemPreset) -> Bool {
        switch self {
        case .all: return true
        case .tag(let tag): return preset.tags.contains(tag)
        case .other: return preset.tags.isEmpty
        }
    }

    /// The English title, which is also its catalog key.
    var englishTitle: String {
        switch self {
        case .all: return "All" // Not localized: the catalog key `title` looks up
        case .tag(let tag): return tag.title
        case .other: return "Other" // Not localized: the catalog key `title` looks up
        }
    }

    /// The title the Library shows, in the interface language.
    var title: String { localized(key: englishTitle) }
}
