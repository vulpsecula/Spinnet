import Foundation

/// One search destination. `{query}` is substituted only after the search
/// text is percent encoded, so it cannot change the host or query structure.
public struct SmartJumpSearchEngine: Equatable {
    public let name: String
    public let template: String

    public static let google = SmartJumpSearchEngine(name: "Google", template: "https://www.google.com/search?q={query}")

    public static func parse(_ text: String) throws -> [SmartJumpSearchEngine] {
        let message = "Enter one search engine per line as Name | https://example.com/search?q={query}. The first is the default; use up to 10 unique names."
        guard text.utf8.count <= 8192 else { throw PluginHostServiceError.invalidInput(message) }
        let lines = text.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty, lines.count <= 10 else { throw PluginHostServiceError.invalidInput(message) }
        var engines: [SmartJumpSearchEngine] = []
        for line in lines {
            let parts = line.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty, parts[0].count <= 50,
                  !engines.contains(where: { $0.name == parts[0] }),
                  parts[1].components(separatedBy: "{query}").count == 2 else {
                throw PluginHostServiceError.invalidInput(message)
            }
            let probe = parts[1].replacingOccurrences(of: "{query}", with: "spinnet_query_probe")
            guard let url = try? OpenableURL.validate(probe),
                  url.scheme?.lowercased() == "https",
                  url.user == nil, url.password == nil,
                  url.host?.contains("spinnet_query_probe") == false,
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  components.path.contains("spinnet_query_probe") || components.query?.contains("spinnet_query_probe") == true else {
                throw PluginHostServiceError.invalidInput(message)
            }
            engines.append(SmartJumpSearchEngine(name: parts[0], template: parts[1]))
        }
        return engines
    }

    public func url(for text: String) throws -> URL {
        // RFC 3986 unreserved characters only, including for a path template.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let encoded = text.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw PluginHostServiceError.invalidInput("The search text cannot be encoded")
        }
        return try OpenableURL.validate(template.replacingOccurrences(of: "{query}", with: encoded))
    }
}
