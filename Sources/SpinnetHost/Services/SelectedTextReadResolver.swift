import SpinnetCore

enum SelectedTextReadResolver {
    static func readSelectedText(
        allowClipboardCopyFallback: Bool,
        accessibilityRead: () throws -> String,
        clipboardCopyFallback: () throws -> SelectedTextCopyResult
    ) throws -> String {
        let accessibilityText: String
        do {
            accessibilityText = try accessibilityRead()
        } catch {
            guard allowClipboardCopyFallback else { throw error }
            return try selectedText(
                from: clipboardCopyFallback(),
                preservingAccessibilityError: error
            )
        }

        guard accessibilityText.isEmpty, allowClipboardCopyFallback else {
            return accessibilityText
        }
        return try selectedText(
            from: clipboardCopyFallback(),
            preservingAccessibilityError: nil
        )
    }

    private static func selectedText(
        from result: SelectedTextCopyResult,
        preservingAccessibilityError accessibilityError: Error?
    ) throws -> String {
        switch result {
        case .selected(let text):
            return text
        case .noSelection:
            return ""
        case .unavailable:
            // A copy that could not run says nothing about whether text is
            // selected. Preserve that distinction for best-effort callers,
            // which may have their own way to read the selection.
            throw accessibilityError ?? PluginHostServiceError.unavailable("Selected text could not be read")
        }
    }
}
