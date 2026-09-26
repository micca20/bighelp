import Foundation
import SwiftUI
import UIKit
import Testing
@testable import Bighelp

@MainActor
struct RichDraftEditorTests {
    @Test func nativeDraftUsesSystemDefaultWithoutChangingMarkdown() throws {
        guard #available(iOS 26.0, *) else { return }
        let context = EnvironmentValues().fontResolutionContext
        let font = RichDraftFormatting.nativeFont(for: .body, context: context)
        #expect(font.fontName == BighelpTheme.light.uiFont(.body).fontName)
        guard case .rich(let document) = RichDraftMarkdown.importSource("Hello **world** and `code`.") else {
            Issue.record("Expected supported Markdown"); return
        }
        let styled = RichDraftFormatting.attributed(document)
        let native = RichDraftNativeTextView.nativeAttributed(styled, context: context)
        let roundTrip = RichDraftNativeTextView.swiftAttributed(native, context: context)
        #expect(try RichDraftMarkdown.export(RichDraftFormatting.document(roundTrip, context: context)) == "Hello **world** and `code`.")
    }

    @Test(arguments: [false, true])
    func nativeFocusRequestBeforeWindowAttachmentKeepsCaret(rich: Bool) throws {
        guard #available(iOS 26.0, *) else { return }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.windowLevel = .alert + 1
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer {
            window.endEditing(true)
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        let owner = RichDraftFocusOwner()
        let view: UITextView = rich ? RichDraftUIKitTextView() : ClipboardPasteTextView()
        view.frame = window.bounds
        view.text = "Hello world"
        view.selectedRange = NSRange(location: 6, length: 0)
        owner.attach(view)
        owner.requestFocus()
        #expect(!view.isFirstResponder)
        window.rootViewController?.view.addSubview(view)
        #expect(view.isFirstResponder)
        #expect(view.selectedRange == NSRange(location: 6, length: 0))
        view.insertText("native ")
        #expect(view.text == "Hello native world")
    }

    @Test(arguments: [false, true])
    func replacementFocusIgnoresOutgoingEndAndDismantle(toRich: Bool) throws {
        guard #available(iOS 26.0, *) else { return }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.windowLevel = .alert + 1
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer {
            window.endEditing(true)
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        let owner = RichDraftFocusOwner()
        let outgoing: UITextView = toRich ? ClipboardPasteTextView() : RichDraftUIKitTextView()
        outgoing.frame = window.bounds
        owner.attach(outgoing)
        window.rootViewController?.view.addSubview(outgoing)
        owner.requestFocus()
        #expect(outgoing.isFirstResponder)
        owner.prepareForReplacement()
        #expect(!owner.didEndEditing(outgoing))
        let incoming: UITextView = toRich ? RichDraftUIKitTextView() : ClipboardPasteTextView()
        incoming.frame = window.bounds
        incoming.text = "source"
        incoming.selectedRange = NSRange(location: 3, length: 0)
        owner.attach(incoming)
        window.rootViewController?.view.addSubview(incoming)
        owner.detach(outgoing)
        #expect(!owner.didEndEditing(outgoing))
        #expect(incoming.isFirstResponder)
        #expect(incoming.selectedRange == NSRange(location: 3, length: 0))
        incoming.insertText("!")
        #expect(incoming.text == "sou!rce")
    }

    @Test(arguments: [false, true])
    func formattingFocusRequestPreservesNativeSelectionAndTypingTraits(rich: Bool) throws {
        guard #available(iOS 26.0, *) else { return }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.windowLevel = .alert + 1
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer {
            window.endEditing(true)
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        let owner = RichDraftFocusOwner()
        let view: UITextView = rich ? RichDraftUIKitTextView() : ClipboardPasteTextView()
        view.frame = window.bounds
        view.text = "Hello world"
        owner.attach(view)
        window.rootViewController?.view.addSubview(view)
        owner.requestFocus()
        #expect(view.isFirstResponder)
        view.resignFirstResponder()
        #expect(owner.didEndEditing(view))
        // A toolbar action resumes this native owner without retapping the text.
        view.selectedRange = NSRange(location: 6, length: 0)
        view.typingAttributes = [.font: UIFont.boldSystemFont(ofSize: 17)]
        owner.requestFocus()
        #expect(view.isFirstResponder)
        #expect(view.selectedRange == NSRange(location: 6, length: 0))
        view.insertText("bold ")
        #expect(view.text == "Hello bold world")
        let font = view.textStorage.attribute(.font, at: 6, effectiveRange: nil) as? UIFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
        owner.detach(view)
        view.removeFromSuperview()
        window.rootViewController?.view.addSubview(view)
        #expect(!view.isFirstResponder, "Dismantled views must not replay a focus request")
    }

    @Test(arguments: [
        ("- first", "- first\n- "),
        ("+ first", "+ first\n+ "),
        ("* first", "* first\n* "),
        ("9. first", "9. first\n10. "),
        ("- 👩🏽‍💻 Cafe\u{301}", "- 👩🏽‍💻 Cafe\u{301}\n- "),
        ("- first\n- ", "- first\n\n"),
        ("9. first\n10. ", "9. first\n\n"),
        ("ordinary text", "ordinary text\n")
    ])
    func sourceReturnContinuesOrExitsList(example: (String, String)) {
        var source = example.0
        var selection = NSRange(location: (source as NSString).length, length: 0)
        let editor = MarkdownSourceTextView(
            text: Binding(get: { source }, set: { source = $0 }),
            selection: Binding(get: { selection }, set: { selection = $0 }),
            accessibilityIdentifier: "test.editor",
            accessibilityLabel: "Test editor"
        )
        let coordinator = editor.makeCoordinator()
        let view = UITextView()
        view.text = source
        view.selectedRange = selection
        view.delegate = coordinator

        // Match UIKit's edit contract: a delegate may handle Return itself.
        let range = view.selectedRange
        let allowsDefault = view.delegate?.textView?(view, shouldChangeTextIn: range, replacementText: "\n") ?? true
        if allowsDefault {
            view.text = (view.text as NSString).replacingCharacters(in: range, with: "\n")
            view.selectedRange = NSRange(location: range.location + 1, length: 0)
            coordinator.textViewDidChange(view)
        }

        #expect(view.text == example.1)
        #expect(source == example.1)
        #expect(view.selectedRange == NSRange(location: (example.1 as NSString).length, length: 0))
        #expect(selection == view.selectedRange)
    }

    @Test(arguments: [RichDraftCommand.bold, .italic, .inlineCode])
    func sourceInlineFormattingTogglesOffForSelectedText(command: RichDraftCommand) {
        let source = "👩🏽‍💻 Cafe\u{301}"
        let originalSelection = NSRange(location: 0, length: (source as NSString).length)
        let enabled = MarkdownSourceFormatter.apply(command, to: source, selection: originalSelection)
        let disabled = MarkdownSourceFormatter.apply(command, to: enabled.source, selection: enabled.selection)
        #expect(disabled.source == source)
        #expect(disabled.selection == originalSelection)
    }

    @Test(arguments: [RichDraftCommand.bold, .italic, .inlineCode])
    func sourceActiveStyleTracksCaretAndToggle(command: RichDraftCommand) {
        let enabled = MarkdownSourceFormatter.apply(command, to: "Hello", selection: NSRange(location: 0, length: 5))
        let caret = NSRange(location: NSMaxRange(enabled.selection), length: 0)
        #expect(MarkdownSourceFormatter.activeCommands(in: enabled.source, selection: caret).contains(command))
        let disabled = MarkdownSourceFormatter.apply(command, to: enabled.source, selection: caret)
        #expect(disabled.source == "Hello")
        #expect(disabled.selection == NSRange(location: 5, length: 0))
        #expect(!MarkdownSourceFormatter.activeCommands(in: disabled.source, selection: disabled.selection).contains(command))
    }

    @Test(arguments: ["- first\n- ", "9. first\n10. "])
    func sourceListExitThenProseIsASeparateParagraph(source: String) throws {
        let result = try #require(MarkdownSourceFormatter.returning(in: source,
            selection: NSRange(location: source.utf16.count, length: 0)))
        let prose = (result.source as NSString).replacingCharacters(in: result.selection, with: "body")
        #expect(prose == source.components(separatedBy: "\n")[0] + "\n\nbody")
        #expect(!MarkdownSourceFormatter.activeCommands(in: prose,
            selection: NSRange(location: prose.utf16.count, length: 0)).contains(.unorderedList))
    }

    @Test(arguments: ["- a\n- \n- c", "1. a\n2. \n3. c", "- 👩🏽‍💻\n- \n- c"])
    func sourceReturnExitsEmptyMiddleItemWithOneBlankSeparator(source: String) throws {
        let lines = source.components(separatedBy: "\n")
        let start = lines[0].utf16.count + 1
        let result = try #require(MarkdownSourceFormatter.returning(in: source,
            selection: NSRange(location: start + lines[1].utf16.count, length: 0)))
        #expect(result.source == lines[0] + "\n\n" + lines[2])
        #expect(result.selection == NSRange(location: start, length: 0))
        #expect((result.source as NSString).replacingCharacters(in: result.selection, with: "body")
            == lines[0] + "\nbody\n" + lines[2])
    }

    @Test(arguments: [NSRange(location: 1, length: 2), NSRange(location: 3, length: 5)])
    func sourceReturnDoesNotRewriteSelectionAcrossMarkersOrItems(selection: NSRange) {
        #expect(MarkdownSourceFormatter.returning(in: "- abc\n- def", selection: selection) == nil)
    }

    @Test func sourceReturnSplitsItemButNotFencedCode() {
        let split = MarkdownSourceFormatter.returning(in: "- first second", selection: NSRange(location: 7, length: 0))
        #expect(split?.source == "- first\n-  second")
        #expect(split?.selection == NSRange(location: 10, length: 0))
        for fence in ["```", "~~~"] {
            let source = fence + "\n- literal\n" + fence
            #expect(MarkdownSourceFormatter.returning(in: source, selection: NSRange(location: 13, length: 0)) == nil)
        }
    }

    @Test(arguments: [RichDraftCommand.unorderedList, .orderedList, .heading(2), .codeBlock])
    func sourceBlockControlsToggleAndReportActive(command: RichDraftCommand) {
        let enabled = MarkdownSourceFormatter.apply(command, to: "Hello", selection: NSRange(location: 0, length: 5))
        #expect(MarkdownSourceFormatter.activeCommands(in: enabled.source, selection: enabled.selection).contains(command))
        let disabled = MarkdownSourceFormatter.apply(command, to: enabled.source, selection: enabled.selection)
        #expect(disabled.source == "Hello")
        #expect(!MarkdownSourceFormatter.activeCommands(in: disabled.source, selection: disabled.selection).contains(command))
    }

    @Test func emptySourceListStartsWithCaretAfterMarker() {
        let result = MarkdownSourceFormatter.apply(.unorderedList, to: "", selection: NSRange(location: 0, length: 0))
        #expect(result.source == "- ")
        #expect(result.selection == NSRange(location: 2, length: 0))
        #expect(MarkdownSourceFormatter.activeCommands(in: result.source, selection: result.selection).contains(.unorderedList))
    }

    @Test(arguments: ["", "\n", "\n\n", "Intro\n", "🐈\n"])
    func startingBulletAtTerminalEmptyLineCreatesOneTypingPosition(source: String) throws {
        if #available(iOS 26.0, *) {
            let context = EnvironmentValues().fontResolutionContext
            let text = AttributedString(source)
            let result = try RichDraftFormatting.applyingBlock(.unorderedList, in: text,
                selection: .init(insertionPoint: text.endIndex), context: context)
            #expect(String(result.text.characters) == source + "• ")
            if case .insertionPoint(let caret) = result.selection.indices(in: result.text) {
                #expect(caret == result.text.endIndex)
            } else { Issue.record("Expected caret after the only new bullet") }
        }
    }

    @Test func richListStartsEmptyAndContinuesWithoutLosingAnyItem() throws {
        if #available(iOS 26.0, *) {
            let context = EnvironmentValues().fontResolutionContext
            let empty = AttributedString()
            let started = try RichDraftFormatting.applyingBlock(.unorderedList, in: empty,
                selection: .init(insertionPoint: empty.startIndex), context: context)
            #expect(started.markdown == "- ")
            var text = started.text
            var selection = started.selection
            if case .insertionPoint(let caret) = selection.indices(in: text) {
                #expect(caret == text.endIndex)
            } else { Issue.record("Starting a list must leave an insertion point") }
            var state = RichDraftEditingTransaction.State()
            for input in ["First", "\n", "Second", "\n", "Third"] {
                var proposed = text
                let typing = selection.typingAttributes(in: text)
                var fragment = AttributedString(input)
                fragment.setAttributes(typing)
                proposed.append(fragment)
                let nextSelection = AttributedTextSelection(insertionPoint: proposed.endIndex, typingAttributes: typing)
                let transaction = RichDraftEditingTransaction.apply(previous: text, proposed: proposed,
                    selection: selection, state: &state, context: context)
                text = transaction.text
                selection = transaction.selection ?? nextSelection
                #expect(RichDraftFormatting.activeCommands(in: text, selection: selection, context: context).contains(.unorderedList))
            }
            let document = RichDraftFormatting.document(text, context: context,
                typingAttributes: RichDraftFormatting.trailingTypingAttributes(in: text, selection: selection))
            #expect(try RichDraftMarkdown.export(document) == "- First\n- Second\n- Third")
            let native = RichDraftNativeTextView.nativeAttributed(text, context: context)
            let roundTrip = RichDraftNativeTextView.swiftAttributed(native, context: context)
            #expect(RichDraftMarkdown.equivalent(document, RichDraftFormatting.document(roundTrip, context: context)))
        }
    }

    @Test(arguments: [
        ("- BeforeX**After**\n- **Keep**", "X", "- Before\n- **After**\n- **Keep**"),
        ("8. Before👩🏽‍💻X**After**\n9. **Keep**\n10. Last", "👩🏽‍💻X",
         "8. Before\n9. **After**\n10. **Keep**\n11. Last")
    ])
    func richReturnReplacesSelectedListContent(example: (String, String, String)) throws {
        if #available(iOS 26.0, *) {
            guard case .rich(let document) = RichDraftMarkdown.importSource(example.0) else {
                Issue.record("Expected supported list"); return
            }
            let context = EnvironmentValues().fontResolutionContext
            let text = RichDraftFormatting.attributed(document)
            let plain = String(text.characters)
            let match = try #require(plain.range(of: example.1))
            let offset = plain.distance(from: plain.startIndex, to: match.lowerBound)
            let start = text.characters.index(text.startIndex, offsetBy: offset)
            let end = text.characters.index(start, offsetBy: example.1.count)
            var proposed = text
            var newline = AttributedString("\n")
            newline.font = .body
            proposed.replaceSubrange(start..<end, with: newline)
            var state = RichDraftEditingTransaction.State()
            let result = RichDraftEditingTransaction.apply(previous: text, proposed: proposed,
                selection: .init(range: start..<end), state: &state, context: context)
            #expect(result.kind == .continueList)
            #expect(try RichDraftMarkdown.export(RichDraftFormatting.document(result.text, context: context)) == example.2)
            let selection = try #require(result.selection)
            guard case .insertionPoint(let caret) = selection.indices(in: result.text) else {
                Issue.record("Return must collapse the selection after the new marker"); return
            }
            #expect(String(result.text[caret...].characters).hasPrefix("After\n"))
            var typed = result.text
            typed.replaceSubrange(caret..<caret, with: AttributedString("typed"))
            #expect(String(typed.characters).contains("typedAfter\n"))
        }
    }

    @Test(arguments: [1..<4, 3..<9])
    func richReturnDoesNotRewriteSelectionAcrossMarkersOrItems(offsets: Range<Int>) throws {
        if #available(iOS 26.0, *) {
            guard case .rich(let document) = RichDraftMarkdown.importSource("- abc\n- **def**") else {
                Issue.record("Expected supported list"); return
            }
            let text = RichDraftFormatting.attributed(document)
            let start = text.characters.index(text.startIndex, offsetBy: offsets.lowerBound)
            let end = text.characters.index(text.startIndex, offsetBy: offsets.upperBound)
            var proposed = text
            proposed.replaceSubrange(start..<end, with: AttributedString("\n"))
            var state = RichDraftEditingTransaction.State()
            let result = RichDraftEditingTransaction.apply(previous: text, proposed: proposed,
                selection: .init(range: start..<end), state: &state,
                context: EnvironmentValues().fontResolutionContext)
            #expect(result.kind == .ordinary)
            #expect(result.text == proposed)
            #expect(result.selection == nil)
        }
    }

    @Test(arguments: ["- First\n- ", "1. First\n2. "])
    func richReturnExitsAnEmptyListAndPreservesBodySeparation(source: String) throws {
        if #available(iOS 26.0, *) {
            guard case .rich(let document) = RichDraftMarkdown.importSource(source) else {
                Issue.record("Empty list items must remain editable"); return
            }
            let context = EnvironmentValues().fontResolutionContext
            let text = RichDraftFormatting.attributed(document)
            var proposed = text
            var newline = AttributedString("\n")
            newline.font = .body
            proposed.append(newline)
            var state = RichDraftEditingTransaction.State()
            let result = RichDraftEditingTransaction.apply(previous: text, proposed: proposed,
                selection: .init(insertionPoint: text.endIndex), state: &state, context: context)
            #expect(result.kind == .exitList)
            #expect(String(result.text.characters).hasSuffix("\n\n"))
            if let selection = result.selection {
                #expect(!RichDraftFormatting.activeCommands(in: result.text, selection: selection, context: context).contains(.unorderedList))
                #expect(!RichDraftFormatting.activeCommands(in: result.text, selection: selection, context: context).contains(.orderedList))
            }
            #expect(try RichDraftMarkdown.export(RichDraftFormatting.document(result.text, context: context)).hasSuffix("\n\n"))
        }
    }

    @Test func richCaretFormattingRemainsSelectedUntilToggledOff() throws {
        if #available(iOS 26.0, *) {
            let context = EnvironmentValues().fontResolutionContext
            let empty = AttributedString()
            let enabled = try RichDraftFormatting.toggling(.bold, in: empty,
                selection: .init(insertionPoint: empty.startIndex), context: context)
            #expect(RichDraftFormatting.activeCommands(in: enabled.text, selection: enabled.selection, context: context).contains(.bold))
            var text = enabled.text
            var selection = enabled.selection
            var fragment = AttributedString("Hello")
            fragment.setAttributes(selection.typingAttributes(in: text))
            text.append(fragment)
            selection = .init(insertionPoint: text.endIndex, typingAttributes: enabled.selection.typingAttributes(in: enabled.text))
            #expect(RichDraftFormatting.activeCommands(in: text, selection: selection, context: context).contains(.bold))
            let disabled = try RichDraftFormatting.toggling(.bold, in: text, selection: selection, context: context)
            #expect(!RichDraftFormatting.activeCommands(in: disabled.text, selection: disabled.selection, context: context).contains(.bold))
            #expect(disabled.markdown == "**Hello**")
        }
    }

    @Test(arguments: ["strikethrough", "attachment", "paragraph", "color", "background", "underline", "unknown"])
    func unsupportedNativePasteIsRejectedBeforeMutation(kind: String) throws {
        if #available(iOS 26.0, *) {
            let context = EnvironmentValues().fontResolutionContext
            let original = AttributedString("Keep this")
            var warning: String?
            var edits = 0
            let bridge = RichDraftNativeTextView(text: original,
                selection: .init(insertionPoint: original.endIndex), contentRevision: 0,
                fontContext: context, accessibilityIdentifier: "test.editor", accessibilityLabel: "Test",
                focus: FocusState<Bool>().projectedValue,
                onEdit: { _, _, _ in edits += 1 }, onSelectionChange: { _ in },
                onPasteRejected: { warning = $0 })
            let coordinator = bridge.makeCoordinator()
            let view = RichDraftUIKitTextView()
            coordinator.view = view
            coordinator.install(original, selection: .init(range: original.startIndex..<original.endIndex), in: view)
            let before = NSAttributedString(attributedString: view.textStorage)
            let caret = view.selectedRange
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any]
            switch kind {
            case "strikethrough": attributes = [.strikethroughStyle: NSUnderlineStyle.single.rawValue]
            case "attachment": attributes = [.attachment: NSTextAttachment()]
            case "paragraph": attributes = [.paragraphStyle: paragraph]
            case "color": attributes = [.foregroundColor: UIColor.red]
            case "background": attributes = [.backgroundColor: UIColor.yellow]
            case "underline": attributes = [.underlineStyle: NSUnderlineStyle.single.rawValue]
            default: attributes = [NSAttributedString.Key("foreign.unsupported"): "value"]
            }
            let payload = NSAttributedString(string: kind == "attachment" ? "\u{FFFC}" : "Pasted", attributes: attributes)
            _ = coordinator.textPasteConfigurationSupporting(view, performPasteOf: payload,
                to: try #require(view.selectedTextRange))
            #expect(warning?.contains("not pasted") == true)
            #expect(view.textStorage.isEqual(to: before))
            #expect(view.selectedRange == caret)
            #expect(edits == 0)
            // Later toolbar installation and reconstruction must still use the untouched draft.
            let toggle = try RichDraftFormatting.toggling(.bold, in: original,
                selection: .init(insertionPoint: original.endIndex), context: context)
            coordinator.installExternal(toggle.text, selection: toggle.selection, in: view)
            #expect(view.text == "Keep this")
            #expect(try RichDraftMarkdown.export(RichDraftFormatting.document(
                RichDraftNativeTextView.swiftAttributed(view.textStorage, context: context), context: context)) == "Keep this")
        }
    }

    @Test func ordinaryNativePasteDefaultsAndBoldAreAccepted() throws {
        if #available(iOS 26.0, *) {
            let context = EnvironmentValues().fontResolutionContext
            for font in [UIFont.systemFont(ofSize: 17), UIFont.boldSystemFont(ofSize: 17)] {
                let payload = NSAttributedString(string: "Ordinary paste", attributes: [
                    .font: font, .paragraphStyle: NSParagraphStyle.default, .foregroundColor: UIColor.label])
                #expect(RichDraftNativeTextView.pasteRejectionReason(payload, context: context) == nil)
                let original = AttributedString("Before ")
                var published: AttributedString?
                var rejected = false
                let bridge = RichDraftNativeTextView(text: original,
                    selection: .init(insertionPoint: original.endIndex), contentRevision: 0,
                    fontContext: context, accessibilityIdentifier: "test.editor", accessibilityLabel: "Test",
                    focus: FocusState<Bool>().projectedValue,
                    onEdit: { value, _, _ in published = value }, onSelectionChange: { _ in },
                    onPasteRejected: { _ in rejected = true })
                let coordinator = bridge.makeCoordinator()
                let view = RichDraftUIKitTextView()
                coordinator.view = view
                coordinator.install(original, selection: .init(insertionPoint: original.endIndex), in: view)
                _ = coordinator.textPasteConfigurationSupporting(view, performPasteOf: payload,
                    to: try #require(view.selectedTextRange))
                #expect(!rejected)
                #expect(view.text == "Before Ordinary paste")
                let document = RichDraftFormatting.document(try #require(published), context: context)
                let isBold = font.fontDescriptor.symbolicTraits.contains(.traitBold)
                #expect(try RichDraftMarkdown.export(document) ==
                    (isBold ? "Before **Ordinary paste**" : "Before Ordinary paste"))
            }
        }
    }

    @Test(arguments: [RichDraftMarkdown.Style.bold, .italic, .code])
    func caretOnlyToolbarFormattingPreservesOriginalSourceBytes(style: RichDraftMarkdown.Style) throws {
        if #available(iOS 26.0, *) {
            let source = "+ first"
            guard case .rich(let accepted) = RichDraftMarkdown.importSource(source) else {
                Issue.record("Expected supported list"); return
            }
            let context = EnvironmentValues().fontResolutionContext
            let text = RichDraftFormatting.attributed(accepted)
            let result = try RichDraftFormatting.toggling(style, in: text,
                selection: .init(insertionPoint: text.endIndex), context: context)
            let proposed = RichDraftFormatting.document(result.text, context: context,
                typingAttributes: RichDraftFormatting.trailingTypingAttributes(in: result.text, selection: result.selection))
            let installedSource = RichDraftEditor.sourceForInstallation(proposed, acceptedDocument: accepted,
                lastSource: source, serializedSource: result.markdown)
            #expect(Data(installedSource.utf8) == Data(source.utf8))
            #expect(result.selection.typingAttributes(in: result.text).font != nil)
            let toggledOff = try RichDraftFormatting.toggling(style, in: result.text,
                selection: result.selection, context: context)
            #expect(toggledOff.selection.typingAttributes(in: toggledOff.text).font !=
                result.selection.typingAttributes(in: result.text).font)
            // Real content edits still choose the newly serialized source.
            let changed = try RichDraftFormatting.toggling(.bold, in: text,
                selection: .init(range: text.startIndex..<text.endIndex), context: context)
            let changedDocument = RichDraftFormatting.document(changed.text, context: context)
            #expect(RichDraftEditor.sourceForInstallation(changedDocument, acceptedDocument: accepted,
                lastSource: source, serializedSource: changed.markdown) == changed.markdown)
            #expect(changed.markdown != source)
        }
    }

    @Test func richRecoveryRetainsExactPendingValueUntilExplicitDiscard() {
        if #available(iOS 26.0, *) {
            let store = RichDraftRecoveryStore()
            let text = AttributedString("unsaved 👩🏽‍💻")
            store.update(.init(text: text, selection: .init(insertionPoint: text.endIndex),
                               lastCommittedMarkdown: "saved", reason: "Cannot export"))
            #expect(store.hasUnexportedChanges)
            #expect(store.state?.text == text)
            #expect(store.state?.lastCommittedMarkdown == "saved")
            store.discard()
            #expect(!store.hasUnexportedChanges)
            #expect(store.state == nil)
        }
    }

    @Test func richListToggleOffKeepsOtherItemsAndTheirSeparator() throws {
        if #available(iOS 26.0, *) {
            let context = EnvironmentValues().fontResolutionContext
            guard case .rich(let document) = RichDraftMarkdown.importSource("- First\n- Second") else {
                Issue.record("Expected list"); return
            }
            let text = RichDraftFormatting.attributed(document)
            let removed = try RichDraftFormatting.removingBlock(in: text,
                selection: .init(insertionPoint: text.endIndex), context: context)
            #expect(removed.markdown == "- First\n\nSecond")
            #expect(!RichDraftFormatting.activeCommands(in: removed.text, selection: removed.selection, context: context).contains(.unorderedList))
        }
    }

    @Test func sourceCombinedTraitsToggleIndependently() {
        let bold = MarkdownSourceFormatter.apply(.bold, to: "Hello", selection: NSRange(location: 0, length: 5))
        let both = MarkdownSourceFormatter.apply(.italic, to: bold.source, selection: bold.selection)
        let active = MarkdownSourceFormatter.activeCommands(in: both.source, selection: both.selection)
        #expect(active.contains(.bold))
        #expect(active.contains(.italic))
        let italic = MarkdownSourceFormatter.apply(.bold, to: both.source, selection: both.selection)
        #expect(italic.source == "*Hello*")
        #expect(MarkdownSourceFormatter.activeCommands(in: italic.source, selection: italic.selection) == [.italic])
    }

    @Test func richEquivalenceDetectsByteDistinctUnicodeEdits() {
        #expect(!RichDraftMarkdown.equivalent(.init(spans: [.init(text: "é")]), .init(spans: [.init(text: "e\u{301}")])))
    }

    @Test(arguments: ["```swift\nif true {\n    print(\"<hello>&amp;\")\n}\n```", "```html\n<div>**literal** &amp;</div>\n```", "Use `<div>` literally"])
    func codeContentsDoNotTriggerProseOnlyRestrictions(source: String) throws {
        guard case .rich(let document) = RichDraftMarkdown.importSource(source) else {
            Issue.record("Code content must remain editable without interpreting its indentation or HTML as prose")
            return
        }
        let encoded = try RichDraftMarkdown.export(document)
        guard case .rich(let reopened) = RichDraftMarkdown.importSource(encoded) else {
            Issue.record("Code export must stay rich-editable"); return
        }
        #expect(RichDraftMarkdown.equivalent(document, reopened))
    }

    @Test(arguments: ["1\\. Literal number, not a list", "\\- Literal dash, not a list", "# Title\n\n1. First\n2. **Second**\n\n[Link](https://example.com)\n\n```swift\nlet value = 1\n```", "```swift\nline one\n\nline three\n```"])
    func nativeProjectionPreservesImportedStructure(source: String) throws {
        guard case .rich(let document) = RichDraftMarkdown.importSource(source) else {
            Issue.record("Expected supported import"); return
        }
        if #available(iOS 26.0, *) {
            let native = RichDraftFormatting.attributed(document)
            let decoded = RichDraftFormatting.document(native, context: EnvironmentValues().fontResolutionContext)
            #expect(RichDraftMarkdown.equivalent(document, decoded))
        }
    }

    @Test(arguments: ["Plain prompt\nNext paragraph", "/plan Build the feature", "**Bold** and *italic*", "***Both***", "Cafe\u{301} 👩🏽‍💻"])
    func supportedSourceCanBeEditedWithoutLosingTextOrTraits(source: String) throws {
        guard case .rich(let document) = RichDraftMarkdown.importSource(source) else {
            Issue.record("Expected rich support for bounded prose")
            return
        }
        let exported = try RichDraftMarkdown.export(document)
        guard case .rich(let reparsed) = RichDraftMarkdown.importSource(exported) else {
            Issue.record("Export must remain representable")
            return
        }
        #expect(RichDraftMarkdown.equivalent(document, reparsed))
    }

    @Test(arguments: ["```swift\nlet n = 1\n```", "[a link](https://example.com)", "- first\n- second", "1. First\n2. **Second**", "# Heading", "Use `inline code` and **bold**"])
    func structuredMarkdownSupportsRichEditingAndRoundTrips(source: String) throws {
        guard case .rich(let document) = RichDraftMarkdown.importSource(source) else {
            Issue.record("Rich Text must support lists, links, code, and headings")
            return
        }
        let exported = try RichDraftMarkdown.export(document)
        guard case .rich(let reparsed) = RichDraftMarkdown.importSource(exported) else {
            Issue.record("Structured rich output must remain editable")
            return
        }
        #expect(RichDraftMarkdown.equivalent(document, reparsed))
    }

    @Test(arguments: ["    indented code\n", "hard break  \nnext", "Windows\r\nlines"])
    func complexMarkdownExplicitlyStaysInSourceMode(source: String) {
        guard case .source(let reason) = RichDraftMarkdown.importSource(source) else {
            Issue.record("Unsupported syntax must not be flattened into rich text")
            return
        }
        #expect(!reason.isEmpty)
    }

    @Test func serializationHandlesLiteralSyntaxAndAdjacentTraits() throws {
        let documents: [RichDraftMarkdown.Document] = [
            .init(spans: [.init(text: "literal *stars* & [brackets]")]),
            .init(spans: [.init(text: "Bold words", style: .bold)]),
            .init(spans: [.init(text: "a", style: .bold), .init(text: "b", style: [.bold, .italic])]),
            .init(spans: [.init(text: "bold", style: .bold), .init(text: " and "), .init(text: "italic", style: .italic)]),
            .init(spans: [.init(text: "👩🏽‍💻 Cafe\u{301}", style: [.bold, .italic])]),
        ]
        for document in documents {
            let encoded = try RichDraftMarkdown.export(document)
            guard case .rich(let decoded) = RichDraftMarkdown.importSource(encoded) else {
                Issue.record("Encoded rich text must round-trip: \(encoded)")
                continue
            }
            #expect(RichDraftMarkdown.equivalent(document, decoded))
        }
    }

    @Test func sourceEqualityIsByteExactRatherThanUnicodeNormalization() {
        #expect(!RichDraftMarkdown.sameSource("é", "e\u{301}"))
        #expect(RichDraftMarkdown.sameSource("line  \n", "line  \n"))
    }

    @Test func nativeFormattingKeepsSelectionNearTheBeginningOfALongDraft() throws {
        if #available(iOS 26.0, *) {
            let context = EnvironmentValues().fontResolutionContext
            let document = RichDraftMarkdown.Document(spans: [.init(text: "Hello " + String(repeating: "long prompt text ", count: 300))])
            let text = RichDraftFormatting.attributed(document)
            let end = text.characters.index(text.startIndex, offsetBy: 5)
            let selected = AttributedTextSelection(range: text.startIndex..<end)
            let result = try RichDraftFormatting.toggling(.bold, in: text, selection: selected, context: context)
            #expect(result.markdown.hasPrefix("**Hello**"))
            guard case .ranges(let ranges) = result.selection.indices(in: result.text) else {
                Issue.record("Formatting must preserve the selected range")
                return
            }
            #expect(ranges.ranges.map { String(result.text[$0].characters) }.joined() == "Hello")
        }
    }

    @Test func v2UsesGlassOnlyForFunctionalChromeAndRespectsTransparency() {
        for role in BighelpSurfaceRole.allCases {
            let normal = BighelpSurfacePresentation.resolve(role: role, supportsLiquidGlass: true, reduceTransparency: false, increaseContrast: false, uiV2Enabled: true)
            #expect(normal.fill == ([.card, .input, .selected].contains(role) ? .opaque : .liquidGlass))
            let reduced = BighelpSurfacePresentation.resolve(role: role, supportsLiquidGlass: true, reduceTransparency: true, increaseContrast: true, uiV2Enabled: true)
            #expect(reduced.fill == .opaque)
            #expect(reduced.outline == .increased)
        }
    }
}
