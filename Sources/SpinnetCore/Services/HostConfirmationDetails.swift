import Foundation

/// Complete Host-owned disclosure. The Plugin cannot provide this model.
/// Paging changes presentation only; no row is dropped from the confirmed plan.
public struct HostConfirmationDetails: Equatable {
    public struct Row: Equatable, Identifiable {
        public enum Presentation: Equatable { case action, verification }
        public let id: String
        /// Its words, which the Host shows in the interface language; the
        /// detail is lines.
        public let titleText: HostText
        public let detailText: [HostText]
        public let title: String
        public let detail: String
        public let presentation: Presentation
        public init(id: String, title: HostText, detail: [HostText], presentation: Presentation = .action) {
            self.id = id; titleText = title; detailText = detail; self.presentation = presentation
            self.title = title.english; self.detail = detail.map(\.english).joined(separator: "\n")
        }
        /// A row shown in the same words in every language.
        public init(id: String, title: String, detail: String, presentation: Presentation = .action) {
            self.init(id: id, title: .verbatim(title), detail: [.verbatim(detail)], presentation: presentation)
        }
    }
    public static let pageSize = 100
    public static let maximumRows = 60_000
    public static let maximumBytes = 96 * 1024 * 1024
    public let titleText: HostText
    public let summaryText: [HostText]
    public var title: String { titleText.english }
    public var summary: String { HostText.englishSentences(summaryText) }
    public let rows: [Row]
    public let actionRows: [Row]
    public let verificationRows: [Row]
    public var pageCount: Int { max(1, (rows.count + Self.pageSize - 1) / Self.pageSize) }
    /// Details shown in the same words in every language.
    public init(title: String, summary: String, rows: [Row], expectedRows: Int? = nil) throws {
        try self.init(title: .verbatim(title), summary: summary.isEmpty ? [] : [.verbatim(summary)], rows: rows,
                      expectedRows: expectedRows)
    }
    /// `summary` is whole sentences.
    public init(title titleText: HostText, summary summaryText: [HostText], rows: [Row], expectedRows: Int? = nil) throws {
        let title = titleText.english, summary = HostText.englishSentences(summaryText)
        guard !title.isEmpty, title.utf8.count <= 256, summary.utf8.count <= 32 * 1024,
              rows.count <= Self.maximumRows, expectedRows == nil || expectedRows == rows.count else { throw PluginHostServiceError.tool(.outputTooLarge) }
        func valid(_ text: String) -> Bool { !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" } }
        guard valid(title), valid(summary) else { throw PluginHostServiceError.tool(.planChanged) }
        var seen = Set<String>(), bytes = title.utf8.count + summary.utf8.count
        for row in rows {
            guard !row.id.isEmpty, row.id.utf8.count <= 4096, row.title.utf8.count <= 512,
                  row.detail.utf8.count <= 512 * 1024, valid(row.id), valid(row.title), valid(row.detail),
                  seen.insert(row.id).inserted else { throw PluginHostServiceError.tool(.planChanged) }
            let size = row.id.utf8.count + row.title.utf8.count + row.detail.utf8.count
            guard size <= Self.maximumBytes - bytes else { throw PluginHostServiceError.tool(.outputTooLarge) }
            bytes += size
        }
        self.titleText = titleText; self.summaryText = summaryText; self.rows = rows
        self.actionRows = rows.filter { $0.presentation == .action }
        self.verificationRows = rows.filter { $0.presentation == .verification }
    }
    public func rows(onPage page: Int) throws -> ArraySlice<Row> {
        guard page >= 0, page < pageCount else { throw PluginHostServiceError.tool(.planChanged) }
        let offset = page * Self.pageSize
        return rows[offset..<min(rows.count, offset + Self.pageSize)]
    }
}
