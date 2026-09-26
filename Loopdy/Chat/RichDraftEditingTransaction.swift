import SwiftUI

/// Only localized native typing gestures are interpreted. The proposed attributed value is
/// otherwise returned untouched: no whole-document parse/reprojection and no caret replay.
@available(iOS 26.0, *)
enum RichDraftEditingTransaction {
    struct State {
        // Prefix characters must belong to a local insertion, not pre-existing
        // imported/escaped literal Markdown. Paste and keyboard share this contract.
        var listShortcut: Range<Int>?
    }

    enum Kind: Equatable {
        case ordinary
        case startList
        case continueList
        case exitList
        case leaveHeading
    }

    struct Result {
        var text: AttributedString
        /// Nil means the native editor retains ownership of its selection.
        var selection: AttributedTextSelection?
        var kind: Kind
    }

    private struct Change {
        var start: Int
        var oldEnd: Int
        var newEnd: Int
    }

    static func apply(
        previous: AttributedString,
        proposed: AttributedString,
        selection: AttributedTextSelection,
        state: inout State,
        context: Font.Context
    ) -> Result {
        let unchanged = Result(text: proposed, selection: nil, kind: .ordinary)
        guard let change = change(previous: previous, proposed: proposed, selection: selection) else {
            // Attribute/selection echoes must not cancel a pending shortcut.
            return unchanged
        }
        if case .ranges(let ranges) = selection.indices(in: previous), ranges.ranges.count > 1 {
            state = State()
            return unchanged
        }
        guard change.oldEnd == change.start, change.newEnd - change.start > 1 else {
            return applySingle(previous: previous, proposed: proposed, selection: selection,
                               change: change, state: &state, context: context)
        }

        let fragment = slice(proposed, change.start..<change.newEnd)
        let characters = Array(fragment.characters)
        let source = String(fragment.characters)
        let old = Array(previous.characters)
        let lineStart = old[..<change.start].lastIndex(of: "\n").map { $0 + 1 } ?? 0
        let lineEnd = old[change.start...].firstIndex(of: "\n") ?? old.count
        let line = slice(previous, lineStart..<lineEnd)
        let inheritedHeading = RichDraftFormatting.headingLevel(in: line, context: context)
            ?? (line.characters.isEmpty ? RichDraftFormatting.headingLevel(
                for: selection.typingAttributes(in: previous), context: context) : nil)

        // onChange cannot distinguish paste from keyboard coalescing. Preserve an
        // explicitly rich fragment as supplied rather than interpreting its text as
        // keystrokes. Uniform inherited heading text can still Return to body.
        guard hasUniformProseAttributes(fragment, context: context),
              !RichDraftFormatting.isCode(fragment, context: context),
              !RichDraftFormatting.isCode(line, context: context),
              !fragment.runs.contains(where: { $0.link != nil }),
              RichDraftFormatting.headingLevel(in: fragment, context: context) == nil
                || RichDraftFormatting.headingLevel(in: fragment, context: context) == inheritedHeading,
              !source.contains("```"), !source.contains("~~~"),
              !source.unicodeScalars.contains(where: { $0.value == 13 }) else {
            state = State()
            return unchanged
        }

        // Interpret only the insertion, against one evolving attributed value. Never
        // publish intermediate snapshots; a budget overflow returns the entire native
        // proposal, not a partially formatted or truncated draft.
        var text = proposed
        text.replaceSubrange(range(change.start..<change.newEnd, in: text), with: AttributedString())
        var pending = state
        var offset = change.start
        var consumed = 0
        var steps = 0
        var work = 0
        var kind = Kind.ordinary
        var typing = selection.typingAttributes(in: previous)
        var overridesRole = false
        while consumed < characters.count {
            steps += 1
            work += text.characters.count + characters.count
            guard steps <= 256, work <= 2_000_000 else {
                state = State()
                return unchanged
            }
            let atLineStart = offset == 0 || text.characters[index(offset - 1, in: text)] == "\n"
            var end = consumed + 1
            // Only a short prefix needs character-sized steps. Ordinary content is
            // copied as one attributed span, even in a long line or Unicode draft.
            if characters[consumed] != "\n", !atLineStart,
               pending.listShortcut == nil {
                while end < characters.count, characters[end] != "\n" { end += 1 }
            }
            var piece = slice(fragment, consumed..<end)
            if overridesRole {
                piece = RichDraftFormatting.settingParagraphRole(piece, heading: nil, context: context)
            }
            var next = text
            let insertion = index(offset, in: next)
            next.replaceSubrange(insertion..<insertion, with: piece)
            let caret = AttributedTextSelection(insertionPoint: index(offset, in: text), typingAttributes: typing)
            let result = applySingle(
                previous: text, proposed: next, selection: caret,
                change: Change(start: offset, oldEnd: offset, newEnd: offset + end - consumed),
                continuationIsSupplied: characters[consumed] == "\n"
                    && suppliedListPrefix(in: characters[end...]),
                state: &pending, context: context)
            text = result.text
            if let updated = result.selection, case .insertionPoint(let caret) = updated.indices(in: text) {
                offset = text.characters.distance(from: text.startIndex, to: caret)
                typing = updated.typingAttributes(in: text)
            } else {
                offset += end - consumed
                typing = piece.runs.last?.attributes ?? typing
            }
            if result.kind != .ordinary {
                kind = result.kind
                overridesRole = true
            }
            consumed = end
        }
        state = pending
        guard kind != .ordinary else { return unchanged }
        return Result(text: text, selection: .init(insertionPoint: index(offset, in: text),
                                                   typingAttributes: typing), kind: kind)
    }

