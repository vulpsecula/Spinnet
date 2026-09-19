import Foundation

/// A bounded recursive-descent parser for decimal arithmetic. It has no
/// variables, functions, exponentiation, runtime evaluator, or code access.
struct SmartJumpArithmetic {
    private let tokens: [Character]
    private var index = 0
    private static let invalid = PluginHostServiceError.invalidInput("Invalid arithmetic expression; use numbers, + − × ÷ and parentheses")

    static func result(for text: String) throws -> Double? {
        let normalized = text.replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
        let allowed = Set("0123456789.+-*/() \t\r\n")
        guard normalized.allSatisfy(allowed.contains), normalized.contains(where: { "0123456789".contains($0) }) else { return nil }
        guard normalized.count <= 512 else { throw invalid }
        var parser = SmartJumpArithmetic(tokens: Array(normalized))
        let value = try parser.expression(depth: 0)
        parser.skipSpaces()
        guard parser.index == parser.tokens.count, value.isFinite else { throw invalid }
        return value
    }

    private mutating func expression(depth: Int) throws -> Double {
        var value = try term(depth: depth)
        while true {
            if take("+") { value += try term(depth: depth) }
            else if take("-") { value -= try term(depth: depth) }
            else { return try finite(value) }
        }
    }

    private mutating func term(depth: Int) throws -> Double {
        var value = try factor(depth: depth)
        while true {
            if take("*") { value *= try factor(depth: depth) }
            else if take("/") {
                let divisor = try factor(depth: depth)
                guard divisor != 0 else { throw PluginHostServiceError.invalidInput("Cannot divide by zero") }
                value /= divisor
            } else { return try finite(value) }
        }
    }

    private mutating func factor(depth: Int) throws -> Double {
        guard depth < 32 else { throw Self.invalid }
        if take("+") { return try factor(depth: depth + 1) }
        if take("-") { return -(try factor(depth: depth + 1)) }
        if take("(") {
            let value = try expression(depth: depth + 1)
            guard take(")") else { throw Self.invalid }
            return value
        }
        skipSpaces()
        let start = index
        while index < tokens.count, "0123456789.".contains(tokens[index]) { index += 1 }
        guard start < index, let number = Double(String(tokens[start..<index])) else { throw Self.invalid }
        return try finite(number)
    }

    private func finite(_ value: Double) throws -> Double {
        guard value.isFinite else { throw Self.invalid }
        return value
    }

    private mutating func take(_ token: Character) -> Bool {
        skipSpaces()
        guard index < tokens.count, tokens[index] == token else { return false }
        index += 1
        return true
    }

    private mutating func skipSpaces() {
        while index < tokens.count, tokens[index].isWhitespace { index += 1 }
    }
}
