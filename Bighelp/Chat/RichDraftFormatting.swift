import SwiftUI
import UIKit

/// Native attributed-text projection for `RichDraftMarkdown.Document`.
///
/// Block semantics are represented visually with dynamic fonts and list markers rather than
/// raw Markdown punctuation. Converting the edited projection back to the model reads those
/// same presentation roles, so Markdown remains the only persisted authority.
@available(iOS 26.0, *)
enum RichDraftFormatting {
    enum BlockKind: Equatable {
        case heading(Int)
        case unorderedList
        case orderedList
        case codeBlock
    }

    private enum Role: CaseIterable {
        case body
        case heading1
        case heading2
        case heading3
        case heading4
        case heading5
        case heading6
        case codeBlock
        case codeLanguage

        var headingLevel: Int? {
            switch self {
            case .heading1: 1
            case .heading2: 2
            case .heading3: 3
            case .heading4: 4
            case .heading5: 5
            case .heading6: 6
            default: nil
            }
        }

        var baseFont: Font {
            switch self {
            case .body: .body
            case .heading1: .largeTitle
            case .heading2: .title
            case .heading3: .title2
            case .heading4: .title3
            case .heading5: .headline
            case .heading6: .subheadline
            case .codeBlock: .callout.monospaced()
            case .codeLanguage: .caption.monospaced().bold()
            }
        }
    }

    private struct Presentation {
        var role: Role
        var style: RichDraftMarkdown.Style
    }

    private struct VisualLine {
        var text: AttributedString
        var separatorFont: Font?
        // The terminal empty code line belongs to the preceding code newline,
        // independently of the body separator that may follow it.
        var emptyRoleFont: Font? = nil

        var string: String { String(text.characters) }
        var isEmpty: Bool { text.characters.isEmpty }
    }

    private static let codeBackground = Color.secondary.opacity(0.14)
    private static let semanticStyles: [RichDraftMarkdown.Style] = [
        [], .bold, .italic, [.bold, .italic], .code
    ]

    static func font(for style: RichDraftMarkdown.Style) -> Font {
        font(for: style, role: .body)
    }

    /// Explicit rendering for the UIKit editor; semantic roles still belong to this adapter.
    static func nativeFont(for font: Font?, context: Font.Context, theme: BighelpTheme = .light) -> UIFont {
        let value = presentation(for: font, context: context)
        let textStyle: UIFont.TextStyle = switch value.role {
        case .body: .body
        case .heading1: .largeTitle
        case .heading2: .title1
        case .heading3: .title2
        case .heading4: .title3
        case .heading5: .headline
        case .heading6: .subheadline
        case .codeBlock: .callout
        case .codeLanguage: .caption1
        }
        let preferred = UIFont.bighelp(textStyle)
        let role: BighelpFontRole = value.role == .body ? .body : .sectionTitle
        var descriptor = theme.uiFont(role).fontDescriptor.withSize(preferred.pointSize)
        if value.style.contains(.code) || value.role == .codeBlock || value.role == .codeLanguage {
            descriptor = descriptor.withDesign(.monospaced) ?? descriptor
        }
        var traits = descriptor.symbolicTraits
        if value.style.contains(.bold) || value.role == .codeLanguage { traits.insert(.traitBold) }
        if value.style.contains(.italic) { traits.insert(.traitItalic) }
        descriptor = descriptor.withSymbolicTraits(traits) ?? descriptor
        return UIFont(descriptor: descriptor, size: 0).bighelpApplyingTraits(traits)
    }

    /// Foreign fonts have no app-owned block role. Preserve public traits without
    /// guessing that a large pasted font is a Markdown heading or fenced code.
    static func semanticFont(for nativeFont: UIFont) -> Font {
        let traits = nativeFont.fontDescriptor.symbolicTraits
        var style: RichDraftMarkdown.Style = []
        if traits.contains(.traitMonoSpace) { style.insert(.code) }
        if traits.contains(.traitBold) { style.insert(.bold) }
        if traits.contains(.traitItalic) { style.insert(.italic) }
        return font(for: style)
    }

