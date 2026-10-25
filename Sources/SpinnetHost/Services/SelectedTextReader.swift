import AppKit
import SpinnetCore

/// The Host's one way to read the focused App's selected text, shared by
/// every Host Service and Command that needs it. Accessibility comes first;
/// only when the caller allows it does a targeted Command-C follow, whose
/// clipboard change is read and then undone (see `SelectedTextCopyFallback`).
/// Whether a Plugin Command may allow it is
/// `PluginCapabilityGrantStore.allowsSelectedTextCopyFallback`.
final class SelectedTextReader {
    private let copyFallback: SelectedTextCopyFallback<AppKitSelectedTextCopyClient>

    init(clipboardObservationGate: ClipboardObservationGate) {
        copyFallback = SelectedTextCopyFallback(
            client: AppKitSelectedTextCopyClient(),
            observationGate: clipboardObservationGate
        )
    }

    func read(allowingCopyFallback: Bool) throws -> String {
        guard AXIsProcessTrusted() else {
            throw PluginHostServiceError.systemPermissionDenied(.accessibility)
        }
        return try SelectedTextReadResolver.readSelectedText(
            allowClipboardCopyFallback: allowingCopyFallback,
            accessibilityRead: { try SelectedTextLookup().read(using: AppKitSelectedTextAXClient()) },
            clipboardCopyFallback: { try copyFallback.readSelectedText() }
        )
    }
}
