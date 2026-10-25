import Carbon
import Foundation

/// The keyboard input source the user has selected.
enum HostInputSource {
    /// Whether it is an input method, such as Pinyin or Kotoeri, rather
    /// than a keyboard layout: a key it receives may start a composition.
    static func isInputMethodSelected() -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else { return false }
        let type = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue()
        return !CFEqual(type, kTISTypeKeyboardLayout)
    }
}
