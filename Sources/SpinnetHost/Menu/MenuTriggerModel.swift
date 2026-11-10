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
    @Published var alternateActionMode: AlternateActionMode {
        didSet { configurationDidChange() }
    }
    /// The trackpad fingers that open the Menu, off by default.
    @Published var trackpadTrigger: TrackpadTrigger {
        didSet { configurationDidChange() }
    }
    /// How long those fingers must rest before the Menu opens, shown on
    /// General. Edits are clamped to
    /// `MenuTriggerConfiguration.trackpadOpeningDelayRange`.
    @Published var trackpadOpeningDelay: TimeInterval {
        didSet {
            let bounded = MenuTriggerConfiguration.boundedTrackpadOpeningDelay(trackpadOpeningDelay)
            guard bounded == trackpadOpeningDelay else {
                trackpadOpeningDelay = bounded
                return
            }
            configurationDidChange()
        }
    }
    /// How long the trigger must be held before the Menu opens, shown on
    /// General. Edits are clamped to `MenuTriggerConfiguration.openingDelayRange`.
    @Published var openingDelay: TimeInterval {
        didSet {
            let bounded = MenuTriggerConfiguration.boundedOpeningDelay(openingDelay)
            guard bounded == openingDelay else {
                openingDelay = bounded
                return
            }
            configurationDidChange()
        }
    }

    @Published private(set) var mouseInputConflicts: [MouseInputConflict]
    /// System trackpad gestures that use the chosen trackpad tap.
    @Published private(set) var trackpadConflicts: [TrackpadGestureConflict]

    /// Spinnet's master switch. Off, the Host stops listening for the mouse
    /// button and keyboard shortcut, so both go back to other apps, and the
    /// Menu cannot open. The trigger itself is kept for switching back on.
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.enabledKey)
            onEnabledChange?(isEnabled)
        }
    }

    static let enabledKey = "spinnet.enabled"

    /// Whether the user left Spinnet switched on, which it is until they don't.
    static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    var onChange: ((MenuTriggerConfiguration) -> Void)?
    var onEnabledChange: ((Bool) -> Void)?

    var configuration: MenuTriggerConfiguration {
        MenuTriggerConfiguration(
            mouseButton: mouseButton,
            clickDragEnabled: clickDragEnabled,
            keyboardShortcut: keyboardShortcut,
            openingDelay: openingDelay,
            alternateActionMode: alternateActionMode,
            trackpadTrigger: trackpadTrigger,
            trackpadOpeningDelay: trackpadOpeningDelay
        )
    }

    private let defaults: UserDefaults
    private let conflictCheck: (Int) -> [MouseInputConflict]
    private let trackpadConflictCheck: (MenuTriggerConfiguration) -> [TrackpadGestureConflict]

    init(
        defaults: UserDefaults = .standard,
        conflictCheck: @escaping (Int) -> [MouseInputConflict] = {
            MouseInputConflictDetector().detect(mouseButton: $0)
        },
        trackpadConflictCheck: @escaping (MenuTriggerConfiguration) -> [TrackpadGestureConflict] = {
            TrackpadGestureConflictDetector().detect($0)
        }
    ) {
        self.defaults = defaults
        self.conflictCheck = conflictCheck
        self.trackpadConflictCheck = trackpadConflictCheck
        let saved = MenuTriggerConfiguration(defaults: defaults)
        mouseButton = saved.mouseButton
        clickDragEnabled = saved.clickDragEnabled
        keyboardShortcut = saved.keyboardShortcut
        openingDelay = saved.openingDelay
        alternateActionMode = saved.alternateActionMode
        trackpadTrigger = saved.trackpadTrigger
        trackpadOpeningDelay = saved.trackpadOpeningDelay
        mouseInputConflicts = conflictCheck(saved.mouseButton)
        trackpadConflicts = trackpadConflictCheck(saved)
        isEnabled = Self.isEnabled(in: defaults)
    }

    /// Re-runs detection without changing the trigger. The set of conflicting
    /// apps, and the system's trackpad gestures, can change while Settings
    /// sits open.
    func refreshConflicts() {
        mouseInputConflicts = conflictCheck(mouseButton)
        trackpadConflicts = trackpadConflictCheck(configuration)
    }

    private func configurationDidChange() {
        let configuration = configuration
        configuration.save(to: defaults)
        onChange?(configuration)
        refreshConflicts()
    }
}
