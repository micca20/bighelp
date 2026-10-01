import Testing
import UIKit
@testable import Bighelp

struct ComposerReturnKeyTests {
    @Test func returnSendsByDefaultAndShiftReturnAddsALine() {
        #expect(ComposerReturnKeyAction.resolve(.plain, returnSends: true, canSend: true, isTurnLive: false) == .send)
        #expect(ComposerReturnKeyAction.resolve(.shift, returnSends: true, canSend: true, isTurnLive: false) == .newLine)
    }

    @Test func returnAddsALineWhenSettingsSaySo() {
        #expect(ComposerReturnKeyAction.resolve(.plain, returnSends: false, canSend: true, isTurnLive: false) == .newLine)
        #expect(ComposerReturnKeyAction.resolve(.shift, returnSends: false, canSend: true, isTurnLive: true) == .newLine)
        // Command-Return still sends, so there's always a key for it.
        #expect(ComposerReturnKeyAction.resolve(.command, returnSends: false, canSend: true, isTurnLive: false) == .send)
    }

    @Test func commandReturnOffersSendChoicesOnlyWhileTheAgentWorks() {
        #expect(ComposerReturnKeyAction.resolve(.command, returnSends: true, canSend: true, isTurnLive: true) == .sendOptions)
        #expect(ComposerReturnKeyAction.resolve(.command, returnSends: true, canSend: true, isTurnLive: false) == .send)
    }

    @Test func nothingToSendNeitherSendsNorAddsAStrayLine() {
        #expect(ComposerReturnKeyAction.resolve(.plain, returnSends: true, canSend: false, isTurnLive: false) == .nothing)
        #expect(ComposerReturnKeyAction.resolve(.command, returnSends: true, canSend: false, isTurnLive: true) == .nothing)
        #expect(ComposerReturnKeyAction.resolve(.shift, returnSends: true, canSend: false, isTurnLive: false) == .newLine)
    }

    // Simulator UI tests can't press a plain or Shift-Return (XCUITest drops
    // them before the app sees them), so the message boxes' own key commands
    // are driven here.
    @MainActor @Test func messageBoxesSendOnReturnAndAddALineOnShiftReturn() {
        var views: [UITextView & ComposerReturnKeyHandling] = [ClipboardPasteTextView()]
        if #available(iOS 26.0, *) { views.append(RichDraftUIKitTextView()) }
        for view in views {
            var pressed: [ComposerReturnKey] = []
            setReturnKeyHandler(on: view) { key in
                pressed.append(key)
                return key != .shift
            }
            view.text = "Packing list"
            view.selectedRange = NSRange(location: 12, length: 0)

            press(.shift, on: view)
            #expect(view.text == "Packing list\n")
            press([], on: view)
            press(.command, on: view)
            #expect(view.text == "Packing list\n", "Handled keys add nothing")
            #expect(pressed == [.shift, .plain, .command])
        }
    }

    @MainActor @Test func returnIsLeftAloneWhileTypingWithAnInputMethodOrOutsideChats() {
        let view = ClipboardPasteTextView()
        #expect(returnCommands(on: view).isEmpty, "No chat handler (Scratchpad and other editors)")
        view.onReturnKey = { _ in true }
        #expect(returnCommands(on: view).count == 3)
        view.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0))
        #expect(returnCommands(on: view).isEmpty, "Return confirms the IME's text")
    }

    @MainActor @Test func sendChoicesTakeNumberKeysAndReturn() {
        let keys = KeyboardChoiceKeys.KeysView()
        var picked: [Int] = []
        keys.count = 3
        keys.onPick = { picked.append($0) }
        let commands = keys.keyCommands ?? []
        #expect(commands.map(\.input) == ["1", "2", "3", "\r"])
        #expect(keys.canBecomeFirstResponder)
        for input in ["2", "\r", "3"] {
            if let command = commands.first(where: { $0.input == input }), let action = command.action {
                keys.perform(action, with: command)
            }
        }
        #expect(picked == [1, 0, 2], "2 picks the second choice, Return the usual one")
    }

    @MainActor private func setReturnKeyHandler(on view: UITextView & ComposerReturnKeyHandling,
                                                _ handler: @escaping (ComposerReturnKey) -> Bool) {
        if let view = view as? ClipboardPasteTextView { view.onReturnKey = handler }
        if #available(iOS 26.0, *), let view = view as? RichDraftUIKitTextView { view.onReturnKey = handler }
    }

    @MainActor private func returnCommands(on view: UITextView) -> [UIKeyCommand] {
        (view.keyCommands ?? []).filter { $0.input == "\r" }
    }

    @MainActor private func press(_ modifiers: UIKeyModifierFlags, on view: UITextView) {
        let command = returnCommands(on: view).first { $0.modifierFlags == modifiers }
        #expect(command?.wantsPriorityOverSystemBehavior == true)
        if let command, let action = command.action { view.perform(action, with: command) }
    }
}
