import Foundation

/// A bounded, editable Markdown model for native rich drafting.
///
/// Markdown remains the persisted authority. Import never rewrites the source, while export
/// emits semantically equivalent Markdown after an actual attributed-text edit. Rich mode
/// intentionally supports only paragraphs, ATX headings, flat ordered/unordered lists,
/// fenced code blocks, links, inline code, strong text, and emphasis. More exotic syntax
/// stays in source mode with an actionable explanation rather than being flattened.
enum RichDraftMarkdown {
    struct Style: OptionSet, Hashable, Sendable {
        let rawValue: Int

        static let bold = Style(rawValue: 1 << 0)
        static let italic = Style(rawValue: 1 << 1)
        static let code = Style(rawValue: 1 << 2)
        static let supported: Style = [.bold, .italic, .code]
    }

    struct Span: Equatable, Sendable {
        var text: String
        var style: Style = []
        /// The exact parsed destination used when this span is exported after an edit.
        var link: String?
    }

    enum Block: Equatable, Sendable {
        case paragraph(spans: [Span])
        case heading(level: Int, spans: [Span])
        case unorderedList(items: [[Span]])
        case orderedList(start: Int, items: [[Span]])
        case code(language: String?, text: String)
    }

    struct Document: Equatable, Sendable {
        var blocks: [Block]
        // Actual visual line breaks, not Markdown's canonical blank-line spacing.
        var leadingNewlines = 0
        var trailingNewlines = 0
        var blockSeparators: [Int] = []

        func separator(before index: Int) -> Int {
            blockSeparators.indices.contains(index - 1) ? blockSeparators[index - 1] : 2
        }

        mutating func preserveLayout(lineRanges: [Range<Int>], lineCount: Int) {
            guard let first = lineRanges.first, let last = lineRanges.last else {
                trailingNewlines = max(0, lineCount - 1)
                return
            }
            leadingNewlines = first.lowerBound
            trailingNewlines = max(0, lineCount - last.upperBound)
            blockSeparators = zip(lineRanges, lineRanges.dropFirst()).map {
                $0.1.lowerBound - $0.0.upperBound + 1
            }
            if blockSeparators.allSatisfy({ $0 == 2 }) { blockSeparators = [] }
        }

        init(spans: [Span]) {
            blocks = [.paragraph(spans: spans)]
        }

        init(blocks: [Block]) {
            self.blocks = blocks
        }

        /// Compatibility projection for callers that only need the visible inline content.
        /// Structural separators and list markers are presentation, not editable span text.
        var spans: [Span] {
            var result: [Span] = []
            if leadingNewlines > 0 { result.append(.init(text: String(repeating: "\n", count: leadingNewlines))) }
            for (index, block) in blocks.enumerated() {
                if index > 0 { result.append(.init(text: String(repeating: "\n", count: separator(before: index)))) }
                switch block {
                case .paragraph(let spans), .heading(_, let spans):
                    result.append(contentsOf: spans)
                case .unorderedList(let items), .orderedList(_, let items):
                    for (itemIndex, item) in items.enumerated() {
                        if itemIndex > 0 { result.append(.init(text: "\n")) }
                        result.append(contentsOf: item)
                    }
                case .code(_, let text):
                    result.append(.init(text: text, style: .code))
                }
            }
            if trailingNewlines > 0 { result.append(.init(text: String(repeating: "\n", count: trailingNewlines))) }
            return result
        }

        var plainText: String {
            spans.map(\.text).joined()
        }
    }

    enum ImportResult: Equatable, Sendable {
        case rich(Document)
        case source(reason: String)
    }

    enum AdapterError: Error, LocalizedError, Equatable {
        case unsupportedStyle
        case unsupportedStructure
        case invalidLink
        case unrepresentableBoundary

        var errorDescription: String? {
            switch self {
            case .unsupportedStyle:
                "Rich text supports bold, italic, links, and inline code within supported blocks. Use Markdown mode for this formatting."
            case .unsupportedStructure:
                "Use Markdown mode for nested blocks, indentation, hard breaks, or other advanced document structure."
            case .invalidLink:
                "This link target cannot be represented safely. Use Markdown mode to edit it."
            case .unrepresentableBoundary:
                "This formatting boundary cannot be represented safely. Use Markdown mode to edit it."
            }
        }
    }

