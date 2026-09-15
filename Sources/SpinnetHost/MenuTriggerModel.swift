import Combine
import Foundation

/// Owns how the user opens a Menu: the mouse button, whether click-and-drag
/// selects on release, and the optional keyboard shortcut.
///
/// Mouse-input conflicts are part of this model rather than a separate concern,
/// because they are derived from the chosen button: picking a button that
/// another utility already claims is a property of the trigger, not of the
/// Settings window. They refresh on every trigger edit, and on demand when the
/// Settings window returns to the foreground and another app may have taken the
/// button in the meantime.
final class MenuTriggerModel: ObservableObject {
    @Published var mouseButton: Int {
        didSet { configurationDidChange() }
    }
    @Published var clickDragEnabled: Bool {
        didSet { configurationDidChange() }
    }
    @Published var keyboardShortcut: MenuKeyboardShortcut? {
        didSet { configurationDidChange() }
    }

    @Published private(set) var mouseInputConflicts: [MouseInputConflict]

    var onChange: ((MenuTriggerConfiguration) -> Void)?

    var configuration: MenuTriggerConfiguration {
        MenuTriggerConfiguration(
            mouseButton: mouseButton,
            clickDragEnabled: clickDragEnabled,
            keyboardShortcut: keyboardShortcut
        )
    }

    private let defaults: UserDefaults
    private let conflictCheck: (Int) -> [MouseInputConflict]

    init(
        defaults: UserDefaults = .standard,
        conflictCheck: @escaping (Int) -> [MouseInputConflict] = {
            MouseInputConflictDetector().detect(mouseButton: $0)
        }
    ) {
        self.defaults = defaults
        self.conflictCheck = conflictCheck
        let saved = MenuTriggerConfiguration(defaults: defaults)
        mouseButton = saved.mouseButton
        clickDragEnabled = saved.clickDragEnabled
        keyboardShortcut = saved.keyboardShortcut
        mouseInputConflicts = conflictCheck(saved.mouseButton)
    }

    /// Re-runs detection without changing the trigger. The set of conflicting
    /// apps can change while Settings sits open.
    func refreshConflicts() {
        mouseInputConflicts = conflictCheck(mouseButton)
    }

    private func configurationDidChange() {
        let configuration = configuration
        configuration.save(to: defaults)
        onChange?(configuration)
        refreshConflicts()
    }
}