    static func style(for font: Font?, context: Font.Context) -> RichDraftMarkdown.Style {
        presentation(for: font, context: context).style
    }

    static func losslessAttributed(
        _ document: RichDraftMarkdown.Document, context: Font.Context
    ) -> AttributedString? {
        let text = attributed(document)
        return RichDraftMarkdown.equivalent(document, Self.document(text, context: context)) ? text : nil
    }

    static func attributed(_ document: RichDraftMarkdown.Document) -> AttributedString {
        var result = piece(String(repeating: "\n", count: document.leadingNewlines), role: .body)
        for (index, block) in document.blocks.enumerated() {
            if index > 0 {
                result.append(piece(String(repeating: "\n", count: document.separator(before: index)), role: .body))
            }
            append(block, to: &result)
        }
        result.append(piece(String(repeating: "\n", count: document.trailingNewlines), role: .body))
        return result
    }

    static func document(
        _ text: AttributedString, context: Font.Context, typingAttributes: AttributeContainer? = nil
    ) -> RichDraftMarkdown.Document {
        let lines = visualLines(in: text)
        var blocks: [RichDraftMarkdown.Block] = []
        var lineRanges: [Range<Int>] = []
        var index = 0

        while index < lines.count {
            let start = index
            let blockCount = blocks.count
            defer {
                if blocks.count > blockCount { lineRanges.append(start..<index) }
            }
            let line = lines[index]
            let role = line.isEmpty && line.emptyRoleFont == nil
                && index == lines.count - 1 && typingAttributes != nil
                ? presentation(for: typingAttributes?.font, context: context).role
                : role(of: line, context: context)
            if line.isEmpty, role != .codeBlock, role.headingLevel == nil {
                index += 1
                continue
            }

            if let level = role.headingLevel {
                blocks.append(.heading(level: level, spans: inlineSpans(in: line.text, context: context)))
                index += 1
                continue
            }

            if role == .codeLanguage {
                let language = line.string.isEmpty ? nil : line.string
                index += 1
                let code = consumeCodeLines(lines, from: &index, context: context)
                blocks.append(.code(language: language, text: code))
                continue
            }

            if role == .codeBlock {
                let code = consumeCodeLines(lines, from: &index, context: context)
                blocks.append(.code(language: nil, text: code))
                continue
            }

            if bulletPrefixLength(in: line) != nil {
                var items: [[RichDraftMarkdown.Span]] = []
                while index < lines.count,
                      let prefixLength = bulletPrefixLength(in: lines[index]) {
                    items.append(inlineSpans(
                        in: droppingFirst(prefixLength, from: lines[index].text),
                        context: context
                    ))
                    index += 1
                }
                blocks.append(.unorderedList(items: items))
                continue
            }

            if let first = orderedPrefix(in: line) {
                let start = first.number
                var expected = start
                var items: [[RichDraftMarkdown.Span]] = []
                while index < lines.count,
                      let prefix = orderedPrefix(in: lines[index]),
                      prefix.number == expected {
                    items.append(inlineSpans(
                        in: droppingFirst(prefix.length, from: lines[index].text),
                        context: context
                    ))
                    expected += 1
                    index += 1
                }
                blocks.append(.orderedList(start: start, items: items))
                continue
            }

            var paragraph: [RichDraftMarkdown.Span] = []
            while index < lines.count {
                let candidate = lines[index]
                let candidateRole = Self.role(of: candidate, context: context)
                if candidate.isEmpty || candidateRole.headingLevel != nil
                    || candidateRole == .codeBlock || candidateRole == .codeLanguage
                    || bulletPrefixLength(in: candidate) != nil
                    || orderedPrefix(in: candidate) != nil {
                    break
                }
                if !paragraph.isEmpty { append(.init(text: "\n"), to: &paragraph) }
                for span in inlineSpans(in: candidate.text, context: context) {
                    append(span, to: &paragraph)
                }
                index += 1
            }
            blocks.append(.paragraph(spans: paragraph.isEmpty ? [.init(text: "")] : paragraph))
        }

        var document = RichDraftMarkdown.Document(blocks: blocks.isEmpty ? [.paragraph(spans: [.init(text: "")])] : blocks)
        document.preserveLayout(lineRanges: lineRanges, lineCount: lines.count)
        return document
    }

