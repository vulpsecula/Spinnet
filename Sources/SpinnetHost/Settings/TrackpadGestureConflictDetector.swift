import Foundation

/// A system trackpad gesture that answers the same fingers as the chosen
/// trackpad trigger, with what the user can change.
struct TrackpadGestureConflict: Identifiable, Equatable {
    let id: String
    let guidance: String
}

/// Reads the trackpad settings System Settings saves to find system gestures
/// that use the chosen fingers. Only Look Up & data detectors can be set to
/// a three-finger tap; no system gesture taps with four fingers. With Click &
/// Drag the fingers also move, so the system gestures that follow moving
/// fingers of the same count conflict too. Three-finger drag does not: the
/// trigger keeps its clicks from the Menu and follows the pointer it moves.
struct TrackpadGestureConflictDetector {
    /// Look Up & data detectors set to "Tap with three fingers".
    static let lookUpOnThreeFingerTap = 2

    /// A saved trackpad setting by key: the largest value either trackpad
    /// keeps, so a gesture switched on for one of them counts.
    var setting: (String) -> Int? = Self.savedSetting

    func detect(_ configuration: MenuTriggerConfiguration) -> [TrackpadGestureConflict] {
        let drags = configuration.clickDragEnabled
        switch configuration.trackpadTrigger {
        case .off:
            return []
        case .threeFingerTap:
            var conflicts: [TrackpadGestureConflict] = []
            if setting("TrackpadThreeFingerTapGesture") == Self.lookUpOnThreeFingerTap { // Not localized: a file path or saved key
                conflicts.append(TrackpadGestureConflict(
                    id: "look-up", // Not localized: an internal identifier
                    guidance: localized("Look Up & data detectors also uses a three-finger tap. Set it to Force Click with one finger in System Settings → Trackpad, or choose Four-Finger Tap.")
                ))
            }
            if drags, isOn("TrackpadThreeFingerHorizSwipeGesture") || isOn("TrackpadThreeFingerVertSwipeGesture") { // Not localized: a file path or saved key
                conflicts.append(TrackpadGestureConflict(
                    id: "three-finger-swipes", // Not localized: an internal identifier
                    guidance: localized("Three-finger swipes also switch pages, Spaces or Mission Control while you drag. Set them to four fingers in System Settings → Trackpad → More Gestures, or turn off Click & Drag.")
                ))
            }
            return conflicts
        case .fourFingerTap:
            guard drags, isOn("TrackpadFourFingerHorizSwipeGesture") || isOn("TrackpadFourFingerVertSwipeGesture") // Not localized: a file path or saved key
                    || isOn("TrackpadFourFingerPinchGesture") else { return [] } // Not localized: a file path or saved key
            return [TrackpadGestureConflict(
                id: "four-finger-swipes", // Not localized: an internal identifier
                guidance: localized("Four-finger swipes and pinches also switch Spaces, show Mission Control or open Launchpad while you drag. Turn them off in System Settings → Trackpad → More Gestures, or choose Three-Finger Tap.")
            )]
        }
    }

    private func isOn(_ key: String) -> Bool {
        (setting(key) ?? 0) != 0
    }

    /// The built-in trackpad and a Magic Trackpad keep their settings in
    /// separate domains.
    private static func savedSetting(_ key: String) -> Int? {
        [
            "com.apple.AppleMultitouchTrackpad", // Not localized: a file path or saved key
            "com.apple.driver.AppleBluetoothMultitouch.trackpad" // Not localized: a file path or saved key
        ].compactMap {
            (CFPreferencesCopyAppValue(key as CFString, $0 as CFString) as? NSNumber)?.intValue
        }.max()
    }
}