    private static func change(
        previous: AttributedString, proposed: AttributedString, selection: AttributedTextSelection
    ) -> Change? {
        let old = Array(previous.characters)
        let new = Array(proposed.characters)
        var start = 0
        while start < min(old.count, new.count), same(old[start], new[start]) { start += 1 }
        // Attribute/selection echoes must not cancel a shortcut that is still being typed.
        if start == old.count, start == new.count { return nil }
        var oldEnd = old.count
        var newEnd = new.count
        while oldEnd > start, newEnd > start, same(old[oldEnd - 1], new[newEnd - 1]) {
            oldEnd -= 1
            newEnd -= 1
        }
        // Common-prefix diff alone is ambiguous next to existing repeated text.
        // Prefer the native insertion point only when both untouched sides prove it.
        let added = new.count - old.count
        if added > 0,
           case .insertionPoint(let caret) = selection.indices(in: previous) {
            let offset = previous.characters.distance(from: previous.startIndex, to: caret)
            if offset <= old.count,
               exact(old[..<offset], new[..<offset]),
               exact(old[offset...], new[(offset + added)...]) {
                start = offset
                oldEnd = offset
                newEnd = offset + added
            }
        }
        return Change(start: start, oldEnd: oldEnd, newEnd: newEnd)
    }

    private static func applySingle(
        previous: AttributedString,
        proposed: AttributedString,
        selection: AttributedTextSelection,
        change: Change,
        continuationIsSupplied: Bool = false,
        state: inout State,
        context: Font.Context
    ) -> Result {
        let unchanged = Result(text: proposed, selection: nil, kind: .ordinary)
        let old = Array(previous.characters)
        let new = Array(proposed.characters)
        let start = change.start
        let oldEnd = change.oldEnd
        let newEnd = change.newEnd
        let listShortcut = state.listShortcut
        state.listShortcut = nil
        // Native selection can already refer to the proposed value when this
        // binding fires. Classify the localized text delta below rather than
        // requiring that newer selection to resolve in the previous buffer.
        let inserted = String(new[start..<newEnd])
        let removed = String(old[start..<oldEnd])
        let lineStart = (old[..<start].lastIndex(of: "\n").map { $0 + 1 }) ?? 0
        let lineEnd = old[start...].firstIndex(of: "\n") ?? old.count
        let line = slice(previous, lineStart..<lineEnd)
        let insertion = slice(proposed, start..<newEnd)
        var continuationAttributes = RichDraftFormatting.typingAttributes()
        continuationAttributes.font = RichDraftFormatting.font(for: RichDraftFormatting.style(
            for: selection.typingAttributes(in: previous).font, context: context))

        let canRecognizePrefix = lineEnd == start
            && !RichDraftFormatting.isCode(line, context: context)
            && !RichDraftFormatting.isCode(insertion, context: context)
            && !line.runs.contains(where: { $0.link != nil })
            && !insertion.runs.contains(where: { $0.link != nil })
            && RichDraftFormatting.headingLevel(in: line, context: context) == nil
            && RichDraftFormatting.headingLevel(in: insertion, context: context) == nil
        if removed.isEmpty, inserted.count == 1, inserted != " ", canRecognizePrefix,
           start == lineStart || listShortcut == lineStart..<start {
            let candidate = String(new[lineStart..<newEnd])
            let digits = candidate.prefix { $0.isASCII && $0.isNumber }
            let suffix = candidate.dropFirst(digits.count)
            let isNumberPrefix = !digits.isEmpty && digits.count <= 9 && digits.first != "0"
                && (suffix.isEmpty || suffix == "." || suffix == ")")
            if ["-", "*", "+", "•"].contains(candidate) || isNumberPrefix {
                state.listShortcut = lineStart..<newEnd
                return unchanged
            }
        }
        if removed.isEmpty, inserted == " ", canRecognizePrefix,
           listShortcut == lineStart..<start {
            let prefix = String(old[lineStart..<start])
            let isBullet = ["-", "*", "+", "•"].contains(prefix)
            let number = Int(prefix.dropLast())
            if isBullet || ((prefix.last == "." || prefix.last == ")") && (number ?? 0) > 0) {
                let marker = RichDraftFormatting.listMarker(number: isBullet ? nil : number)
                var text = proposed
                var caret = AttributedTextSelection(insertionPoint: index(start + 1, in: text))
                text.transform(updating: &caret) { value in
                    value.replaceSubrange(range(lineStart..<(start + 1), in: value), with: marker)
                }
                caret = .init(insertionPoint: index(lineStart + marker.characters.count, in: text),
                              typingAttributes: continuationAttributes)
                return Result(text: text, selection: caret, kind: .startList)
            }
        }

        // A body paragraph after a list needs a real blank separator in Markdown.
        let exitBreak = lineStart > 1 && old[lineStart - 2] != "\n" ? "\n" : ""

        // Deleting the final marker space on an otherwise empty list item exits it.
        if inserted.isEmpty, removed == " ", oldEnd == lineEnd,
           let marker = RichDraftFormatting.listMarker(in: line),
           lineEnd - lineStart == marker.length {
            var text = proposed
            var caret = AttributedTextSelection(insertionPoint: index(start, in: text))
            text.transform(updating: &caret) { value in
                var bodyBreak = AttributedString(exitBreak)
                bodyBreak.font = .body
                value.replaceSubrange(range(lineStart..<start, in: value), with: bodyBreak)
            }
            caret = .init(insertionPoint: index(lineStart + exitBreak.count, in: text),
                          typingAttributes: continuationAttributes)
            return Result(text: text, selection: caret, kind: .exitList)
        }

        guard inserted == "\n" else { return unchanged }
        if !removed.isEmpty {
            // Return may replace content, but never a marker or multiple items.
            guard let marker = RichDraftFormatting.listMarker(in: line),
                  start >= lineStart + marker.length, oldEnd <= lineEnd else { return unchanged }
        }
        // A Return within code or a linked run is literal content, not a block shortcut.
        let probe = start > lineStart ? slice(previous, (start - 1)..<start) : line
        guard !RichDraftFormatting.isCodeBlock(line, context: context),
              !RichDraftFormatting.isCodeBlock(insertion, context: context) else { return unchanged }
        if start < lineEnd,
           RichDraftFormatting.isCode(probe, context: context) || probe.runs.contains(where: { $0.link != nil }) {
            return unchanged
        }

        if let marker = RichDraftFormatting.listMarker(in: line), start >= lineStart + marker.length {
            var text = proposed
            var caret = AttributedTextSelection(insertionPoint: index(start + 1, in: text))
            if lineEnd - lineStart == marker.length {
                // Remove the empty item and its newly inserted Return, leaving one real
                // body line (the preceding item's newline is already in the buffer).
                text.transform(updating: &caret) { value in
                    var bodyBreak = AttributedString(exitBreak)
                    bodyBreak.font = .body
                    value.replaceSubrange(range(lineStart..<(start + 1), in: value), with: bodyBreak)
                }
                caret = .init(insertionPoint: index(lineStart + exitBreak.count, in: text),
                              typingAttributes: continuationAttributes)
                return Result(text: text, selection: caret, kind: .exitList)
            }
            guard marker.number != Int.max else { return unchanged }
            if continuationIsSupplied {
                // A plain or rich insertion may already contain its next marker.
                // Keep that content; do not synthesize a second prefix ahead of it.
                var newline = AttributedString("\n")
                newline.font = .body
                text.replaceSubrange(range(start..<(start + 1), in: text), with: newline)
                caret = .init(insertionPoint: index(start + 1, in: text),
                              typingAttributes: continuationAttributes)
                return Result(text: text, selection: caret, kind: .continueList)
            }
            let nextNumber = marker.number.map { $0 + 1 }
            let nextMarker = RichDraftFormatting.listMarker(number: nextNumber)
            let caretOffset = start + 1 + nextMarker.characters.count
            text.transform(updating: &caret) { value in
                // Only the affected contiguous ordered segment is renumbered. Work
                // backwards so suffix indices and all inline attributes remain valid.
                if let number = marker.number {
                    var following = lineEnd + 2 - (oldEnd - start) // Account for replaced content.
                    var expected = number + 1
                    var replacements: [(Range<Int>, Int)] = []
                    while following < new.count, expected < Int.max {
                        let end = new[following...].firstIndex(of: "\n") ?? new.count
                        let candidate = slice(proposed, following..<end)
                        guard let prefix = RichDraftFormatting.listMarker(in: candidate),
                              prefix.number == expected else { break }
                        replacements.append((following..<(following + prefix.length), expected + 1))
                        expected += 1
                        following = end + 1
                    }
                    for (target, number) in replacements.reversed() {
                        value.replaceSubrange(range(target, in: value),
                                              with: RichDraftFormatting.listMarker(number: number))
                    }
                }
                // The inserted newline and marker are body text, never a link or heading.
                var newline = AttributedString("\n")
                newline.font = .body
                value.replaceSubrange(range(start..<(start + 1), in: value), with: newline)
                let insertion = index(start + 1, in: value)
                value.replaceSubrange(insertion..<insertion, with: nextMarker)
            }
            caret = .init(insertionPoint: index(caretOffset, in: text),
                          typingAttributes: continuationAttributes)
            return Result(text: text, selection: caret, kind: .continueList)
        }

        // An empty heading has no characters from which to read its font role.
        let heading = RichDraftFormatting.headingLevel(in: line, context: context)
            ?? (line.characters.isEmpty ? RichDraftFormatting.headingLevel(
                for: selection.typingAttributes(in: previous), context: context) : nil)
        if heading != nil {
            var text = proposed
            var caret = AttributedTextSelection(insertionPoint: index(start + 1, in: text))
            text.transform(updating: &caret) { value in
                let suffixEnd = lineEnd + (lineEnd < old.count ? 2 : 1)
                let target = range((start + 1)..<suffixEnd, in: value)
                let suffix = RichDraftFormatting.settingParagraphRole(
                    AttributedString(value[target]), heading: nil, context: context)
                value.replaceSubrange(target, with: suffix)
                // Keep the heading's own role on its terminator, including an empty one.
                let newline = range(start..<(start + 1), in: value)
                value[newline].font = RichDraftFormatting.typingAttributes(heading: heading).font
                value[newline].link = nil
            }
            caret = .init(insertionPoint: index(start + 1, in: text),
                          typingAttributes: continuationAttributes)
            return Result(text: text, selection: caret, kind: .leaveHeading)
        }
        return unchanged
    }

