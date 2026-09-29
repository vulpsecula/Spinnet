import Foundation
import SpinnetCore

/// Checks a JSON value against the part of JSON Schema (draft 2020-12) that
/// the schemas in `PluginAPI/` use. The package has no JSON Schema library and
/// the tests must not fetch one, so this implements only those keywords, and a
/// schema using any other fails validation outright rather than having the
/// keyword silently ignored.
struct JSONSchemaSubsetValidator {
    /// Keywords that describe or organise a schema without constraining the
    /// instance.
    private static let annotations: Set<String> = [
        "$schema", "$id", "$comment", "$defs", "title", "description", "examples"
    ]
    private static let assertions: Set<String> = [
        "$ref", "type", "const", "enum", "properties", "required", "additionalProperties",
        "items", "minItems", "maxItems", "uniqueItems", "minLength", "maxLength", "pattern", "minimum", "maximum",
        "allOf", "oneOf", "if", "then", "propertyNames", "maxProperties"
    ]

    private let root: JSONValue
    /// Where a reference to another schema file, such as
    /// `https-request.schema.json#/$defs/credential_use`, is looked up.
    private let directory: URL?

    init(schema: JSONValue, directory: URL? = nil) {
        root = schema
        self.directory = directory
    }

    init(schemaAt url: URL) throws {
        self.init(schema: try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url)),
                  directory: url.deletingLastPathComponent())
    }

    /// Checks against one of the `$defs` of the schema at `url`, such as
    /// `https_request.input`.
    init(definition: String, inSchemaAt url: URL) throws {
        let schema = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        guard case .object(let document) = schema, case .object(let definitions)? = document["$defs"],
              definitions[definition] != nil else {
            throw ConfigurationError.malformedValue("\(url.lastPathComponent) does not define \(definition)")
        }
        self.init(schema: .object(["$ref": .string("#/$defs/\(definition)"), "$defs": .object(definitions)]),
                  directory: url.deletingLastPathComponent())
    }

    /// Every way `instance` breaks the schema, each prefixed with the JSON
    /// Pointer of the value at fault. Empty means the instance is valid.
    func errors(for instance: JSONValue) -> [String] {
        errors(for: instance, against: root, at: "")
    }

    private func errors(for instance: JSONValue, against schema: JSONValue, at path: String) -> [String] {
        switch schema {
        case .bool(true):
            return []
        case .bool(false):
            return ["\(path): is not allowed here"]
        case .object(let keywords):
            return keywords.keys.sorted().flatMap { keyword in
                errors(for: instance, keyword: keyword, in: keywords, at: path)
            }
        default:
            return ["\(path): the schema here is neither an object nor a boolean"]
        }
    }

    private func errors(
        for instance: JSONValue, keyword: String, in keywords: [String: JSONValue], at path: String
    ) -> [String] {
        guard !Self.annotations.contains(keyword) else { return [] }
        guard Self.assertions.contains(keyword) else {
            return ["\(path): the schema uses \(keyword), which this validator does not implement"]
        }
        let value = keywords[keyword]!
        func fail(_ message: String) -> [String] { ["\(path): \(message)"] }

        switch (keyword, value) {
        case ("$ref", .string(let reference)):
            guard let (document, target) = resolve(reference) else { return fail("cannot resolve \(reference)") }
            return document.errors(for: instance, against: target, at: path)
        case ("type", .string(let type)):
            return Self.matches(instance, type: type) ? [] : fail("is not of type \(type)")
        case ("type", .array(let types)):
            return types.contains { if case .string(let type) = $0 { return Self.matches(instance, type: type) }; return false }
                ? [] : fail("is not of any allowed type")
        case ("const", _):
            return instance == value ? [] : fail("is not the required value")
        case ("enum", .array(let allowed)):
            return allowed.contains(instance) ? [] : fail("is not one of the allowed values")
        case ("properties", .object(let properties)):
            guard case .object(let members) = instance else { return [] }
            return properties.keys.sorted().flatMap { name -> [String] in
                guard let member = members[name] else { return [] }
                return errors(for: member, against: properties[name]!, at: path + "/" + name)
            }
        case ("required", .array(let names)):
            guard case .object(let members) = instance else { return [] }
            return names.compactMap { name -> String? in
                guard case .string(let name) = name, members[name] == nil else { return nil }
                return "\(path): is missing \(name)"
            }
        case ("additionalProperties", _):
            guard case .object(let members) = instance else { return [] }
            var declared = Set<String>()
            if case .object(let properties)? = keywords["properties"] { declared = Set(properties.keys) }
            return members.keys.sorted().filter { !declared.contains($0) }.flatMap { name in
                errors(for: members[name]!, against: value, at: path + "/" + name)
            }
        case ("propertyNames", _):
            guard case .object(let members) = instance else { return [] }
            return members.keys.sorted().flatMap { name in
                errors(for: .string(name), against: value, at: path + "/" + name)
            }
        case ("items", _):
            guard case .array(let elements) = instance else { return [] }
            return elements.enumerated().flatMap { index, element in
                errors(for: element, against: value, at: path + "/\(index)")
            }
        case ("minItems", .number(let minimum)):
            guard case .array(let elements) = instance else { return [] }
            return Double(elements.count) >= minimum ? [] : fail("has fewer than \(Int(minimum)) items")
        case ("maxItems", .number(let maximum)):
            guard case .array(let elements) = instance else { return [] }
            return Double(elements.count) <= maximum ? [] : fail("has more than \(Int(maximum)) items")
        case ("uniqueItems", .bool(let unique)):
            guard unique, case .array(let elements) = instance else { return [] }
            return Set(elements).count == elements.count ? [] : fail("repeats an item")
        case ("minLength", .number(let minimum)):
            guard case .string(let text) = instance else { return [] }
            return Double(text.unicodeScalars.count) >= minimum ? [] : fail("is shorter than \(Int(minimum))")
        case ("maxLength", .number(let maximum)):
            guard case .string(let text) = instance else { return [] }
            return Double(text.unicodeScalars.count) <= maximum ? [] : fail("is longer than \(Int(maximum))")
        case ("pattern", .string(let pattern)):
            guard case .string(let text) = instance else { return [] }
            guard let expression = try? NSRegularExpression(pattern: pattern) else {
                return fail("the schema's pattern \(pattern) does not compile")
            }
            let range = NSRange(text.startIndex..., in: text)
            return expression.firstMatch(in: text, range: range) != nil ? [] : fail("does not match \(pattern)")
        case ("minimum", .number(let minimum)):
            guard case .number(let number) = instance else { return [] }
            return number >= minimum ? [] : fail("is less than \(minimum)")
        case ("maximum", .number(let maximum)):
            guard case .number(let number) = instance else { return [] }
            return number <= maximum ? [] : fail("is greater than \(maximum)")
        case ("maxProperties", .number(let maximum)):
            guard case .object(let members) = instance else { return [] }
            return Double(members.count) <= maximum ? [] : fail("has more than \(Int(maximum)) members")
        case ("allOf", .array(let schemas)):
            return schemas.flatMap { errors(for: instance, against: $0, at: path) }
        case ("oneOf", .array(let schemas)):
            let matching = schemas.filter { errors(for: instance, against: $0, at: path).isEmpty }.count
            return matching == 1 ? [] : fail("matches \(matching) of the schemas where exactly one must match")
        case ("if", _):
            // `then` applies only when the instance satisfies `if`.
            guard errors(for: instance, against: value, at: path).isEmpty,
                  let then = keywords["then"] else { return [] }
            return errors(for: instance, against: then, at: path)
        case ("then", _):
            return []
        default:
            return fail("the schema's \(keyword) has a value of the wrong type")
        }
    }

    /// Resolves a reference within this document, such as `#/$defs/command`,
    /// or within a schema file beside it, such as
    /// `plugin-view.schema.json#/$defs/view`, together with the validator
    /// that resolves the references inside it.
    private func resolve(_ reference: String) -> (JSONSchemaSubsetValidator, JSONValue)? {
        let parts = reference.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        var document = self
        if !parts[0].isEmpty {
            guard let directory, let other = try? JSONSchemaSubsetValidator(
                schemaAt: directory.appendingPathComponent(String(parts[0]))
            ) else { return nil }
            document = other
        }
        var target = document.root
        for token in (parts.count > 1 ? parts[1] : "").split(separator: "/") {
            guard case .object(let members) = target, let next = members[String(token)] else { return nil }
            target = next
        }
        return (document, target)
    }

    private static func matches(_ instance: JSONValue, type: String) -> Bool {
        switch (type, instance) {
        case ("null", .null), ("boolean", .bool), ("string", .string), ("number", .number),
             ("array", .array), ("object", .object):
            return true
        case ("integer", .number(let number)):
            return number.rounded() == number
        default:
            return false
        }
    }
}