    /// Whole-selection toggling preserves each run's heading/body role and the other trait.
    /// Code blocks reject strong/emphasis because fenced Markdown cannot encode those traits.
    static func toggling(
        _ trait: RichDraftMarkdown.Style,
        in text: AttributedString,
        selection: AttributedTextSelection,
        context: Font.Context
    ) throws -> (text: AttributedString, selection: AttributedTextSelection, markdown: String) {
        guard trait == .bold || trait == .italic || trait == .code else {
            throw RichDraftMarkdown.AdapterError.unsupportedStyle
        }
        let attributes: [AttributeContainer]
        if case .insertionPoint = selection.indices(in: text) {
            attributes = [selection.typingAttributes(in: text)]
        } else {
            attributes = Array(selection.attributes(in: text))
        }
        guard !attributes.contains(where: {
            let role = presentation(for: $0.font, context: context).role
            return role == .codeBlock || role == .codeLanguage
        }) else {
            throw RichDraftMarkdown.AdapterError.unsupportedStyle
        }
        let remove = !attributes.isEmpty && attributes.allSatisfy {
            presentation(for: $0.font, context: context).style.contains(trait)
        }
        var edited = text
        var updatedSelection = selection
        edited.transformAttributes(in: &updatedSelection) { attributes in
            var value = presentation(for: attributes.font, context: context)
            if value.role == .codeBlock || value.role == .codeLanguage { return }
            if remove {
                value.style.remove(trait)
            } else if trait == .code {
                value.style = .code
            } else {
                value.style.remove(.code)
                value.style.insert(trait)
            }
            attributes.font = font(for: value.style, role: value.role)
            attributes.backgroundColor = value.style.contains(.code) ? codeBackground : nil
        }
        let markdown = try RichDraftMarkdown.export(document(
            edited, context: context, typingAttributes: trailingTypingAttributes(in: edited, selection: updatedSelection)
        ))
        return (edited, updatedSelection, markdown)
    }

    static func applyingLink(
        _ url: URL,
        in text: AttributedString,
        selection: AttributedTextSelection,
        context: Font.Context
    ) throws -> (text: AttributedString, selection: AttributedTextSelection, markdown: String) {
        var edited = text
        var updatedSelection = selection
        if selectionHasCharacters(selection, in: text) {
            edited.transformAttributes(in: &updatedSelection) { attributes in
                let role = presentation(for: attributes.font, context: context).role
                guard role != .codeBlock && role != .codeLanguage else { return }
                attributes.link = url
                attributes.foregroundColor = .accentColor
                attributes.underlineStyle = .single
            }
            // List markers are structural presentation, not link-label content.
            edited.transform(updating: &updatedSelection) { value in
                for line in selectedLineRanges(in: text, selection: selection) {
                    guard let marker = listMarker(in: AttributedString(text[line])) else { continue }
                    let end = text.characters.index(line.lowerBound, offsetBy: marker.length)
                    let prefix = line.lowerBound..<end
                    value[prefix].link = nil
                    value[prefix].foregroundColor = .secondary
                    value[prefix].underlineStyle = nil
                }
            }
        } else {
            var label = piece("Link text", role: .body)
            label.link = url
            label.foregroundColor = .accentColor
            label.underlineStyle = .single
            edited.replaceSelection(&updatedSelection, with: label)
        }
        let markdown = try RichDraftMarkdown.export(document(
            edited, context: context, typingAttributes: trailingTypingAttributes(in: edited, selection: updatedSelection)
        ))
        return (edited, updatedSelection, markdown)
    }

