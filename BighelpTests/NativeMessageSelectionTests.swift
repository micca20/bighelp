import Foundation
import Testing
import UIKit
import SwiftUI
@testable import Bighelp

@MainActor
struct NativeMessageSelectionTests {
    @Test(arguments: [TimelineRole.human, .assistant])
    func everyMessageRoleUsesTheInlineNativeSelectionSurface(role: TimelineRole) {
        #expect(ChatMessageInteractionPolicy.usesInlineNativeSelection(role: role, uiV3Enabled: true))
    }

    @Test(arguments: [TimelineRole.human, .assistant])
    func everyMessageRoleCanOfferReactions(role: TimelineRole) {
        let presentation = NativeMessageReactionPresentation(
            rowID: 42,
            reactions: [],
            availability: .available,
            isUpdating: false,
            errorMessage: nil
        )

        let canReact = ChatMessageInteractionPolicy.canReact(
            role: role,
            presentation: presentation,
            hasMutationHandler: true
        )
        #expect(canReact)
        #expect(
            ChatBubbleInteraction(
                markdown: "React to this message",
                canFork: true,
                canReact: canReact
            ).menuActions == [.react, .copy, .selectText, .forkFromHere]
        )
    }

    @Test func nativeProseUsesSystemFontByDefault() throws {
        let rendered = ChatNativeMarkdownAttributedBuilder.build(document: MarkdownDocument("Hello"), style: style())
        let actual = try #require(rendered.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        #expect(actual.fontName == BighelpTheme.light.uiFont(.body).fontName)
    }

    private func style(_ category: UIContentSizeCategory = .large) -> ChatNativeMarkdownStyle {
        .init(primaryText: .label, secondaryText: .secondaryLabel, accent: .systemBlue,
              codeBackground: .secondarySystemBackground, proseLineSpacing: 5,
              traitCollection: UITraitCollection(preferredContentSizeCategory: category))
    }

    @Test func unchangedMarkdownReusesAttributedRenderingAndInvalidatesForTextAndStyle() {
        let cache = ChatNativeMarkdownRenderCache()
        let document = MarkdownDocument("**One** and [link](https://example.com)")
        let first = cache.render(document: document, style: style())
        for _ in 0..<100 {
            #expect(cache.render(document: document, style: style()) === first)
        }
        let changed = cache.render(document: MarkdownDocument("**Two**"), style: style())
        #expect(changed !== first)
        #expect(changed.string == "Two")
        let large = cache.render(document: MarkdownDocument("**Two**"), style: style(.accessibilityExtraExtraExtraLarge))
        #expect(large !== changed)
        let largeFont = large.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        let normalFont = changed.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        #expect((largeFont?.pointSize ?? 0) > (normalFont?.pointSize ?? 0))
    }

    @Test func recreatedSwiftUIColorsReuseUnchangedNativeRendering() {
        let cache = ChatNativeMarkdownRenderCache()
        let document = MarkdownDocument("**Same** message across tool updates")
        func recreatedStyle() -> ChatNativeMarkdownStyle {
            .init(primaryText: UIColor(Color(red: 0.8, green: 0.7, blue: 0.6)),
                  secondaryText: UIColor(Color.secondary), accent: UIColor(Color.blue),
                  codeBackground: UIColor(Color.black.opacity(0.1)), proseLineSpacing: 5,
                  traitCollection: UITraitCollection(traitsFrom: [
                    .init(userInterfaceStyle: .dark), .init(preferredContentSizeCategory: .large)]))
        }
        let first = cache.render(document: document, style: recreatedStyle())
        #expect(cache.render(document: document, style: recreatedStyle()) === first,
                "Equivalent SwiftUI color bridges must not rebuild unchanged message text")
    }

    @Test func unchangedSourceReusesParsingWithoutLosingByteDistinctEdits() {
        let cache = ChatMessageContentCache()
        let original = cache.project("**Caf\u{00e9}**")
        #expect(cache.project("**Caf\u{00e9}**") === original)
        let edited = cache.project("**Cafe\u{0301}**")
        #expect(edited !== original)
        #expect(Array(edited.references.source.utf8) == Array("**Cafe\u{0301}**".utf8))
        #expect(edited.document.visiblePlainText == "Cafe\u{0301}")
        let malformed = "Text\n```loopdy-references-v1\ninvalid"
        let failed = cache.project(malformed)
        #expect(failed.references.failure != nil)
        #expect(failed.references.prose == malformed)
        #expect(failed.references.references.isEmpty)
        #expect(cache.project(malformed) === failed)
        #expect(cache.project("**Caf\u{00e9}**") !== original,
                "Keep only the current source revision, not every past message value")
    }

    @Test func layoutTraitsDoNotInvalidateIdenticalRenderedText() {
        let cache = ChatNativeMarkdownRenderCache()
        let document = MarkdownDocument("**Stable** text while surrounding views change")
        func layoutStyle(_ scale: CGFloat) -> ChatNativeMarkdownStyle {
            .init(primaryText: .label, secondaryText: .secondaryLabel, accent: .systemBlue,
                  codeBackground: .secondarySystemBackground, proseLineSpacing: 5,
                  traitCollection: UITraitCollection(traitsFrom: [
                    .init(preferredContentSizeCategory: .large),
                    .init(userInterfaceStyle: .light), .init(displayScale: scale)]))
        }
        let first = cache.render(document: document, style: layoutStyle(2))
        #expect(cache.render(document: document, style: layoutStyle(3)) === first,
                "Layout-only traits cannot invalidate identical fonts and colors")
        let dark = ChatNativeMarkdownStyle(primaryText: .label, secondaryText: .secondaryLabel,
            accent: .systemBlue, codeBackground: .secondarySystemBackground, proseLineSpacing: 5,
            traitCollection: UITraitCollection(traitsFrom: [
                .init(preferredContentSizeCategory: .large), .init(userInterfaceStyle: .dark)]))
        #expect(cache.render(document: document, style: dark) !== first,
                "A real resolved color change must invalidate the rendered revision")
    }

    @Test func nativeMeasurementReusesSizesAndInvalidatesWithRenderedRevision() {
        let cache = ChatNativeMarkdownRenderCache()
        let document = MarkdownDocument("**A** message")
        _ = cache.render(document: document, style: style())
        var calls = 0
        func measure(_ width: CGFloat) -> CGSize {
            calls += 1
            return CGSize(width: width, height: CGFloat(calls))
        }
        let first = cache.measure(width: 300, using: measure)
        for _ in 0..<100 {
            #expect(cache.measure(width: 300, using: measure) == first)
        }
        #expect(calls == 1)
        _ = cache.measure(width: 200, using: measure)
        #expect(calls == 2)
        #expect(cache.measure(width: 300, using: measure) == first)
        _ = cache.render(document: document, style: style())
        #expect(cache.measure(width: 300, using: measure) == first)
        _ = cache.render(document: MarkdownDocument("Changed text"), style: style())
        #expect(cache.measure(width: 300, using: measure) != first)
        #expect(calls == 3)
        _ = cache.render(document: MarkdownDocument("Changed text"), style: style(.accessibilityExtraExtraExtraLarge))
        _ = cache.measure(width: 300, using: measure)
        #expect(calls == 4)
        for width in 301...310 { _ = cache.measure(width: CGFloat(width), using: measure) }
        let before = calls
        _ = cache.measure(width: 300, using: measure)
        #expect(calls == before + 1, "Old widths must be evicted from the bounded per-view cache")
    }

    @Test func formattedTextKeepsInlineTraitsAndExactLinks() throws {
        let result = ChatNativeMarkdownAttributedBuilder.build(
            document: MarkdownDocument("**Bold** and *italic* with `code` and [Apple](https://apple.com)."), style: style())
        #expect(result.string == "Bold and italic with code and Apple.")
        let text = result.string as NSString
        let bold = try #require(result.attribute(.font, at: text.range(of: "Bold").location, effectiveRange: nil) as? UIFont)
        let italic = try #require(result.attribute(.font, at: text.range(of: "italic").location, effectiveRange: nil) as? UIFont)
        let code = try #require(result.attribute(.font, at: text.range(of: "code").location, effectiveRange: nil) as? UIFont)
        #expect(bold.fontDescriptor.symbolicTraits.contains(.traitBold))
        #expect(italic.fontDescriptor.symbolicTraits.contains(.traitItalic))
        #expect(code.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
        #expect((result.attribute(.link, at: text.range(of: "Apple").location, effectiveRange: nil) as? URL)?.absoluteString == "https://apple.com")
    }

    @Test func blockTextAndDynamicTypeRemainReadable() throws {
        let document = MarkdownDocument("# Heading\n\nA paragraph.\n\n- First\n- Second\n\n> Quoted\n\n```swift\nlet x = 1\n```")
        let normal = ChatNativeMarkdownAttributedBuilder.build(document: document, style: style())
        let large = ChatNativeMarkdownAttributedBuilder.build(document: document, style: style(.accessibilityExtraExtraExtraLarge))
        #expect(normal.string == large.string)
        for text in ["Heading", "A paragraph.", "First", "Second", "Quoted", "let x = 1"] {
            #expect(normal.string.contains(text))
        }
        #expect(!normal.string.contains("```"))
        let normalFont = try #require(normal.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        let largeFont = try #require(large.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        #expect(largeFont.pointSize > normalFont.pointSize)
    }
}
