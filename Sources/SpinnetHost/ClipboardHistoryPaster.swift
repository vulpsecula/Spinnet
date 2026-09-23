import AppKit
import SpinnetCore

/// Puts a retained copy back on the general pasteboard and pastes it into the
/// application that was frontmost before the history window took focus.
struct ClipboardHistoryPaster {
    var pasteboard: NSPasteboard = .general
    var isTrusted: () -> Bool = { AXIsProcessTrusted() }
    var sendPaste: () -> Bool = { AppKitHostCommandAdapter().pasteText() }

    /// Returns a message for the user when the copy could only be placed on
    /// the clipboard, or nil once the paste keystroke was sent.
    func paste(_ items: [ClipboardHistoryRestoredItem], into target: NSRunningApplication?,
               completion: @escaping (String?) -> Void) {
        guard write(items) else { completion("The clipboard could not be updated"); return }
        guard let target, !target.isTerminated else { completion("Copied to the clipboard"); return }
        guard isTrusted() else {
            target.activate()
            completion("Copied to the clipboard. Allow Accessibility to paste automatically.")
            return
        }
        target.activate()
        waitUntilFrontmost(target, deadline: Date().addingTimeInterval(1)) { active in
            guard active else { completion("Copied to the clipboard"); return }
            completion(sendPaste() ? nil : "Copied to the clipboard")
        }
    }

    func write(_ items: [ClipboardHistoryRestoredItem]) -> Bool {
        let pasteboardItems = items.map { item -> NSPasteboardItem in
            let pasteboardItem = NSPasteboardItem()
            for representation in item.representations {
                pasteboardItem.setData(representation.data, forType: .init(representation.format))
            }
            return pasteboardItem
        }
        pasteboard.clearContents()
        return pasteboard.writeObjects(pasteboardItems)
    }

    /// Activation is asynchronous; a keystroke sent before the target is
    /// frontmost would land in Spinnet instead.
    private func waitUntilFrontmost(_ target: NSRunningApplication, deadline: Date,
                                    then: @escaping (Bool) -> Void) {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
            // Give the target a moment to restore its key window and focus.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { then(true) }
        } else if Date() >= deadline {
            then(false)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                waitUntilFrontmost(target, deadline: deadline, then: then)
            }
        }
    }
}