    static func applyingBlock(
        _ kind: BlockKind,
        in text: AttributedString,
        selection: AttributedTextSelection,
        context: Font.Context
    ) throws -> (text: AttributedString, selection: AttributedTextSelection, markdown: String) {
        var edited = text
        var updatedSelection = selection
        let lines = selectedLineRanges(in: text, selection: selection)

        switch kind {
        case .heading(let level):
            guard (1...6).contains(level) else { throw RichDraftMarkdown.AdapterError.unsupportedStructure }
            let role: Role = switch level {
            case 1: .heading1
            case 2: .heading2
            case 3: .heading3
            case 4: .heading4
            case 5: .heading5
            default: .heading6
            }
            if lines.allSatisfy({ $0.isEmpty }) {
                edited.transformAttributes(in: &updatedSelection) { attributes in
                    attributes.font = font(for: [], role: role)
                    attributes.backgroundColor = nil
                    attributes.link = nil
                    attributes.foregroundColor = nil
                    attributes.underlineStyle = nil
                }
            } else {
                edited.transform(updating: &updatedSelection) { value in
                    for line in lines {
                        let runs = value[line].runs.map { ($0.range, presentation(for: $0.font, context: context).style) }
                        for (range, style) in runs {
                            value[range].font = font(for: style.subtracting(.code), role: role)
                            value[range].backgroundColor = nil
                        }
                    }
                }
            }
        case .unorderedList, .orderedList:
            guard !lines.contains(where: { isCodeBlock(AttributedString(text[$0]), context: context) }) else {
                throw RichDraftMarkdown.AdapterError.unsupportedStructure
            }
            edited.transform(updating: &updatedSelection) { value in
                for (offset, line) in lines.enumerated().reversed() {
                    let original = AttributedString(value[line])
                    let existingPrefix = listMarker(in: original)?.length ?? 0
                    let content = droppingFirst(existingPrefix, from: original)
                    var replacement = listMarker(number: kind == .unorderedList ? nil : offset + 1)
                    replacement.append(settingParagraphRole(content, heading: nil, context: context))
                    value.replaceSubrange(line, with: replacement)
                }
            }
            let insertionPoint: AttributedString.Index?
            if case .insertionPoint(let point) = selection.indices(in: text) {
                insertionPoint = point
            } else if lines.count == 1, let line = lines.first, line.isEmpty {
                // Before native focus establishes a caret, an empty draft can have
                // no selection. Its new item still needs an explicit typing position.
                insertionPoint = line.lowerBound
            } else {
                insertionPoint = nil
            }
            if let point = insertionPoint, let line = lines.first {
                let original = AttributedString(text[line])
                let oldPrefix = listMarker(in: original)?.length ?? 0
                let newPrefix = kind == .unorderedList ? 2 : 3
                let lineOffset = text.characters.distance(from: text.startIndex, to: line.lowerBound)
                let contentOffset = max(0, text.characters.distance(from: line.lowerBound, to: point) - oldPrefix)
                let caret = edited.characters.index(edited.startIndex, offsetBy: lineOffset + newPrefix + contentOffset)
                var attributes = selection.typingAttributes(in: text)
                attributes.font = font(for: style(for: attributes.font, context: context))
                attributes.foregroundColor = nil
                updatedSelection = .init(insertionPoint: caret, typingAttributes: attributes)
            }
        case .codeBlock:
            if lines.allSatisfy({ $0.isEmpty }) {
                var code = piece("Code", role: .codeBlock)
                code.backgroundColor = codeBackground
                edited.replaceSelection(&updatedSelection, with: code)
            } else {
                edited.transform(updating: &updatedSelection) { value in
                    for line in lines {
                        value[line].font = font(for: [], role: .codeBlock)
                        value[line].backgroundColor = codeBackground
                        value[line].foregroundColor = nil
                        value[line].underlineStyle = nil
                        value[line].link = nil
                    }
                }
            }
        }

        let markdown = try RichDraftMarkdown.export(document(
            edited, context: context, typingAttributes: trailingTypingAttributes(in: edited, selection: updatedSelection)
        ))
        return (edited, updatedSelection, markdown)
    }

