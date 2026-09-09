import AppKit

struct MenuTitleLayout {
    let text: String
    let font: NSFont
    let size: CGSize

    var lineCount: Int {
        text.split(separator: "\n", omittingEmptySubsequences: false).count
    }
}

enum MenuTitleLayoutEngine {
    static func layout(
        title: String,
        maxWidth: CGFloat,
        baseSize: CGFloat,
        font: MenuAppearanceConfiguration.MenuFont,
        weight: MenuAppearanceConfiguration.MenuFontWeight = .semibold
    ) -> MenuTitleLayout {
        let normalizedTitle = title
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let safeTitle = normalizedTitle.isEmpty ? " " : normalizedTitle
        let baseFont = font.makeFont(ofSize: baseSize, weight: weight)

        guard maxWidth > 0 else {
            return makeLayout(text: safeTitle, font: baseFont, maxWidth: maxWidth)
        }

        let singleLineWidth = width(of: safeTitle, font: baseFont)
        guard singleLineWidth > maxWidth else {
            return makeLayout(text: safeTitle, font: baseFont, maxWidth: maxWidth)
        }

        let wrappedLines = balancedLines(
            for: safeTitle,
            font: baseFont,
            maxWidth: maxWidth,
            minimumFontSize: baseSize
        )
        guard wrappedLines.count > 1 else {
            return makeLayout(
                text: truncate(safeTitle, font: baseFont, maxWidth: maxWidth),
                font: baseFont,
                maxWidth: maxWidth
            )
        }

        let wrappedText = wrappedLines.joined(separator: "\n")
        let widestWrappedLine = wrappedLines.map { width(of: $0, font: baseFont) }.max() ?? 0
        if widestWrappedLine <= maxWidth {
            return makeLayout(text: wrappedText, font: baseFont, maxWidth: maxWidth)
        }

        let truncatedLines = wrappedLines.map {
            truncate($0, font: baseFont, maxWidth: maxWidth)
        }
        return makeLayout(
            text: truncatedLines.joined(separator: "\n"),
            font: baseFont,
            maxWidth: maxWidth
        )
    }

    private static func balancedLines(
        for title: String,
        font: NSFont,
        maxWidth: CGFloat,
        minimumFontSize: CGFloat
    ) -> [String] {
        let minimumFont = font.withSize(minimumFontSize)
        let words = title.split(separator: " ").map(String.init)
        guard words.count > 1 else {
            return [title]
        }

        var bestLines: [String]?
        var bestScore = CGFloat.greatestFiniteMagnitude
        for splitIndex in 1..<words.count {
            let first = words[..<splitIndex].joined(separator: " ")
            let second = words[splitIndex...].joined(separator: " ")
            let firstWidth = width(of: first, font: font)
            let secondWidth = width(of: second, font: font)
            let minimumOverflow = max(
                0,
                max(
                    width(of: first, font: minimumFont),
                    width(of: second, font: minimumFont)
                ) - maxWidth
            )
            let balance = abs(firstWidth - secondWidth)
            let score = minimumOverflow * 1_000 + balance
            if score < bestScore {
                bestScore = score
                bestLines = [first, second]
            }
        }
        return bestLines ?? [title]
    }

    private static func truncate(
        _ text: String,
        font: NSFont,
        maxWidth: CGFloat
    ) -> String {
        guard width(of: text, font: font) > maxWidth else { return text }
        let ellipsis = "…"
        var result = ""
        for character in text {
            let candidate = result + String(character) + ellipsis
            guard width(of: candidate, font: font) <= maxWidth else { break }
            result.append(character)
        }
        return result.isEmpty ? ellipsis : result + ellipsis
    }

    private static func width(of text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    private static func makeLayout(
        text: String,
        font: NSFont,
        maxWidth: CGFloat
    ) -> MenuTitleLayout {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.lineSpacing = 1
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraphStyle
        ]
        let measuredSize = (text as NSString).boundingRect(
            with: CGSize(width: max(maxWidth, 1), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        ).size
        return MenuTitleLayout(text: text, font: font, size: measuredSize)
    }
}
