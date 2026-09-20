enum SelectedTextReadResolver {
    static func readSelectedText(
        allowClipboardCopyFallback: Bool,
        accessibilityRead: () throws -> String,
        clipboardCopyFallback: () throws -> SelectedTextCopyResult
    ) throws -> String {
        do {
            return try accessibilityRead()
        } catch {
            guard allowClipboardCopyFallback else { throw error }
            switch try clipboardCopyFallback() {
            case .selected(let text):
                return text
            case .noSelection:
                return ""
            case .unavailable:
                throw error
            }
        }
    }
}