    /// Toolbar state is a projection of the live selection/typing attributes.
    /// Mixed selections are inactive, matching whole-selection toggle semantics.
    static func activeCommands(in text: AttributedString, selection: AttributedTextSelection,
                               context: Font.Context) -> Set<RichDraftCommand> {
        let attributes: [AttributeContainer]
        switch selection.indices(in: text) {
        case .insertionPoint:
            attributes = [selection.typingAttributes(in: text)]
        case .ranges(let ranges):
            attributes = ranges.ranges.flatMap { text[$0].runs.map(\.attributes) }
        }
        var result = Set<RichDraftCommand>()
        if !attributes.isEmpty {
            for (command, style): (RichDraftCommand, RichDraftMarkdown.Style) in [(.bold, .bold), (.italic, .italic), (.inlineCode, .code)] {
                if attributes.allSatisfy({ presentation(for: $0.font, context: context).style.contains(style) }) {
                    result.insert(command)
                }
            }
            if attributes.allSatisfy({ $0.link != nil }) { result.insert(.link) }
        }
        let lines = selectedLineRanges(in: text, selection: selection).map { AttributedString(text[$0]) }
        if !lines.isEmpty {
            if lines.allSatisfy({ listMarker(in: $0) != nil && listMarker(in: $0)?.number == nil }) { result.insert(.unorderedList) }
            if lines.allSatisfy({ listMarker(in: $0)?.number != nil }) { result.insert(.orderedList) }
            if lines.allSatisfy({ isCodeBlock($0, context: context) }) { result.insert(.codeBlock) }
            for level in 1...6 where lines.allSatisfy({ line in
                headingLevel(in: line, context: context) == level
                    || (line.characters.isEmpty && attributes.allSatisfy({ headingLevel(for: $0, context: context) == level }))
            }) { result.insert(.heading(level)) }
        }
        return result
    }

    static func removingLink(in text: AttributedString, selection: AttributedTextSelection,
                             context: Font.Context) throws -> (text: AttributedString, selection: AttributedTextSelection, markdown: String) {
        var edited = text
        var updated = selection
        edited.transformAttributes(in: &updated) { attributes in
            attributes.link = nil
            attributes.foregroundColor = nil
            attributes.underlineStyle = nil
        }
        return (edited, updated, try RichDraftMarkdown.export(document(
            edited, context: context, typingAttributes: trailingTypingAttributes(in: edited, selection: updated))))
    }

    static func removingBlock(in text: AttributedString, selection: AttributedTextSelection,
                              context: Font.Context) throws -> (text: AttributedString, selection: AttributedTextSelection, markdown: String) {
        var edited = text
        var updated = selection
        var lines = selectedLineRanges(in: text, selection: selection)
        let allLines = selectedLineRanges(in: text, selection: .init(range: text.startIndex..<text.endIndex))
        // A fenced block is one control, including its language label, not a
        // collection of independent paragraphs that leave partial fences behind.
        if lines.contains(where: { isCodeBlock(AttributedString(text[$0]), context: context) }),
           let first = lines.first, let last = lines.last,
           var lower = allLines.firstIndex(of: first), var upper = allLines.firstIndex(of: last) {
            while lower > 0, isCodeBlock(AttributedString(text[allLines[lower - 1]]), context: context) { lower -= 1 }
            while upper + 1 < allLines.count, isCodeBlock(AttributedString(text[allLines[upper + 1]]), context: context) { upper += 1 }
            lines = Array(allLines[lower...upper])
        }
        let first = lines.first
        let last = lines.last
        let previousIsList: Bool = first.flatMap { allLines.firstIndex(of: $0) }.map { index in
            index > 0 && listMarker(in: AttributedString(text[allLines[index - 1]])) != nil
        } ?? false
        let followingIsList: Bool = last.flatMap { allLines.firstIndex(of: $0) }.map { index in
            index + 1 < allLines.count && listMarker(in: AttributedString(text[allLines[index + 1]])) != nil
        } ?? false
        edited.transform(updating: &updated) { value in
            for line in lines.reversed() {
                let original = AttributedString(value[line])
                let marker = listMarker(in: original)
                let content = droppingFirst(marker?.length ?? 0, from: original)
                var replacement = settingParagraphRole(content, heading: nil, context: context)
                if isCodeBlock(original, context: context) {
                    replacement.backgroundColor = nil
                    if presentation(for: original.runs.first?.font, context: context).role == .codeLanguage {
                        replacement = AttributedString()
                    }
                }
                if marker != nil, line == first, previousIsList {
                    var separated = piece("\n", role: .body)
                    separated.append(replacement)
                    replacement = separated
                }
                if marker != nil, line == last, followingIsList { replacement.append(piece("\n", role: .body)) }
                value.replaceSubrange(line, with: replacement)
            }
        }
        if case .insertionPoint(let point) = selection.indices(in: text), let first,
           let marker = listMarker(in: AttributedString(text[first])) {
            let offset = text.characters.distance(from: text.startIndex, to: first.lowerBound)
                + max(0, text.characters.distance(from: first.lowerBound, to: point) - marker.length)
                + (previousIsList ? 1 : 0)
            updated = .init(insertionPoint: edited.characters.index(edited.startIndex, offsetBy: offset),
                            typingAttributes: selection.typingAttributes(in: text))
        }
        if case .insertionPoint = updated.indices(in: edited) {
            edited.transformAttributes(in: &updated) { attributes in
                let style = presentation(for: attributes.font, context: context).style
                attributes.font = font(for: style, role: .body)
                attributes.foregroundColor = nil
                if !style.contains(.code) { attributes.backgroundColor = nil }
            }
        }
        return (edited, updated, try RichDraftMarkdown.export(document(
            edited, context: context, typingAttributes: trailingTypingAttributes(in: edited, selection: updated))))
    }

