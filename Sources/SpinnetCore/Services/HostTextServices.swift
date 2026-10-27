import Foundation

/// Bounded text insertion and language detection, without owning Plugin authority.
public struct HostTextServices {
    private let focusedTextInserter: (String) throws -> Void
    private let targetedTextInserter: (String, InsertionTargetCapture) throws -> Void
    private let languageDetector: (String) -> String?

    public init(focusedTextInserter: @escaping (String) throws -> Void = { _ in throw PluginHostServiceError.unavailable("Text insertion") },
                targetedTextInserter: @escaping (String, InsertionTargetCapture) throws -> Void = { _, _ in throw PluginHostServiceError.unavailable("Text insertion") },
                languageDetector: @escaping (String) -> String? = { _ in nil }) {
        self.focusedTextInserter = focusedTextInserter
        self.targetedTextInserter = targetedTextInserter
        self.languageDetector = languageDetector
    }

    func execute(_ request: PluginRuntimeHostServiceRequest, for package: PluginPackage,
                 action: ActionConfiguration) throws -> JSONValue {
        switch request.service {
        case .insertText:
            guard case .string(let text) = request.input,
                  text.utf8.count <= HTTPSRequestBudgets.maximumResponseBodyBytes else {
                throw PluginHostServiceError.invalidInput("insert_text expects a text string of at most 128 KiB")
            }
            if let target = request.insertionTarget {
                try targetedTextInserter(text, target)
            } else {
                try focusedTextInserter(text)
            }
            return .null
        case .detectLanguage:
            guard case .string(let text) = request.input else {
                throw PluginHostServiceError.invalidInput("detect_language expects a text string")
            }
            return languageDetector(text).map(JSONValue.string) ?? .null
        default: throw PluginHostServiceError.unavailable("This Host Service is not in the HostTextServices module")
        }
    }
}
