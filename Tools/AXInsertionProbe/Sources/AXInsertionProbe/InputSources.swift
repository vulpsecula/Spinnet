import Carbon

/// Selecting a keyboard input source for one row, and putting the previous
/// one back. Only an already enabled source is selected; nothing is enabled.
enum InputSources {
    private static func string(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? String
    }

    static func currentID() -> String? {
        string(TISCopyCurrentKeyboardInputSource().takeRetainedValue(), kTISPropertyInputSourceID)
    }

    /// Selects `id` and returns the restore step, which reports what it did.
    static func select(_ id: String) -> Result<() -> String, SelectionError> {
        let filter = [kTISPropertyInputSourceID: id, kTISPropertyInputSourceIsEnabled: true] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
              let source = list.first else {
            return .failure(SelectionError("the input source \(id) is not enabled"))
        }
        let previous = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let previousID = string(previous, kTISPropertyInputSourceID) ?? "?"
        guard TISSelectInputSource(source) == noErr else {
            return .failure(SelectionError("TISSelectInputSource(\(id)) failed"))
        }
        Thread.sleep(forTimeInterval: 0.4)
        guard currentID() == id else {
            TISSelectInputSource(previous)
            return .failure(SelectionError("\(id) did not become the current input source"))
        }
        return .success({
            let status = TISSelectInputSource(previous)
            Thread.sleep(forTimeInterval: 0.3)
            return "input source restored to \(previousID): \(status == noErr && currentID() == previousID ? "yes" : "NO (now \(currentID() ?? "?"))")"
        })
    }

    struct SelectionError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