    // Shared by the bounded native typing transaction; no Markdown reparsing is needed.
    static func headingLevel(in text: AttributedString, context: Font.Context) -> Int? {
        presentation(for: text.runs.first?.font, context: context).role.headingLevel
    }

    static func headingLevel(for attributes: AttributeContainer, context: Font.Context) -> Int? {
        presentation(for: attributes.font, context: context).role.headingLevel
    }

    static func isCode(_ text: AttributedString, context: Font.Context) -> Bool {
        text.runs.contains {
            let value = presentation(for: $0.font, context: context)
            return value.style.contains(.code) || value.role == .codeBlock || value.role == .codeLanguage
        }
    }

    static func listMarker(in text: AttributedString) -> (length: Int, number: Int?)? {
        let line = VisualLine(text: text, separatorFont: nil)
        if let length = bulletPrefixLength(in: line) { return (length, nil) }
        if let prefix = orderedPrefix(in: line) { return (prefix.length, prefix.number) }
        return nil
    }

    static func listMarker(number: Int?) -> AttributedString {
        var marker = piece(number.map { "\($0). " } ?? "• ", role: .body)
        marker.foregroundColor = .secondary
        return marker
    }

    static func trailingTypingAttributes(
        in text: AttributedString, selection: AttributedTextSelection
    ) -> AttributeContainer? {
        guard case .insertionPoint(let index) = selection.indices(in: text), index == text.endIndex else { return nil }
        return selection.typingAttributes(in: text)
    }

    static func isCodeBlock(_ text: AttributedString, context: Font.Context) -> Bool {
        text.runs.contains {
            let role = presentation(for: $0.font, context: context).role
            return role == .codeBlock || role == .codeLanguage
        }
    }

    static func typingAttributes(heading: Int? = nil) -> AttributeContainer {
        var attributes = AttributeContainer()
        attributes.font = headingFont(heading)
        return attributes
    }

    static func settingParagraphRole(
        _ text: AttributedString, heading: Int?, context: Font.Context
    ) -> AttributedString {
        var result = text
        let role = presentation(for: headingFont(heading), context: context).role
        for run in text.runs {
            let style = presentation(for: run.font, context: context).style
            result[run.range].font = font(for: style, role: role)
        }
        return result
    }

    private static func headingFont(_ level: Int?) -> Font {
        switch level {
        case 1: .largeTitle
        case 2: .title
        case 3: .title2
        case 4: .title3
        case 5: .headline
        case 6: .subheadline
        default: .body
        }
    }

    private static func selectionHasCharacters(
        _ selection: AttributedTextSelection,
        in text: AttributedString
    ) -> Bool {
        guard case .ranges(let ranges) = selection.indices(in: text) else { return false }
        return ranges.ranges.contains { !$0.isEmpty }
    }

