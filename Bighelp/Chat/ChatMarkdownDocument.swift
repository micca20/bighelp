import SwiftUI

enum ChatMarkdownLayoutPolicy {
    static let growsVerticallyWithoutTruncation = true
    static let blockSpacing: CGFloat = 16
    static let headingContentSpacing: CGFloat = 8
    static let sectionSpacing: CGFloat = 20
    static let listRowSpacing: CGFloat = 8
    static let unorderedMarkerWidth: CGFloat = 16
    static let orderedMarkerWidth: CGFloat = 28

    static func spacing(after previous: MarkdownBlock, before current: MarkdownBlock) -> CGFloat {
        if case .heading = current {
            return sectionSpacing
        }
        if case .heading = previous {
            return headingContentSpacing
        }
        return blockSpacing
    }
}

enum ChatMarkdownTypography {
    static func headingRole(for level: Int) -> BighelpFontRole {
        switch level {
        case 1: .display
        case 2: .screenTitle
        case 3: .sectionTitle
        default: .label
        }
    }
}

enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, markdown: String)
    case paragraph(markdown: String)
    case unorderedList(items: [String])
    case orderedList(start: Int, items: [String])
    case quote(markdown: String)
    case code(language: String?, text: String)
}

struct MarkdownDocument: Equatable, Sendable {
    let blocks: [MarkdownBlock]
    let visiblePlainText: String

    init(_ source: String) {
        blocks = Self.parse(source)
        visiblePlainText = blocks.map(Self.plainText).joined(separator: "\n\n")
    }

    private static func parse(_ source: String) -> [MarkdownBlock] {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        let lines = normalized.components(separatedBy: "\n")
        var result: [MarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            result.append(.paragraph(markdown: paragraph.joined(separator: "\n")))
            paragraph.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }
            if trimmed.hasPrefix("```") {
                flushParagraph()
                let languageValue = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                var cursor = index + 1
                while cursor < lines.count,
                      !lines[cursor].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[cursor])
                    cursor += 1
                }
                if cursor < lines.count {
                    result.append(.code(
                        language: languageValue.isEmpty ? nil : languageValue,
                        text: codeLines.joined(separator: "\n")
                    ))
                    index = cursor + 1
                } else {
                    paragraph.append(contentsOf: Array(lines[index...]))
                    index = lines.count
                }
                continue
            }
            if let heading = heading(from: trimmed) {
                flushParagraph()
                result.append(heading)
                index += 1
                continue
            }
            if unorderedItem(from: trimmed) != nil {
                flushParagraph()
                var items: [String] = []
                while index < lines.count,
                      let item = unorderedItem(from: lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(item)
                    index += 1
                }
                result.append(.unorderedList(items: items))
                continue
            }
            if let first = orderedItem(from: trimmed) {
                flushParagraph()
                var items = [first.text]
                let start = first.number
                index += 1
                while index < lines.count,
                      let item = orderedItem(from: lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(item.text)
                    index += 1
                }
                result.append(.orderedList(start: start, items: items))
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    quoted.append(String(candidate.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                result.append(.quote(markdown: quoted.joined(separator: "\n")))
                continue
            }
            paragraph.append(line)
            index += 1
        }
        flushParagraph()
        return result
    }

    private static func heading(from line: String) -> MarkdownBlock? {
        let count = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(count), line.dropFirst(count).first == " " else { return nil }
        let text = String(line.dropFirst(count + 1))
        guard !text.isEmpty else { return nil }
        return .heading(level: count, markdown: text)
    }

    private static func unorderedItem(from line: String) -> String? {
        for prefix in ["- ", "* ", "+ "] where line.hasPrefix(prefix) {
            let value = String(line.dropFirst(prefix.count))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static func orderedItem(from line: String) -> (number: Int, text: String)? {
        guard let dot = line.firstIndex(of: ".") else { return nil }
        let prefix = line[..<dot]
        guard
            !prefix.isEmpty,
            prefix.allSatisfy(\.isNumber),
            let number = Int(prefix),
            number > 0
        else { return nil }
        let remainder = line[line.index(after: dot)...]
        guard remainder.first == " " else { return nil }
        let text = String(remainder.dropFirst())
        return text.isEmpty ? nil : (number, text)
    }

    private static func plainText(for block: MarkdownBlock) -> String {
        switch block {
        case .heading(_, let markdown), .paragraph(let markdown), .quote(let markdown):
            inlinePlainText(markdown)
        case .unorderedList(let items):
            items.map(inlinePlainText).joined(separator: "\n")
        case .orderedList(_, let items):
            items.map(inlinePlainText).joined(separator: "\n")
        case .code(_, let text):
            text
        }
    }

    private static func inlinePlainText(_ markdown: String) -> String {
        guard inlineMarkersAreBalanced(markdown) else { return markdown }
        do {
            let attributed = try AttributedString(
                markdown: markdown,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )
            return String(attributed.characters)
        } catch {
            return markdown
        }
    }

    private static func inlineMarkersAreBalanced(_ value: String) -> Bool {
        value.components(separatedBy: "**").count.isMultiple(of: 2) == false
            && value.filter { $0 == "`" }.count.isMultiple(of: 2)
    }
}

enum ChatInlineMarkdown {
    static func attributedText(_ markdown: String) -> AttributedString {
        var attributed = (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)
        let visibleText = String(attributed.characters)
        guard
            let detector = try? NSDataDetector(
                types: NSTextCheckingResult.CheckingType.link.rawValue
            )
        else { return attributed }

        let matches = detector.matches(
            in: visibleText,
            range: NSRange(visibleText.startIndex..<visibleText.endIndex, in: visibleText)
        )
        for match in matches {
            guard
                let url = match.url,
                let stringRange = Range(match.range, in: visibleText),
                let lowerBound = AttributedString.Index(
                    stringRange.lowerBound,
                    within: attributed
                ),
                let upperBound = AttributedString.Index(
                    stringRange.upperBound,
                    within: attributed
                )
            else { continue }
            let range = lowerBound..<upperBound
            guard !attributed[range].runs.contains(where: { $0.link != nil }) else {
                continue
            }
            attributed[range].link = url
        }
        return attributed
    }
}
