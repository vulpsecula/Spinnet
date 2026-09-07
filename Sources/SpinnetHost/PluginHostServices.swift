import AppKit
import SpinnetCore

/// AppKit adapters for the narrow Host Services exposed to the fixture
/// Plugin. The Plugin helper never receives these objects or framework access.
final class AppKitPluginHostServiceProvider {
    func isGranted(_ permission: PluginSystemPermission) -> Bool {
        switch permission {
        case .accessibility:
            return AXIsProcessTrusted()
        }
    }

    func readSelectedText() throws -> String {
        guard isGranted(.accessibility) else {
            throw PluginHostServiceError.systemPermissionDenied(.accessibility)
        }

        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        let focusedStatus = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        guard focusedStatus == .success,
              let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            throw PluginHostServiceError.failed("Focused application has no accessible text selection")
        }
        let focusedElement = focusedValue as! AXUIElement

        var selectedValue: CFTypeRef?
        let selectedStatus = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &selectedValue
        )
        guard selectedStatus == .success,
              let selectedText = selectedValue as? String else {
            throw PluginHostServiceError.failed("Focused application has no readable text selection")
        }
        return selectedText
    }

    func writeClipboard(_ text: String) throws {
        let pasteboard = NSPasteboard.general
        guard pasteboard.clearContents() != 0,
              pasteboard.setString(text, forType: .string) else {
            throw PluginHostServiceError.failed("Clipboard could not be updated")
        }
    }
}
