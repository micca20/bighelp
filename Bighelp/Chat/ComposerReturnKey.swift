import SwiftUI
import UIKit

/// Return on a hardware keyboard, and which modifier was held with it.
enum ComposerReturnKey: Sendable {
    case plain, shift, command
}

/// What a hardware Return does in a message box. Return sends (or adds a line,
/// per Settings › Chat), Shift-Return adds a line, and Command-Return shows the
/// send choices while the agent is working, or sends when it isn't.
enum ComposerReturnKeyAction: Equatable, Sendable {
    case newLine, send, sendOptions, nothing

    static func resolve(_ key: ComposerReturnKey, returnSends: Bool, canSend: Bool, isTurnLive: Bool) -> Self {
        switch key {
        case .shift: .newLine
        case .plain: !returnSends ? .newLine : canSend ? .send : .nothing
        case .command: !canSend ? .nothing : isTurnLive ? .sendOptions : .send
        }
    }
}

/// A message box's text view taking hardware Return keys.
@MainActor
protocol ComposerReturnKeyHandling: UITextView {
    /// True when the chat handled the key (sent, or showed send choices); false
    /// types a new line. Nil leaves Return alone.
    var onReturnKey: ((ComposerReturnKey) -> Bool)? { get }
}

extension ComposerReturnKeyHandling {
    /// The Return commands, unless text is still being composed (Japanese,
    /// Chinese…), where Return confirms it.
    func returnKeyCommands(plain: Selector, shift: Selector, command: Selector) -> [UIKeyCommand] {
        guard onReturnKey != nil, isEditable, markedTextRange == nil else { return [] }
        let commands = [
            UIKeyCommand(input: "\r", modifierFlags: [], action: plain),
            UIKeyCommand(input: "\r", modifierFlags: .shift, action: shift),
            UIKeyCommand(title: "Send Options", action: command, input: "\r", modifierFlags: .command),
        ]
        for command in commands { command.wantsPriorityOverSystemBehavior = true }
        return commands
    }

    func handleReturnKey(_ key: ComposerReturnKey) {
        if onReturnKey?(key) != true { insertText("\n") }
    }
}

/// Takes the keyboard when the send choices open from Command-Return. The
/// message box gave up focus for them, and without a first responder in the
/// sheet no key reaches it: 1–9 pick a choice, Return picks the first.
struct KeyboardChoiceKeys: UIViewRepresentable {
    let count: Int
    let onPick: (Int) -> Void

    func makeUIView(context: Context) -> KeysView { KeysView() }
    func updateUIView(_ view: KeysView, context: Context) {
        view.count = min(count, 9)
        view.onPick = onPick
    }

    final class KeysView: UIView {
        var count = 0
        var onPick: ((Int) -> Void)?

        override var canBecomeFirstResponder: Bool { true }

        override var keyCommands: [UIKeyCommand]? {
            let digits = (0..<count).map { index in
                UIKeyCommand(input: String(index + 1), modifierFlags: [], action: #selector(pickDigit(_:)))
            }
            let commands = digits + [UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(pickFirst))]
            for command in commands { command.wantsPriorityOverSystemBehavior = true }
            return commands
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in _ = self?.becomeFirstResponder() }
        }

        @objc private func pickDigit(_ command: UIKeyCommand) {
            guard let digit = command.input.flatMap(Int.init), (1...count).contains(digit) else { return }
            onPick?(digit - 1)
        }

        @objc private func pickFirst() { onPick?(0) }
    }
}