    private static func selectedLineRanges(
        in text: AttributedString,
        selection: AttributedTextSelection
    ) -> [Range<AttributedString.Index>] {
        let selected: [Range<AttributedString.Index>]
        switch selection.indices(in: text) {
        case .insertionPoint(let index):
            selected = [index..<index]
        case .ranges(let ranges):
            selected = Array(ranges.ranges)
        }

        var lines: [Range<AttributedString.Index>] = []
        var start = text.startIndex
        var cursor = start
        while cursor < text.endIndex {
            if text.characters[cursor] == "\n" {
                let after = text.characters.index(after: cursor)
                lines.append(start..<after)
                start = after
                cursor = after
            } else {
                cursor = text.characters.index(after: cursor)
            }
        }
        lines.append(start..<text.endIndex)

        let matches = lines.filter { line in
            selected.contains { range in
                if range.isEmpty {
                    // At EOF only the final logical line owns the caret. After
                    // a trailing newline the preceding line ends here too, but
                    // formatting it would insert an extra item and misplace the caret.
                    return line.contains(range.lowerBound)
                        || (range.lowerBound == text.endIndex && line.lowerBound == start)
                }
                return range.lowerBound < line.upperBound && line.lowerBound < range.upperBound
            }
        }
        return matches.isEmpty ? [text.endIndex..<text.endIndex] : matches
    }

    private static func append(_ block: RichDraftMarkdown.Block, to result: inout AttributedString) {
        switch block {
        case .paragraph(let spans):
            result.append(inline(spans, role: .body))
        case .heading(let level, let spans):
            let role: Role = switch level {
            case 1: .heading1
            case 2: .heading2
            case 3: .heading3
            case 4: .heading4
            case 5: .heading5
            default: .heading6
            }
            result.append(inline(spans, role: role))
        case .unorderedList(let items):
            for (index, item) in items.enumerated() {
                if index > 0 { result.append(piece("\n", role: .body)) }
                var marker = piece("• ", role: .body)
                marker.foregroundColor = .secondary
                result.append(marker)
                result.append(inline(item, role: .body))
            }
        case .orderedList(let start, let items):
            for (index, item) in items.enumerated() {
                if index > 0 { result.append(piece("\n", role: .body)) }
                var marker = piece("\(start + index). ", role: .body)
                marker.foregroundColor = .secondary
                result.append(marker)
                result.append(inline(item, role: .body))
            }
        case .code(let language, let text):
            if let language {
                var label = piece(language, role: .codeLanguage)
                label.foregroundColor = .secondary
                result.append(label)
                result.append(piece("\n", role: .codeBlock))
            }
            var code = piece(text, role: .codeBlock)
            code.backgroundColor = codeBackground
            result.append(code)
        }
    }

    private static func inline(_ spans: [RichDraftMarkdown.Span], role: Role) -> AttributedString {
        var result = AttributedString()
        for span in spans {
            var value = piece(span.text, role: role, style: span.style)
            if span.style.contains(.code) { value.backgroundColor = codeBackground }
            if let target = span.link, let url = URL(string: target) {
                value.link = url
                value.foregroundColor = .accentColor
                value.underlineStyle = .single
            }
            result.append(value)
        }
        return result
    }

    private static func piece(
        _ text: String,
        role: Role,
        style: RichDraftMarkdown.Style = []
    ) -> AttributedString {
        var result = AttributedString(text)
        result.font = font(for: style, role: role)
        return result
    }

    private static func font(for style: RichDraftMarkdown.Style, role: Role) -> Font {
        var result = role.baseFont
        if style.contains(.code) { result = result.monospaced() }
        if style.contains(.bold) { result = result.bold() }
        if style.contains(.italic) { result = result.italic() }
        return result
    }

    private static func presentation(for font: Font?, context: Font.Context) -> Presentation {
        guard let font else { return .init(role: .body, style: []) }
        for role in Role.allCases {
            let styles: [RichDraftMarkdown.Style] = role == .codeBlock || role == .codeLanguage
                ? [[]]
                : semanticStyles
            for style in styles where font == self.font(for: style, role: role) {
                return .init(role: role, style: style)
            }
        }
        let resolved = font.resolve(in: context)
        var style: RichDraftMarkdown.Style = []
        if resolved.isBold { style.insert(.bold) }
        if resolved.isItalic { style.insert(.italic) }
        if resolved.isMonospaced { style.insert(.code) }
        return .init(role: .body, style: style)
    }

