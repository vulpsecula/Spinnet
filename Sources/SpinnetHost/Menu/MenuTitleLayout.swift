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
        layout(
            title: title,
            maxWidth: maxWidth,
            baseFont: font.makeFont(ofSize: baseSize, weight: weight)
        )
    }

    static func layout(
        title: String,
        maxWidth: CGFloat,
        baseFont: NSFont
    ) -> MenuTitleLayout {
        let normalizedTitle = title
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let safeTitle = normalizedTitle.isEmpty ? " " : normalizedTitle

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
            maxWidth: maxWidth
        )
        let fullyWrappedLines = wrappedLines.flatMap {
            wrapLine($0, font: baseFont, maxWidth: maxWidth)
        }
        return makeLayout(
            text: fullyWrappedLines.joined(separator: "\n"),
            font: baseFont,
            maxWidth: maxWidth
        )
    }

    private static func balancedLines(
        for title: String,
        font: NSFont,
        maxWidth: CGFloat
    ) -> [String] {
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
                    firstWidth,
                    secondWidth
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

    private static func wrapLine(
        _ line: String,
        font: NSFont,
        maxWidth: CGFloat
    ) -> [String] {
        guard width(of: line, font: font) > maxWidth else { return [line] }

        var result: [String] = []
        var currentLine = ""
        for word in line.split(separator: " ").map(String.init) {
            let wordLines = wrapWord(word, font: font, maxWidth: maxWidth)
            guard wordLines.count > 1 else {
                let candidate = currentLine.isEmpty ? word : "\(currentLine) \(word)"
                if currentLine.isEmpty || width(of: candidate, font: font) <= maxWidth {
                    currentLine = candidate
                } else {
                    result.append(currentLine)
                    currentLine = word
                }
                continue
            }

            if !currentLine.isEmpty {
                result.append(currentLine)
                currentLine = ""
            }
            result.append(contentsOf: wordLines.dropLast())
            currentLine = wordLines.last ?? ""
        }

        if !currentLine.isEmpty {
            result.append(currentLine)
        }
        return result.isEmpty ? [line] : result
    }

    private static func wrapWord(
        _ word: String,
        font: NSFont,
        maxWidth: CGFloat
    ) -> [String] {
        guard width(of: word, font: font) > maxWidth else { return [word] }

        var result: [String] = []
        var current = ""
        for character in word {
            let candidate = current + String(character)
            if current.isEmpty || width(of: candidate, font: font) <= maxWidth {
                current = candidate
            } else {
                result.append(current)
                current = String(character)
            }
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result.isEmpty ? [word] : result
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
