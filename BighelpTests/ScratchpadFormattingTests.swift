import SwiftUI
import Testing
@testable import Bighelp

@MainActor
struct ScratchpadFormattingTests {
    @Test func blockControlsCreateRealMarkdownStructures() throws {
        if #available(iOS 26.0, *) {
            let context = EnvironmentValues().fontResolutionContext
            let source = RichDraftMarkdown.Document(blocks: [.paragraph(spans: [.init(text: "First\nSecond")])])
            let text = RichDraftFormatting.attributed(source)
            let selection = AttributedTextSelection(range: text.startIndex..<text.endIndex)
            let bullets = try RichDraftFormatting.applyingBlock(.unorderedList, in: text, selection: selection, context: context)
            #expect(bullets.markdown.contains("- First"))
            #expect(bullets.markdown.contains("- Second"))
            let numbers = try RichDraftFormatting.applyingBlock(.orderedList, in: text, selection: selection, context: context)
            #expect(numbers.markdown.contains("1. First"))
            #expect(numbers.markdown.contains("2. Second"))
            let code = try RichDraftFormatting.applyingBlock(.codeBlock, in: text, selection: selection, context: context)
            #expect(code.markdown.contains("```"))
            #expect(code.markdown.contains("First\nSecond"))
            let heading = try RichDraftFormatting.applyingBlock(.heading(2), in: text, selection: selection, context: context)
            #expect(heading.markdown.contains("## First"))
            for result in [bullets, numbers, code, heading] {
                guard case .rich(let reparsed) = RichDraftMarkdown.importSource(result.markdown) else {
                    Issue.record("Formatting must remain losslessly representable"); continue
                }
                #expect(RichDraftFormatting.losslessAttributed(reparsed, context: context) != nil)
            }
        }
    }

    @Test func inlineExportPreservesLineEdgesWithoutEscapingGroupEdges() throws {
        let document = RichDraftMarkdown.Document(spans: [
            .init(text: " \tBefore "),
            .init(text: "Link", link: "https://example.com/reference"),
            .init(text: " "),
            .init(text: "code", style: .code),
            .init(text: " after \t\n \tNext "),
            .init(text: "link", link: "https://example.com/reference"),
            .init(text: " \t")
        ])
        let markdown = try RichDraftMarkdown.export(document)
        #expect(markdown == "&#32;&#9;Before [Link](<https://example.com/reference>) `code` after&#32;&#9;\n&#32;&#9;Next [link](<https://example.com/reference>)&#32;&#9;")
        guard case .rich(let reparsed) = RichDraftMarkdown.importSource(markdown) else {
            Issue.record("Boundary whitespace must remain representable"); return
        }
        #expect(RichDraftMarkdown.equivalent(document, reparsed))
    }

    @Test func emphasisKeepsInteriorWhitespaceInsideOneDelimiterPair() throws {
        let document = RichDraftMarkdown.Document(spans: [
            .init(text: "Before "),
            .init(text: "Ordinary paste", style: .bold)
        ])
        #expect(try RichDraftMarkdown.export(document) == "Before **Ordinary paste**")
        let mixed = RichDraftMarkdown.Document(spans: [
            .init(text: "Bold", style: .bold),
            .init(text: " "),
            .init(text: "both words", style: [.bold, .italic]),
            .init(text: " after")
        ])
        #expect(try RichDraftMarkdown.export(mixed) == "**Bold *both words*** after")
    }

    @Test func linkAndInlineCodeApplyToSelectedTextWithoutDroppingSurroundings() throws {
        if #available(iOS 26.0, *) {
            let context = EnvironmentValues().fontResolutionContext
            let source = RichDraftMarkdown.Document(blocks: [.paragraph(spans: [.init(text: "Before Link after")])])
            let text = RichDraftFormatting.attributed(source)
            let start = text.characters.index(text.startIndex, offsetBy: 7)
            let end = text.characters.index(start, offsetBy: 4)
            let selection = AttributedTextSelection(range: start..<end)
            let linked = try RichDraftFormatting.applyingLink(URL(string: "https://example.com/reference")!, in: text, selection: selection, context: context)
            #expect(linked.markdown == "Before [Link](<https://example.com/reference>) after")
            let code = try RichDraftFormatting.toggling(.code, in: text, selection: selection, context: context)
            #expect(code.markdown == "Before `Link` after")
        }
    }
}
