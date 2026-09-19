import Foundation

/// A Host-owned input/result window can outlive the Plugin Action. Preview
/// is pure; submitting goes back through the broker using current grants.
public final class SmartJumpSession {
    public let initialText: String
    public let searchEngines: [SmartJumpSearchEngine]
    private let perform: (SmartJumpTarget) throws -> Void
    private let copy: (String) throws -> Void

    init(initialText: String, searchEngines: [SmartJumpSearchEngine],
         copy: @escaping (String) throws -> Void, perform: @escaping (SmartJumpTarget) throws -> Void) {
        self.initialText = initialText
        self.searchEngines = searchEngines
        self.perform = perform
        self.copy = copy
    }

    public func preview(_ text: String, engineName: String? = nil) throws -> SmartJumpTarget {
        let engine = engineName.flatMap { name in searchEngines.first { $0.name == name } } ?? searchEngines[0]
        return try SmartJumpClassifier(searchEngines: [engine]).classify(text)
    }

    @discardableResult
    public func submit(_ text: String, engineName: String? = nil) throws -> SmartJumpTarget {
        let target = try preview(text, engineName: engineName)
        guard target != .input else { throw PluginHostServiceError.invalidInput("Enter text to jump") }
        try perform(target)
        return target
    }

    public func copyResult(for text: String) throws {
        guard let result = try preview(text).resultText else {
            throw PluginHostServiceError.invalidInput("There is no calculation result to copy")
        }
        try copy(result)
    }
}

public extension SmartJumpTarget {
    var resultText: String? {
        guard case .calculation(let value) = self else { return nil }
        return String(format: "%.15g", locale: Locale(identifier: "en_US_POSIX"), value == 0 ? 0 : value)
    }
}