    static func importSource(_ source: String) -> ImportResult {
        if let reason = sourceOnlyReason(source) {
            return .source(reason: reason)
        }
        do {
            let document = try parseDocument(source)
            // Eligibility includes a verified export path, but the canonical candidate is
            // deliberately discarded so entering rich mode cannot alter source bytes.
            let candidate = try serialize(document)
            let reparsed = try parseDocument(candidate)
            guard equivalent(document, reparsed) else {
                return .source(reason: "Markdown mode is required to preserve this draft’s formatting boundaries.")
            }
            return .rich(document)
        } catch {
            return .source(reason: sourceReason(for: error))
        }
    }

    static func export(_ document: Document) throws -> String {
        do {
            let candidate = try serialize(document)
            let reparsed = try parseDocument(candidate)
            guard equivalent(document, reparsed) else {
                throw AdapterError.unrepresentableBoundary
            }
            return candidate
        } catch let error as AdapterError {
            throw error
        } catch {
            // Private parser errors must never escape into an editor alert.
            throw AdapterError.unsupportedStructure
        }
    }

    /// Compares exact visible text, inline semantics, link targets, and block structure.
    /// Run boundaries and bold/italic styling on whitespace are not semantically relevant.
    static func equivalent(_ lhs: Document, _ rhs: Document) -> Bool {
        guard lhs.blocks.count == rhs.blocks.count,
              lhs.leadingNewlines == rhs.leadingNewlines,
              lhs.trailingNewlines == rhs.trailingNewlines,
              (1..<max(1, lhs.blocks.count)).allSatisfy({ lhs.separator(before: $0) == rhs.separator(before: $0) }) else { return false }
        return zip(lhs.blocks, rhs.blocks).allSatisfy { equivalent($0.0, $0.1) }
    }

    /// Swift String equality is canonically equivalent, not byte equality.
    static func sameSource(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }

    private struct Atom: Equatable {
        var character: Character
        var style: Style
        var link: String?
    }

    private enum ParseError: Error {
        case unsupportedInline
        case unsupportedBlock
        case malformedFence
    }

    private static func parseDocument(_ source: String) throws -> Document {
        if let _ = sourceOnlyReason(source) { throw ParseError.unsupportedBlock }
        if source.isEmpty { return Document(spans: [.init(text: "")]) }

        let lines = source.components(separatedBy: "\n")
        var blocks: [Block] = []
        var paragraphLines: [String] = []
        var paragraphStart = 0
        var lineRanges: [Range<Int>] = []
        var index = 0

        func flushParagraph() throws {
            guard !paragraphLines.isEmpty else { return }
            blocks.append(.paragraph(spans: try parseInline(paragraphLines.joined(separator: "\n"))))
            lineRanges.append(paragraphStart..<(paragraphStart + paragraphLines.count))
            paragraphLines.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let line = lines[index]
            if line.isEmpty {
                try flushParagraph()
                index += 1
                continue
            }

            if let fence = codeFenceOpening(line) {
                try flushParagraph()
                var content: [String] = []
                var cursor = index + 1
                while cursor < lines.count, !isCodeFenceClosing(lines[cursor], length: fence.length) {
                    content.append(lines[cursor])
                    cursor += 1
                }
                guard cursor < lines.count else { throw ParseError.malformedFence }
                blocks.append(.code(language: fence.language, text: content.joined(separator: "\n")))
                lineRanges.append(index..<(cursor + 1))
                index = cursor + 1
                continue
            }

            if let heading = heading(from: line) {
                try flushParagraph()
                blocks.append(.heading(level: heading.level, spans: try parseInline(heading.text)))
                lineRanges.append(index..<(index + 1))
                index += 1
                continue
            }

            if unorderedItem(from: line) != nil {
                try flushParagraph()
                let startLine = index
                var items: [[Span]] = []
                while index < lines.count, let item = unorderedItem(from: lines[index]) {
                    items.append(try parseInline(item))
                    index += 1
                }
                blocks.append(.unorderedList(items: items))
                lineRanges.append(startLine..<index)
                continue
            }

            if let first = orderedItem(from: line) {
                try flushParagraph()
                let startLine = index
                var items = [try parseInline(first.text)]
                let start = first.number
                var expected = start + 1
                index += 1
                while index < lines.count, let item = orderedItem(from: lines[index]), item.number == expected {
                    items.append(try parseInline(item.text))
                    expected += 1
                    index += 1
                }
                blocks.append(.orderedList(start: start, items: items))
                lineRanges.append(startLine..<index)
                continue
            }

            if paragraphLines.isEmpty { paragraphStart = index }
            paragraphLines.append(line)
            index += 1
        }
        try flushParagraph()
        var document = Document(blocks: blocks.isEmpty ? [.paragraph(spans: [.init(text: "")])] : blocks)
        document.preserveLayout(lineRanges: lineRanges, lineCount: lines.count)
        // A single visual newline is not always a Markdown block boundary. In
        // particular, unmarked prose after a list is a lazy list continuation.
        // Keep these unmodeled structures in source/recovery rather than flattening.
        for index in 1..<max(1, blocks.count) where document.separator(before: index) == 1 {
            switch (blocks[index - 1], blocks[index]) {
            case (.unorderedList, .paragraph), (.orderedList, .paragraph),
                 (.orderedList, .orderedList):
                throw ParseError.unsupportedBlock
            case (.paragraph, .orderedList(let start, _)) where start != 1:
                throw ParseError.unsupportedBlock
            default:
                break
            }
        }
        return document
    }