    private static func visualLines(in text: AttributedString) -> [VisualLine] {
        var lines: [VisualLine] = []
        var start = text.startIndex
        var cursor = text.startIndex
        while cursor < text.endIndex {
            if text.characters[cursor] == "\n" {
                let after = text.characters.index(after: cursor)
                let separator = AttributedString(text[cursor..<after])
                lines.append(.init(
                    text: AttributedString(text[start..<cursor]),
                    separatorFont: separator.runs.first?.font,
                    emptyRoleFont: lines.last?.separatorFont == font(for: [], role: .codeBlock)
                        ? font(for: [], role: .codeBlock) : nil
                ))
                start = after
                cursor = after
            } else {
                cursor = text.characters.index(after: cursor)
            }
        }
        lines.append(.init(
            text: AttributedString(text[start..<text.endIndex]), separatorFont: nil,
            emptyRoleFont: lines.last?.separatorFont == font(for: [], role: .codeBlock)
                ? font(for: [], role: .codeBlock) : nil
        ))
        return lines
    }

    private static func role(of line: VisualLine, context: Font.Context) -> Role {
        if let run = line.text.runs.first {
            return presentation(for: run.font, context: context).role
        }
        return presentation(for: line.emptyRoleFont ?? line.separatorFont, context: context).role
    }

    private static func inlineSpans(
        in text: AttributedString,
        context: Font.Context
    ) -> [RichDraftMarkdown.Span] {
        var spans: [RichDraftMarkdown.Span] = []
        for run in text.runs {
            let presentation = presentation(for: run.font, context: context)
            let span = RichDraftMarkdown.Span(
                text: String(text[run.range].characters),
                style: presentation.style,
                link: run.link?.absoluteString
            )
            append(span, to: &spans)
        }
        return spans.isEmpty ? [.init(text: "")] : spans
    }

    private static func consumeCodeLines(
        _ lines: [VisualLine],
        from index: inout Int,
        context: Font.Context
    ) -> String {
        var result = ""
        while index < lines.count, role(of: lines[index], context: context) == .codeBlock {
            let line = lines[index]
            result += line.string
            if presentation(for: line.separatorFont, context: context).role == .codeBlock {
                result += "\n"
            }
            index += 1
        }
        return result
    }

    private static func bulletPrefixLength(in line: VisualLine) -> Int? {
        guard line.text.runs.first?.foregroundColor == .secondary else { return nil }
        return bulletPrefixLength(in: line.string)
    }

    private static func orderedPrefix(in line: VisualLine) -> (number: Int, length: Int)? {
        guard line.text.runs.first?.foregroundColor == .secondary else { return nil }
        return orderedPrefix(in: line.string)
    }

    private static func bulletPrefixLength(in value: String) -> Int? {
        guard value.count >= 2, let first = value.first,
              first == "•" || first == "-" || first == "+" || first == "*",
              value.dropFirst().first == " " else { return nil }
        return 2
    }

    private static func orderedPrefix(in value: String) -> (number: Int, length: Int)? {
        let digits = value.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty, digits.count <= 9, let number = Int(digits), number > 0 else { return nil }
        let remainder = value.dropFirst(digits.count)
        guard let punctuation = remainder.first, punctuation == "." || punctuation == ")",
              remainder.dropFirst().first == " " else { return nil }
        return (number, digits.count + 2)
    }

    private static func droppingFirst(_ count: Int, from text: AttributedString) -> AttributedString {
        guard count > 0 else { return text }
        guard text.characters.count >= count else { return AttributedString() }
        let start = text.characters.index(text.startIndex, offsetBy: count)
        return AttributedString(text[start..<text.endIndex])
    }

    private static func append(_ span: RichDraftMarkdown.Span, to spans: inout [RichDraftMarkdown.Span]) {
        if spans.last?.style == span.style, spans.last?.link == span.link {
            spans[spans.count - 1].text += span.text
        } else {
            spans.append(span)
        }
    }
}
