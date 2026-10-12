import Foundation

/// Trusted publisher templates use fixed native environment slots for
/// configured paths. Local configuration never becomes shell program text.
public enum HomebrewNativeGeneratedScript {
    public static let homeMarker = "/__SPINNET_GENERATED_HOME__"
    public static let prefixMarker = "/__SPINNET_GENERATED_PREFIX__"
    public static let appDirectoryMarker = "/__SPINNET_GENERATED_APPDIR__"
    public static let payloadMarker = "/__SPINNET_GENERATED_PAYLOAD__"
    public struct Rendered {
        public let content: String
        public let environment: [String: String]
    }
    public static func neutralConfiguration(languages: [String]) throws -> HomebrewSignedCaskCatalog.Configuration {
        try .init(languages: languages, home: URL(fileURLWithPath: homeMarker), prefix: URL(fileURLWithPath: prefixMarker), appDirectory: URL(fileURLWithPath: appDirectoryMarker))
    }
    public static func render(template: String, home: URL, prefix: URL, appDirectory: URL, payload: URL,
                              stagedRelativePrefix: String? = nil) throws -> Rendered {
        let slots = [(homeMarker, "SPINNET_GENERATED_HOME", home.path), (prefixMarker, "SPINNET_GENERATED_PREFIX", prefix.path),
                     (appDirectoryMarker, "SPINNET_GENERATED_APPDIR", appDirectory.path), (payloadMarker, "SPINNET_GENERATED_PAYLOAD", payload.path)]
        guard template.utf8.count <= 256 * 1024, !template.contains("\0"),
              slots.allSatisfy({ !$0.2.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else { throw PluginHostServiceError.tool(.planChanged) }
        var source = template
        if let stagedRelativePrefix {
            source = source.replacingOccurrences(of: prefixMarker + stagedRelativePrefix, with: payloadMarker + "/")
        }
        guard slots.contains(where: { source.contains($0.0) }) else { return Rendered(content: source, environment: [:]) }
        let shebang = String(source.split(separator: "\n", maxSplits: 1).first ?? "")
        guard ["#!/bin/sh", "#!/bin/bash", "#!/bin/zsh", "#!/bin/ksh", "#!/usr/bin/env sh", "#!/usr/bin/env bash", "#!/usr/bin/env zsh"].contains(shebang),
              !source.contains("<<") else { throw PluginHostServiceError.unavailable("This generated script's path substitution requires a reviewed native language adapter") }
        enum Quote { case none, single, double }
        var quote = Quote.none, escaped = false, index = source.startIndex, result = "", used: [String: String] = [:]
        while index < source.endIndex {
            if let slot = slots.first(where: { source[index...].hasPrefix($0.0) }) {
                guard !escaped else { throw PluginHostServiceError.unavailable("This generated path escape requires native review") }
                let variable = "${" + slot.1 + "}"
                switch quote {
                case .none: result += "\"" + variable + "\""
                case .single: result += "'\"" + variable + "\"'"
                case .double: result += variable
                }
                used[slot.1] = slot.2; index = source.index(index, offsetBy: slot.0.count); continue
            }
            let character = source[index]; result.append(character)
            if escaped { escaped = false }
            else {
                switch (quote, character) {
                case (.none, "'"): quote = .single
                case (.none, "\""): quote = .double
                case (.single, "'"): quote = .none
                case (.double, "\""): quote = .none
                case (.none, "\\"), (.double, "\\"): escaped = true
                default: break
                }
            }
            index = source.index(after: index)
        }
        guard quote == .none, !escaped else { throw PluginHostServiceError.tool(.planChanged) }
        return Rendered(content: result, environment: used)
    }
}