    private static func parseInline(_ source: String) throws -> [Span] {
        let parsed = try AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        var spans: [Span] = []
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            let allowed: InlinePresentationIntent = [
                .stronglyEmphasized, .emphasized, .code, .softBreak, .lineBreak
            ]
            guard intent.subtracting(allowed).isEmpty else { throw ParseError.unsupportedInline }
            var style: Style = []
            if intent.contains(.stronglyEmphasized) { style.insert(.bold) }
            if intent.contains(.emphasized) { style.insert(.italic) }
            if intent.contains(.code) { style.insert(.code) }
            let text = String(parsed[run.range].characters)
            let link = run.link?.absoluteString
            append(.init(text: text, style: style, link: link), to: &spans)
        }
        if spans.isEmpty { spans = [.init(text: "")] }
        return spans
    }

    private static func serialize(_ document: Document) throws -> String {
        guard !document.blocks.isEmpty else { return "" }
        var encoded: [String] = []
        for block in document.blocks {
            switch block {
            case .paragraph(let spans):
                encoded.append(try serializeInline(spans))
            case .heading(let level, let spans):
                guard (1...6).contains(level) else { throw AdapterError.unsupportedStructure }
                encoded.append(String(repeating: "#", count: level) + " " + (try serializeInline(spans)))
            case .unorderedList(let items):
                guard !items.isEmpty else { throw AdapterError.unsupportedStructure }
                encoded.append(try items.map { "- " + (try serializeInline($0)) }.joined(separator: "\n"))
            case .orderedList(let start, let items):
                guard start > 0, start <= 999_999_999, !items.isEmpty,
                      items.count <= 1_000_000_000 - start else { throw AdapterError.unsupportedStructure }
                encoded.append(try items.enumerated().map { offset, item in
                    "\(start + offset). " + (try serializeInline(item))
                }.joined(separator: "\n"))
            case .code(let language, let text):
                guard language?.contains(where: { $0.isWhitespace || $0 == "`" }) != true else {
                    throw AdapterError.unsupportedStructure
                }
                let fenceLength = max(3, longestBacktickRun(in: text) + 1)
                let fence = String(repeating: "`", count: fenceLength)
                encoded.append(fence + (language ?? "") + "\n" + text + "\n" + fence)
            }
        }
        guard document.leadingNewlines >= 0, document.trailingNewlines >= 0 else {
            throw AdapterError.unsupportedStructure
        }
        var result = String(repeating: "\n", count: document.leadingNewlines)
        for (index, block) in encoded.enumerated() {
            if index > 0 {
                let count = document.separator(before: index)
                guard count > 0 else { throw AdapterError.unsupportedStructure }
                result += String(repeating: "\n", count: count)
            }
            result += block
        }
        result += String(repeating: "\n", count: document.trailingNewlines)
        return result
    }

    private static func serializeInline(_ spans: [Span]) throws -> String {
        guard spans.allSatisfy({ $0.style.subtracting(.supported).isEmpty }) else {
            throw AdapterError.unsupportedStyle
        }
        let atoms = normalizedAtoms(spans)
        for boldFirst in [true, false] {
            for italicMarker in ["*", "_"] {
                for boldMarker in ["**", "__"] {
                    guard let candidate = try? serializeGroups(
                        atoms,
                        boldFirst: boldFirst,
                        boldMarker: boldMarker,
                        italicMarker: italicMarker
                    ), let decoded = try? parseInline(candidate), equivalent(spans, decoded) else {
                        continue
                    }
                    return candidate
                }
            }
        }
        throw AdapterError.unrepresentableBoundary
    }

    private static func serializeGroups(
        _ atoms: [Atom],
        boldFirst: Bool,
        boldMarker: String,
        italicMarker: String
    ) throws -> String {
        guard !atoms.isEmpty else { return "" }
        // Line boundaries belong to the complete inline sequence, not to the
        // individual link/code groups that happen to split its attributed runs.
        var boundaryWhitespace = Set<Int>()
        var atLineStart = true
        for index in atoms.indices {
            let character = atoms[index].character
            if character == "\n" {
                atLineStart = true
            } else if character == " " || character == "\t" {
                if atLineStart { boundaryWhitespace.insert(index) }
            } else {
                atLineStart = false
            }
        }
        var atLineEnd = true
        for index in atoms.indices.reversed() {
            let character = atoms[index].character
            if character == "\n" {
                atLineEnd = true
            } else if character == " " || character == "\t" {
                if atLineEnd { boundaryWhitespace.insert(index) }
            } else {
                atLineEnd = false
            }
        }
        var result = ""
        var index = 0
        while index < atoms.count {
            let first = atoms[index]
            let isCode = first.style.contains(.code)
            var end = index + 1
            while end < atoms.count,
                  atoms[end].link == first.link,
                  atoms[end].style.contains(.code) == isCode {
                end += 1
            }
            let group = Array(atoms[index..<end])
            let value: String
            if isCode {
                guard group.allSatisfy({ $0.style.subtracting(.code).isEmpty }) else {
                    throw AdapterError.unsupportedStyle
                }
                value = codeSpan(group.map(\.character))
            } else {
                value = serializeStyled(
                    group,
                    offset: index,
                    boundaryWhitespace: boundaryWhitespace,
                    boldFirst: boldFirst,
                    boldMarker: boldMarker,
                    italicMarker: italicMarker
                )
            }
            if let link = first.link {
                guard !link.contains(where: { $0 == "\n" || $0 == "\r" }) else {
                    throw AdapterError.invalidLink
                }
                result += "[" + value + "](<" + escapeLinkDestination(link) + ">)"
            } else {
                result += value
            }
            index = end
        }
        return result
    }

    private static func serializeStyled(
        _ atoms: [Atom],
        offset: Int,
        boundaryWhitespace: Set<Int>,
        boldFirst: Bool,
        boldMarker: String,
        italicMarker: String
    ) -> String {
        var result = ""
        var isBlockPrefix = true
        var hasLeadingDigit = false
        var open: [Style] = []
        let order: [Style] = boldFirst ? [.bold, .italic] : [.italic, .bold]

        func marker(_ style: Style) -> String { style == .bold ? boldMarker : italicMarker }
        // Normalization ignores emphasis on whitespace for semantic comparison.
        // Keep shared emphasis open across interior spaces when emitting Markdown,
        // rather than turning a multiword bold span into separate bold words.
        var styles = atoms.map(\.style)
        var index = 0
        while index < atoms.count {
            guard atoms[index].character == " " || atoms[index].character == "\t" else {
                index += 1
                continue
            }
            let start = index
            while index < atoms.count,
                  atoms[index].character == " " || atoms[index].character == "\t" {
                index += 1
            }
            if start > 0, index < atoms.count {
                let shared = atoms[start - 1].style.intersection(atoms[index].style)
                for whitespaceIndex in start..<index { styles[whitespaceIndex] = shared }
            }
        }

        for (atomIndex, atom) in atoms.enumerated() {
            let wanted = order.filter { styles[atomIndex].contains($0) }
            var shared = 0
            while shared < min(open.count, wanted.count), open[shared] == wanted[shared] {
                shared += 1
            }
            for style in open.dropFirst(shared).reversed() { result += marker(style) }
            for style in wanted.dropFirst(shared) { result += marker(style) }
            open = wanted

            // Encode boundary whitespace as visible characters, not Markdown indentation
            // or hard-break syntax. Inline code/link destinations use their own encoders.
            if boundaryWhitespace.contains(offset + atomIndex) {
                result += atom.character == " " ? "&#32;" : "&#9;"
            } else if isBlockPrefix, hasLeadingDigit, atom.character == "." || atom.character == ")" {
                result += "\\" + String(atom.character)
            } else if isBlockPrefix, !hasLeadingDigit, "#=+-".contains(atom.character) {
                result += "\\" + String(atom.character)
            } else {
                result += escapeInline(atom.character)
            }

            if atom.character == "\n" {
                isBlockPrefix = true
                hasLeadingDigit = false
            } else if isBlockPrefix {
                if atom.character.isASCII, atom.character.isNumber {
                    hasLeadingDigit = true
                } else if atom.character != " " || hasLeadingDigit {
                    isBlockPrefix = false
                }
            }
        }
        for style in open.reversed() { result += marker(style) }
        return result
    }

    private static func codeSpan(_ characters: [Character]) -> String {
        let text = String(characters)
        let delimiter = String(repeating: "`", count: max(1, longestBacktickRun(in: text) + 1))
        let needsPadding = text.first == "`" || text.last == "`"
            || (text.first?.isWhitespace == true && text.last?.isWhitespace == true && !text.allSatisfy(\.isWhitespace))
        return needsPadding ? delimiter + " " + text + " " + delimiter : delimiter + text + delimiter
    }

    private static func escapeInline(_ character: Character) -> String {
        let syntax = "\\`*_[]<>~&|"
        return syntax.contains(character) ? "\\" + String(character) : String(character)
    }

    private static func escapeLinkDestination(_ destination: String) -> String {
        var result = ""
        for character in destination {
            if character == "\\" || character == ">" { result += "\\" }
            result.append(character)
        }
        return result
    }

    private static func normalizedAtoms(_ spans: [Span]) -> [Atom] {
        spans.flatMap { span in
            span.text.map { character in
                let style = character.isWhitespace ? span.style.intersection(.code) : span.style
                return Atom(character: character, style: style, link: span.link)
            }
        }
    }

    private static func equivalent(_ lhs: Block, _ rhs: Block) -> Bool {
        switch (lhs, rhs) {
        case (.paragraph(let a), .paragraph(let b)):
            equivalent(a, b)
        case (.heading(let aLevel, let a), .heading(let bLevel, let b)):
            aLevel == bLevel && equivalent(a, b)
        case (.unorderedList(let a), .unorderedList(let b)):
            equivalent(a, b)
        case (.orderedList(let aStart, let a), .orderedList(let bStart, let b)):
            aStart == bStart && equivalent(a, b)
        case (.code(let aLanguage, let aText), .code(let bLanguage, let bText)):
            aLanguage == bLanguage && sameSource(aText, bText)
        default:
            false
        }
    }

    private static func equivalent(_ lhs: [[Span]], _ rhs: [[Span]]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { equivalent($0.0, $0.1) }
    }

    private static func equivalent(_ lhs: [Span], _ rhs: [Span]) -> Bool {
        sameSource(lhs.map(\.text).joined(), rhs.map(\.text).joined())
            && normalizedAtoms(lhs) == normalizedAtoms(rhs)
    }

    private static func append(_ span: Span, to spans: inout [Span]) {
        if spans.last?.style == span.style, spans.last?.link == span.link {
            spans[spans.count - 1].text += span.text
        } else {
            spans.append(span)
        }
    }

    private static func heading(from line: String) -> (level: Int, text: String)? {
        let count = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(count), line.dropFirst(count).first == " " else { return nil }
        return (count, String(line.dropFirst(count + 1)))
    }

    private static func unorderedItem(from line: String) -> String? {
        guard line.count >= 2, let first = line.first, "-+*".contains(first), line.dropFirst().first == " " else {
            return nil
        }
        return String(line.dropFirst(2))
    }

    private static func orderedItem(from line: String) -> (number: Int, text: String)? {
        let digits = line.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty, digits.count <= 9, let number = Int(digits), number > 0 else { return nil }
        let remainder = line.dropFirst(digits.count)
        guard let punctuation = remainder.first, punctuation == "." || punctuation == ")",
              remainder.dropFirst().first == " " else { return nil }
        return (number, String(remainder.dropFirst(2)))
    }

    private static func codeFenceOpening(_ line: String) -> (length: Int, language: String?)? {
        let length = line.prefix(while: { $0 == "`" }).count
        guard length >= 3 else { return nil }
        let info = String(line.dropFirst(length))
        guard !info.contains("`"), !info.contains(where: { $0.isWhitespace }) else { return nil }
        return (length, info.isEmpty ? nil : info)
    }

    private static func isCodeFenceClosing(_ line: String, length: Int) -> Bool {
        let trimmed = line.drop(while: { $0 == " " })
        let count = trimmed.prefix(while: { $0 == "`" }).count
        return count >= length && trimmed.dropFirst(count).allSatisfy { $0 == " " }
    }

    private static func longestBacktickRun(in value: String) -> Int {
        var longest = 0
        var current = 0
        for character in value {
            if character == "`" {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }

    private static func sourceOnlyReason(_ source: String) -> String? {
        if source.unicodeScalars.contains(where: { $0.value == 13 }) {
            return "Markdown mode preserves this draft’s original line endings. Convert them to standard line breaks to use Rich Text."
        }
        let lines = source.components(separatedBy: "\n")
        var proseLines: [String] = []
        var activeFenceLength: Int?
        for line in lines {
            if let length = activeFenceLength {
                if isCodeFenceClosing(line, length: length) { activeFenceLength = nil }
                continue
            }
            if let fence = codeFenceOpening(line) {
                activeFenceLength = fence.length
                continue
            }
            proseLines.append(line)
            if line.hasPrefix("    ") || line.hasPrefix("\t") || line.hasSuffix("  ") || line.hasSuffix("\t") {
                return "Markdown mode preserves indentation and hard line breaks. Remove those structures to use Rich Text."
            }
            let trimmed = line.drop(while: { $0 == " " })
            let leadingSpaces = line.count - trimmed.count
            if leadingSpaces > 0,
               (unorderedItem(from: String(trimmed)) != nil || orderedItem(from: String(trimmed)) != nil) {
                return "Markdown mode preserves nested or indented lists. Flatten the list to use Rich Text."
            }
            if trimmed.hasPrefix(">") {
                return "Markdown mode preserves block quotes. Remove the quote structure to use Rich Text."
            }
            if trimmed.hasPrefix("~~~") {
                return "Markdown mode preserves tilde-fenced code. Use backtick fences to edit this draft in Rich Text."
            }
            if isThematicRule(trimmed) {
                return "Markdown mode preserves thematic rules and setext headings. Use an ATX heading such as “## Heading” for Rich Text."
            }
            if isTableDelimiter(trimmed) {
                return "Markdown mode preserves tables. Remove the table structure to use Rich Text."
            }
            if trimmed.hasPrefix("- [") || trimmed.hasPrefix("* [") || trimmed.hasPrefix("+ [") {
                return "Markdown mode preserves task lists. Use a plain bulleted list to edit this draft in Rich Text."
            }
            if isLinkDefinition(trimmed) {
                return "Markdown mode preserves reference links. Use an inline link to edit this draft in Rich Text."
            }
            if hasOddTrailingBackslash(line) {
                return "Markdown mode preserves backslash hard breaks. Remove the hard break to use Rich Text."
            }
        }
        let prose = removingInlineCode(from: proseLines.joined(separator: "\n"))
        if prose.contains("![") {
            return "Markdown mode preserves image syntax. Remove the image or edit it in Markdown mode."
        }
        if containsRawHTML(prose) {
            return "Markdown mode preserves embedded HTML. Remove the HTML to use Rich Text."
        }
        if containsEntity(prose) {
            return "Markdown mode preserves named and numeric entities. Use the visible character to edit this draft in Rich Text."
        }
        return nil
    }

    /// Prose-only restrictions must not inspect the literal contents of code spans.
    private static func removingInlineCode(from source: String) -> String {
        var result = ""
        var cursor = source.startIndex
        while cursor < source.endIndex {
            if source[cursor] == "\\" {
                result.append(source[cursor])
                cursor = source.index(after: cursor)
                if cursor < source.endIndex {
                    result.append(source[cursor])
                    cursor = source.index(after: cursor)
                }
                continue
            }
            guard source[cursor] == "`" else {
                result.append(source[cursor])
                cursor = source.index(after: cursor)
                continue
            }
            let start = cursor
            while cursor < source.endIndex, source[cursor] == "`" {
                cursor = source.index(after: cursor)
            }
            let length = source.distance(from: start, to: cursor)
            var search = cursor
            var closingEnd: String.Index?
            while search < source.endIndex {
                guard source[search] == "`" else {
                    search = source.index(after: search)
                    continue
                }
                let runStart = search
                while search < source.endIndex, source[search] == "`" {
                    search = source.index(after: search)
                }
                if source.distance(from: runStart, to: search) == length {
                    closingEnd = search
                    break
                }
            }
            if let closingEnd {
                result.append(" ")
                cursor = closingEnd
            } else {
                result += source[start..<cursor]
            }
        }
        return result
    }

    private static func hasOddTrailingBackslash(_ value: String) -> Bool {
        value.reversed().prefix(while: { $0 == "\\" }).count.isMultiple(of: 2) == false
    }

    private static func isThematicRule(_ line: Substring) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3, let first = compact.first, "-*_=".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func isTableDelimiter(_ line: Substring) -> Bool {
        guard line.contains("|") else { return false }
        let cells = line.split(separator: "|", omittingEmptySubsequences: false)
        return cells.contains { cell in
            let value = String(cell).trimmingCharacters(in: .whitespaces)
            let core = value.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return core.count >= 3 && core.allSatisfy { $0 == "-" }
        }
    }

    private static func isLinkDefinition(_ line: Substring) -> Bool {
        guard line.first == "[", let close = line.firstIndex(of: "]") else { return false }
        let after = line.index(after: close)
        return after < line.endIndex && line[after] == ":"
    }

    private static func isEscaped(_ index: String.Index, in source: String) -> Bool {
        var cursor = index
        var count = 0
        while cursor > source.startIndex {
            cursor = source.index(before: cursor)
            guard source[cursor] == "\\" else { break }
            count += 1
        }
        return !count.isMultiple(of: 2)
    }

    private static func containsRawHTML(_ source: String) -> Bool {
        var cursor = source.startIndex
        while let open = source[cursor...].firstIndex(of: "<"),
              let close = source[open...].firstIndex(of: ">") {
            let inner = source[source.index(after: open)..<close]
            if !isEscaped(open, in: source), let first = inner.first,
               first == "/" || first == "!" || first.isLetter,
               !inner.hasPrefix("http://"), !inner.hasPrefix("https://"), !inner.hasPrefix("mailto:") {
                return true
            }
            cursor = source.index(after: close)
        }
        return false
    }

    private static func containsEntity(_ source: String) -> Bool {
        var cursor = source.startIndex
        while let ampersand = source[cursor...].firstIndex(of: "&"),
              let semicolon = source[ampersand...].firstIndex(of: ";") {
            let body = source[source.index(after: ampersand)..<semicolon]
            // These two entities are explicitly modeled literal whitespace, including
            // export's safe encoding of transient indentation/trailing spaces.
            if !isEscaped(ampersand, in: source), body != "#32", body != "#9",
               !body.isEmpty, body.count <= 32,
               body.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "#" || $0 == "x") }) {
                return true
            }
            cursor = source.index(after: ampersand)
        }
        return false
    }

    private static func sourceReason(for error: Error) -> String {
        if let error = error as? AdapterError, let description = error.errorDescription {
            return description
        }
        if let error = error as? ParseError {
            switch error {
            case .malformedFence:
                return "Markdown mode preserves this incomplete code fence. Close the fence to use Rich Text."
            case .unsupportedInline:
                return "Markdown mode preserves advanced inline formatting. Rich Text supports bold, italic, links, and inline code."
            case .unsupportedBlock:
                break
            }
        }
        return "Markdown mode preserves unsupported or ambiguous block formatting. Simplify the structure to use Rich Text."
    }
}