    private static func hasUniformProseAttributes(_ text: AttributedString, context: Font.Context) -> Bool {
        guard let first = text.runs.first else { return false }
        let heading = RichDraftFormatting.headingLevel(for: first.attributes, context: context)
        var expected = first.attributes
        // Native default-font and explicit-body runs are semantically identical.
        // Do not mistake that boundary for explicitly mixed pasted formatting.
        expected.font = RichDraftFormatting.font(for: RichDraftFormatting.style(for: first.font, context: context))
        return text.runs.allSatisfy { run in
            guard RichDraftFormatting.headingLevel(for: run.attributes, context: context) == heading else { return false }
            var attributes = run.attributes
            attributes.font = RichDraftFormatting.font(for: RichDraftFormatting.style(for: run.font, context: context))
            return attributes == expected
        }
    }

    private static func suppliedListPrefix(in characters: ArraySlice<Character>) -> Bool {
        let prefix = String(characters.prefix(12))
        if ["- ", "* ", "+ ", "• "].contains(where: { prefix.hasPrefix($0) }) { return true }
        let digits = prefix.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9, digits.first != "0" else { return false }
        let suffix = prefix.dropFirst(digits.count)
        return suffix.hasPrefix(". ") || suffix.hasPrefix(") ")
    }

    private static func exact(_ lhs: ArraySlice<Character>, _ rhs: ArraySlice<Character>) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { same($0.0, $0.1) }
    }

    private static func same(_ lhs: Character, _ rhs: Character) -> Bool {
        String(lhs).utf8.elementsEqual(String(rhs).utf8)
    }

    private static func index(_ offset: Int, in text: AttributedString) -> AttributedString.Index {
        text.characters.index(text.startIndex, offsetBy: offset)
    }

    private static func range(_ offsets: Range<Int>, in text: AttributedString) -> Range<AttributedString.Index> {
        index(offsets.lowerBound, in: text)..<index(offsets.upperBound, in: text)
    }

    private static func slice(_ text: AttributedString, _ offsets: Range<Int>) -> AttributedString {
        AttributedString(text[range(offsets, in: text)])
    }
}
