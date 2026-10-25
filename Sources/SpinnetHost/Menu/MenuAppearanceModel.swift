import Combine
import Foundation

/// Owns the Appearance shared by a Menu's Editor Mode and Runtime Mode: the
/// values themselves, their persistence in `UserDefaults`, and the undo history
/// over them.
///
/// Editing any value records one undo entry, except while a menu-size
/// adjustment session is open: a slider drag emits a continuous stream of
/// values that should collapse into a single entry, so the session brackets
/// them with `beginMenuSizeAdjustment()` and `endMenuSizeAdjustment()`.
///
/// `onChange` fires for every committed edit, including undo, redo and reset,
/// so a Menu presenting this Appearance can follow it without polling.
final class MenuAppearanceModel: ObservableObject {
    @Published var theme: String {
        willSet { recordWillChange() }
        didSet { commit(theme, forKey: MenuAppearanceConfiguration.themeDefaultsKey) }
    }
    @Published var accent: String {
        willSet { recordWillChange() }
        didSet { commit(accent, forKey: MenuAppearanceConfiguration.accentDefaultsKey) }
    }
    @Published var menuSize: String {
        willSet { recordWillChange() }
        didSet { commit(menuSize, forKey: MenuAppearanceConfiguration.menuSizeDefaultsKey) }
    }
    @Published var font: String {
        willSet { recordWillChange() }
        didSet { commit(font, forKey: MenuAppearanceConfiguration.fontDefaultsKey) }
    }
    @Published var fontWeight: String {
        willSet { recordWillChange() }
        didSet { commit(fontWeight, forKey: MenuAppearanceConfiguration.fontWeightDefaultsKey) }
    }

    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    var onChange: ((MenuAppearanceConfiguration) -> Void)?

    var configuration: MenuAppearanceConfiguration {
        MenuAppearanceConfiguration(
            theme: theme,
            accent: accent,
            menuSize: menuSize,
            font: font,
            fontWeight: fontWeight
        )
    }

    private struct HistoryEntry {
        let before: MenuAppearanceConfiguration
        let after: MenuAppearanceConfiguration
    }

    private let defaults: UserDefaults
    private var undoHistory: [HistoryEntry] = []
    private var redoHistory: [HistoryEntry] = []
    private var applyingHistory = false
    private var suppressNotifications = false
    private var lastBeforeMutation: MenuAppearanceConfiguration?
    private var menuSizeAdjustmentBefore: MenuAppearanceConfiguration?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = MenuAppearanceConfiguration(defaults: defaults)
        saved.save(to: defaults)
        theme = saved.theme
        accent = saved.accent
        menuSize = saved.menuSize
        font = saved.font
        fontWeight = saved.fontWeight
    }

    // MARK: Menu size adjustment session

    func beginMenuSizeAdjustment() {
        guard !applyingHistory, menuSizeAdjustmentBefore == nil else { return }
        menuSizeAdjustmentBefore = configuration
        lastBeforeMutation = nil
    }

    func endMenuSizeAdjustment() {
        guard let before = menuSizeAdjustmentBefore else { return }
        menuSizeAdjustmentBefore = nil
        appendHistory(before: before, after: configuration)
    }

    // MARK: History

    func undo() {
        guard let entry = undoHistory.popLast() else { return }
        redoHistory.append(entry)
        apply(entry.before)
        refreshHistoryState()
    }

    func redo() {
        guard let entry = redoHistory.popLast() else { return }
        undoHistory.append(entry)
        apply(entry.after)
        refreshHistoryState()
    }

    func reset() {
        let before = configuration
        let after = MenuAppearanceConfiguration.defaultConfiguration
        guard before != after else { return }
        apply(after)
        appendHistory(before: before, after: after)
    }

    // MARK: Internals

    private func commit(_ value: String, forKey key: String) {
        defaults.set(value, forKey: key)
        recordDidChange()
        if !suppressNotifications { onChange?(configuration) }
    }

    private func recordWillChange() {
        guard !applyingHistory, menuSizeAdjustmentBefore == nil else { return }
        lastBeforeMutation = configuration
    }

    private func recordDidChange() {
        guard !applyingHistory,
              menuSizeAdjustmentBefore == nil,
              let before = lastBeforeMutation,
              before != configuration else {
            lastBeforeMutation = nil
            return
        }
        lastBeforeMutation = nil
        appendHistory(before: before, after: configuration)
    }

    private func appendHistory(before: MenuAppearanceConfiguration, after: MenuAppearanceConfiguration) {
        guard before != after else { return }
        undoHistory.append(HistoryEntry(before: before, after: after))
        redoHistory.removeAll()
        refreshHistoryState()
    }

    private func refreshHistoryState() {
        canUndo = !undoHistory.isEmpty
        canRedo = !redoHistory.isEmpty
    }

    /// Writes all five values as one edit: history recording and per-value
    /// notifications stay suppressed so the batch produces a single `onChange`.
    private func apply(_ appearance: MenuAppearanceConfiguration) {
        suppressNotifications = true
        applyingHistory = true
        theme = appearance.theme
        accent = appearance.accent
        menuSize = appearance.menuSize
        font = appearance.font
        fontWeight = appearance.fontWeight
        applyingHistory = false
        suppressNotifications = false
        lastBeforeMutation = nil
        onChange?(appearance)
    }
}
