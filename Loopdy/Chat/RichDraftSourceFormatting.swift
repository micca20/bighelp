import Foundation

/// Bounded source edits use UTF-16 ranges, like UITextView. Untouched Markdown
/// stays byte-for-byte intact; this is not a whole-document reserializer.
enum MarkdownSourceFormatter {
    static func apply(
        _ command: RichDraftCommand, to source: String, selection proposed: NSRange,
        linkTarget: String? = nil
    ) -> (source: String, selection: NSRange) {
        let text = source as NSString
        let selection = clamped(proposed, length: text.length)
        if let enclosure = inlineEnclosure(command, source: source, selection: selection) {
            let content = text.substring(with: enclosure.content)
            let result = text.replacingCharacters(in: enclosure.whole, with: content)
            return (result, NSRange(location: selection.location - enclosure.content.location + enclosure.whole.location,
                                    length: selection.length))
        }
        switch command {
        case .bold, .italic, .inlineCode:
            let marker = command == .bold ? "**" : command == .italic ? "*" : "`"
            let placeholder = command == .bold ? "bold text" : command == .italic ? "italic text" : "code"
            let content = selection.length > 0 ? text.substring(with: selection) : placeholder
            return (text.replacingCharacters(in: selection, with: marker + content + marker),
                    NSRange(location: selection.location + marker.utf16.count, length: content.utf16.count))
        case .link:
            let target = linkTarget?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !target.isEmpty else { return (source, selection) }
            let label = selection.length > 0 ? text.substring(with: selection) : "link text"
            let escaped = target.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ">", with: "\\>")
            return (text.replacingCharacters(in: selection, with: "[\(label)](<\(escaped)>)"),
                    NSRange(location: selection.location + 1, length: label.utf16.count))
        case .codeBlock:
            if let fence = fencedBlock(in: source, selection: selection) {
                guard let content = fence.content else { return (source, selection) }
                let offset = min(content.length, max(0, selection.location - content.location))
                return (text.replacingCharacters(in: fence.whole, with: text.substring(with: content)),
                        NSRange(location: fence.whole.location + offset,
                                length: min(selection.length, content.length - offset)))
            }
            let content = selection.length > 0 ? text.substring(with: selection) : "code"
            return (text.replacingCharacters(in: selection, with: "```\n" + content + "\n```"),
                    NSRange(location: selection.location + 4, length: content.utf16.count))
        case .heading(let level):
            guard (1...6).contains(level) else { return (source, selection) }
            let active = activeCommands(in: source, selection: selection).contains(command)
            return prefixLines(source, selection: selection) { _, line in
                let content = removingBlockPrefix(line)
                return active ? content : String(repeating: "#", count: level) + " " + content
            }
        case .unorderedList, .orderedList:
            let active = activeCommands(in: source, selection: selection).contains(command)
            return prefixLines(source, selection: selection) { index, line in
                let content = removingBlockPrefix(line)
                return active ? content : (command == .unorderedList ? "- " : "\(index + 1). ") + content
            }
        }
    }

    static func activeCommands(in source: String, selection proposed: NSRange) -> Set<RichDraftCommand> {
        let text = source as NSString
        let selection = clamped(proposed, length: text.length)
        if fencedBlock(in: source, selection: selection) != nil { return [.codeBlock] }
        var result = Set<RichDraftCommand>()
        for command: RichDraftCommand in [.bold, .italic, .inlineCode, .link] {
            if inlineEnclosure(command, source: source, selection: selection) != nil { result.insert(command) }
        }
        if result.contains(.inlineCode) { result.subtract([.bold, .italic, .link]) }
        let lines = selectedLines(source, selection: selection).body.components(separatedBy: "\n")
        if lines.allSatisfy({ listPrefix($0)?.number == nil && listPrefix($0) != nil }) { result.insert(.unorderedList) }
        if lines.allSatisfy({ listPrefix($0)?.number != nil }) { result.insert(.orderedList) }
        for level in 1...6 where lines.allSatisfy({ headingLevel($0) == level }) { result.insert(.heading(level)) }
        return result
    }

    /// Nil delegates an ordinary Return to UIKit. A second Return removes an
    /// empty marker; middle-of-item Return keeps the suffix on the new item.
    static func returning(in source: String, selection proposed: NSRange) -> (source: String, selection: NSRange)? {
        let text = source as NSString
        let selection = clamped(proposed, length: text.length)
        guard fencedBlock(in: source, selection: selection) == nil else { return nil }
        let lineRange = text.lineRange(for: NSRange(location: selection.location, length: 0))
        let line = text.substring(with: lineRange).trimmingCharacters(in: .newlines)
        guard let prefix = listPrefix(line), selection.location >= lineRange.location + prefix.length,
              NSMaxRange(selection) <= lineRange.location + line.utf16.count else { return nil }
        if String(line.dropFirst(prefix.characterCount)).trimmingCharacters(in: .whitespaces).isEmpty {
            let hasTerminator = lineRange.length > line.utf16.count
            // Consume the item's terminator too: retaining it adds a third newline.
            let separator = lineRange.location > 0 || hasTerminator ? "\n" : ""
            let hasFollowingLine = NSMaxRange(lineRange) < text.length
            let caretOffset = hasFollowingLine || lineRange.location == 0 ? 0 : separator.utf16.count
            return (text.replacingCharacters(in: lineRange, with: separator),
                    NSRange(location: lineRange.location + caretOffset, length: 0))
        }
        guard prefix.number != 999_999_999 else { return nil }
        let marker = prefix.number.map { "\($0 + 1)\(prefix.punctuation) " } ?? prefix.marker
        let replacement = "\n" + prefix.indent + marker
        return (text.replacingCharacters(in: selection, with: replacement),
                NSRange(location: selection.location + replacement.utf16.count, length: 0))
    }

    private struct Enclosure { var whole: NSRange; var content: NSRange }

    private static func inlineEnclosure(_ command: RichDraftCommand, source: String, selection: NSRange) -> Enclosure? {
        let patterns: [String]
        switch command {
        case .bold: patterns = [#"(?<![\\*])\*\*(\*.+?\*)\*\*(?!\*)"#, #"(?<![\\*])\*\*(.+?)\*\*(?!\*)"#, #"(?<![\\_])__(.+?)__(?!_)"#]
        case .italic: patterns = [#"(?<![\\*])\*(\*\*.+?\*\*)\*(?!\*)"#, #"(?<![\\*])\*(?!\*)(.+?)\*(?!\*)"#, #"(?<![\\_])_(?!_)(.+?)_(?!_)"#]
        case .inlineCode: patterns = [#"(?<![\\`])`([^`\n]+)`(?!`)"#]
        case .link: patterns = [#"(?<!!)\[([^\]\n]+)\]\((?:<[^>\n]*>|[^)\n]*)\)"#]
        default: return nil
        }
        let full = NSRange(location: 0, length: source.utf16.count)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: source, range: full) {
                let content = match.range(at: 1)
                if selection.location >= content.location, NSMaxRange(selection) <= NSMaxRange(content) {
                    return Enclosure(whole: match.range, content: content)
                }
            }
        }
        return nil
    }

    private struct ListPrefix {
        var length: Int
        var characterCount: Int
        var number: Int?
        var punctuation: String
        var marker: String
        var indent: String
    }

    private static func listPrefix(_ line: String) -> ListPrefix? {
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        let body = String(line.dropFirst(indent.count))
        let digits = body.prefix { $0.isASCII && $0.isNumber }
        let marker: String
        let number: Int?
        let punctuation: String
        if ["- ", "+ ", "* "].contains(String(body.prefix(2))) {
            marker = String(body.prefix(2)); number = nil; punctuation = ""
        } else {
            let suffix = body.dropFirst(digits.count)
            guard !digits.isEmpty, digits.count <= 9, let parsed = Int(digits), parsed > 0,
                  suffix.hasPrefix(". ") || suffix.hasPrefix(") ") else { return nil }
            punctuation = String(suffix.prefix(1)); number = parsed
            marker = String(digits) + punctuation + " "
        }
        let prefix = indent + marker
        return .init(length: prefix.utf16.count, characterCount: prefix.count, number: number,
                     punctuation: punctuation, marker: marker, indent: indent)
    }

    private static func headingLevel(_ line: String) -> Int? {
        let count = line.prefix { $0 == "#" }.count
        return (1...6).contains(count) && line.dropFirst(count).first == " " ? count : nil
    }

    private static func removingBlockPrefix(_ line: String) -> String {
        if let prefix = listPrefix(line) { return String(line.dropFirst(prefix.characterCount)) }
        if let level = headingLevel(line) { return String(line.dropFirst(level + 1)) }
        return line
    }

    private struct Fence { var whole: NSRange; var content: NSRange? }

    private static func fencedBlock(in source: String, selection: NSRange) -> Fence? {
        var offset = 0
        var opening: (offset: Int, content: Int, marker: Character, count: Int)?
        for line in source.components(separatedBy: "\n") {
            let trimmed = line.drop { $0 == " " }
            let end = offset + line.utf16.count
            if let active = opening {
                let count = trimmed.prefix { $0 == active.marker }.count
                if count >= active.count, trimmed.dropFirst(count).allSatisfy({ $0.isWhitespace }) {
                    if selection.location >= active.offset, NSMaxRange(selection) <= end {
                        return Fence(whole: NSRange(location: active.offset, length: end - active.offset),
                                     content: NSRange(location: active.content, length: max(0, offset - active.content - 1)))
                    }
                    opening = nil
                }
            } else if let marker = trimmed.first, marker == "`" || marker == "~" {
                let count = trimmed.prefix { $0 == marker }.count
                if count >= 3 { opening = (offset, end + 1, marker, count) }
            }
            offset = end + 1
        }
        if let opening, selection.location >= opening.offset {
            return Fence(whole: NSRange(location: opening.offset, length: source.utf16.count - opening.offset), content: nil)
        }
        return nil
    }

    private static func selectedLines(_ source: String, selection: NSRange) -> (range: NSRange, body: String, newline: Bool) {
        let text = source as NSString
        // A selection ending at the next line's start doesn't format that line.
        let probe = NSRange(location: selection.location, length: max(0, selection.length - 1))
        let range = text.lineRange(for: probe)
        let value = text.substring(with: range)
        let newline = value.hasSuffix("\n")
        return (range, newline ? String(value.dropLast()) : value, newline)
    }

    private static func prefixLines(_ source: String, selection: NSRange,
                                    transform: (Int, String) -> String) -> (source: String, selection: NSRange) {
        let lines = selectedLines(source, selection: selection)
        let body = lines.body.components(separatedBy: "\n").enumerated().map(transform).joined(separator: "\n")
        let replacement = body + (lines.newline ? "\n" : "")
        let updated = (source as NSString).replacingCharacters(in: lines.range, with: replacement)
        if selection.length == 0 {
            let delta = body.utf16.count - lines.body.utf16.count
            return (updated, NSRange(location: max(lines.range.location, selection.location + delta), length: 0))
        }
        return (updated, NSRange(location: lines.range.location, length: body.utf16.count))
    }

    private static func clamped(_ selection: NSRange, length: Int) -> NSRange {
        let location = min(max(0, selection.location), length)
        return NSRange(location: location, length: min(max(0, selection.length), length - location))
    }
}
